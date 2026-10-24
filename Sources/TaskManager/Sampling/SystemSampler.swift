import Darwin
import Foundation
import IOKit
import SystemConfiguration

/// System-wide metrics from mach / sysctl / IOKit — no child processes.
/// Not thread-safe: owned by `Sampler`'s queue.
final class SystemSampler {
    private var previousTicks: [[UInt32]] = []          // per core: user, system, idle, nice
    private var previousDisk: DiskCounters?
    private var previousNet: (rx: UInt64, tx: UInt64)?
    private var previousSwap: (ins: UInt64, outs: UInt64)?
    private var previousTime: UInt64 = 0

    // Slow-changing values, refreshed every `slowEvery` ticks.
    private var tick = 0
    private let slowEvery = 15
    private var cachedDisk = DiskStats()
    private var cachedNet = NetworkStats()
    private var cachedGPU = GPUStats()
    private let devices = DeviceScanner()

    private let staticCPU: CPUStats = {
        var c = CPUStats()
        c.brand = Sysctl.string("machdep.cpu.brand_string") ?? "CPU"
        c.physicalCores = Sysctl.int("hw.physicalcpu") ?? 0
        c.logicalCores = Sysctl.int("hw.logicalcpu") ?? 0
        c.performanceCores = Sysctl.int("hw.perflevel0.physicalcpu") ?? 0
        c.efficiencyCores = Sysctl.int("hw.perflevel1.physicalcpu") ?? 0
        return c
    }()
    private let totalMemory = UInt64(Sysctl.int("hw.memsize") ?? 0)
    private var lastSwapCounts: (ins: UInt64, outs: UInt64)?
    private let bootTime = Sysctl.bootTime()

    func sample() -> SystemSnapshot {
        let now = DispatchTime.now().uptimeNanoseconds
        let secs = previousTime == 0 ? 0 : Double(now - previousTime) / 1e9
        previousTime = now

        if tick % slowEvery == 0 { refreshSlow() }
        tick &+= 1

        var s = SystemSnapshot()
        s.cpu = cpu()
        s.memory = memory()
        if let p = previousSwap, secs > 0, let cur = lastSwapCounts {
            let page = Double(vm_kernel_page_size)
            s.memory.swapInPerSec = cur.ins >= p.ins ? Double(cur.ins - p.ins) * page / secs : 0
            s.memory.swapOutPerSec = cur.outs >= p.outs ? Double(cur.outs - p.outs) * page / secs : 0
        }
        previousSwap = lastSwapCounts
        s.disk = cachedDisk
        devices.refreshIfNeeded()
        let storage = devices.readStorage(seconds: secs)
        s.storageDevices = storage.devices
        s.bootIO = storage.bootIO
        // The Disk page is the startup drive only; other drives have their own
        // pages, and disk images are left out (their I/O already hits a real drive).
        let disk = storage.boot.map { DiskCounters(read: $0.r, write: $0.w, readOps: $0.ro, writeOps: $0.wo) } ?? diskCounters()
        s.disk.totalBytesRead = disk.read
        s.disk.totalBytesWritten = disk.write
        s.disk.totalReadOps = disk.readOps
        s.disk.totalWriteOps = disk.writeOps
        if let p = previousDisk, secs > 0 {
            func r(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) / secs : 0 }
            s.disk.readPerSec = r(disk.read, p.read)
            s.disk.writePerSec = r(disk.write, p.write)
            s.disk.readOpsPerSec = r(disk.readOps, p.readOps)
            s.disk.writeOpsPerSec = r(disk.writeOps, p.writeOps)
        }
        previousDisk = disk
        s.network = cachedNet
        let (net, perInterface) = networkCounters()
        s.networkDevices = devices.readNetwork(perInterface, seconds: secs)
        if let p = previousNet, secs > 0 {
            s.network.inPerSec = net.rx >= p.rx ? Double(net.rx - p.rx) / secs : 0
            s.network.outPerSec = net.tx >= p.tx ? Double(net.tx - p.tx) / secs : 0
        }
        previousNet = net
        s.gpu = cachedGPU
        if let g = GPU.performance() {
            s.gpu.utilization = g.utilization; s.gpu.memoryInUse = g.memoryInUse
            s.gpu.renderer = g.renderer; s.gpu.tiler = g.tiler
            s.gpu.memoryAllocated = g.memoryAllocated; s.gpu.recoveries = g.recoveries
        }
        s.uptime = bootTime.map { Date().timeIntervalSince($0) } ?? 0
        s.thermal = ProcessInfo.processInfo.thermalState
        s.systemPower = Self.systemPower()
        return s
    }

    private static let battery: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))

    /// PowerTelemetryData.SystemLoad (mW) from the battery controller.
    private static func systemPower() -> Double? {
        guard battery != 0,
              let t = IOKitUtil.property(battery, "PowerTelemetryData") as? [String: Any],
              let mw = (t["SystemLoad"] as? NSNumber)?.doubleValue, mw > 0 else { return nil }
        return mw / 1000
    }

    // MARK: CPU

    private func cpu() -> CPUStats {
        var c = staticCPU
        var la = [Double](repeating: 0, count: 3)
        if getloadavg(&la, 3) == 3 { c.loadAverage = la }

        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return c }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        ticks.reserveCapacity(Int(count))
        for core in 0..<Int(count) {
            let base = core * states
            ticks.append([UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                          UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                          UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                          UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])])
        }
        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else {
            c.perCore = Array(repeating: 0, count: ticks.count)
            return c
        }

        var sumUser = 0.0, sumSys = 0.0, sumTotal = 0.0
        c.perCore = ticks.indices.map { i in
            let d = (0..<4).map { Double(ticks[i][$0] &- previousTicks[i][$0]) }
            let user = d[0] + d[3], sys = d[1], total = d[0] + d[1] + d[2] + d[3]
            sumUser += user; sumSys += sys; sumTotal += total
            return total > 0 ? (user + sys) / total * 100 : 0
        }
        if sumTotal > 0 {
            c.user = sumUser / sumTotal * 100
            c.system = sumSys / sumTotal * 100
            c.total = c.user + c.system
        }
        return c
    }

    // MARK: Memory (used = app + wired + compressed, as macOS counts it)

    private func memory() -> MemoryStats {
        var m = MemoryStats()
        m.total = totalMemory
        var vm = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            m.wired = UInt64(vm.wire_count) * page
            m.compressed = UInt64(vm.compressor_page_count) * page
            m.compressorStored = UInt64(vm.total_uncompressed_pages_in_compressor) * page
            m.cached = (UInt64(vm.external_page_count) + purgeable) * page
            m.free = (UInt64(vm.free_count) + UInt64(vm.speculative_count)) * page
            m.used = m.app + m.wired + m.compressed
            lastSwapCounts = (vm.swapins, vm.swapouts)
        }
        let swap = Sysctl.swapUsage()
        m.swapUsed = swap.used
        m.swapTotal = swap.total
        if let level = Sysctl.int("kern.memorystatus_level") { m.pressure = Double(100 - level) }
        if let l = Sysctl.int("kern.memorystatus_vm_pressure_level"), let p = PressureLevel(rawValue: l) { m.pressureLevel = p }
        return m
    }

    // MARK: Disk

    private struct DiskCounters { var read: UInt64 = 0, write: UInt64 = 0, readOps: UInt64 = 0, writeOps: UInt64 = 0 }

    private func diskCounters() -> DiskCounters {
        var c = DiskCounters()
        IOKitUtil.forEach(matching: "IOBlockStorageDriver") { service in
            guard let stats = IOKitUtil.property(service, "Statistics") as? [String: Any] else { return }
            func v(_ k: String) -> UInt64 { (stats[k] as? NSNumber)?.uint64Value ?? 0 }
            c.read &+= v("Bytes (Read)")
            c.write &+= v("Bytes (Write)")
            c.readOps &+= v("Operations (Read)")
            c.writeOps &+= v("Operations (Write)")
        }
        return c
    }

    // MARK: Network (64-bit counters; getifaddrs' if_data wraps at 4 GB)

    private func networkCounters() -> ((rx: UInt64, tx: UInt64), [String: InterfaceCounters]) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return ((0, 0), [:]) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return ((0, 0), [:]) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var each: [String: InterfaceCounters] = [:]
        var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if (h2.ifm_flags & IFF_LOOPBACK) == 0 {
                        rx &+= h2.ifm_data.ifi_ibytes
                        tx &+= h2.ifm_data.ifi_obytes
                        if if_indextoname(UInt32(h2.ifm_index), &nameBuf) != nil {
                            let up = (h2.ifm_flags & IFF_UP) != 0 && (h2.ifm_flags & IFF_RUNNING) != 0
                            each[String(cString: nameBuf)] = InterfaceCounters(rx: h2.ifm_data.ifi_ibytes, tx: h2.ifm_data.ifi_obytes,
                                                                               baud: h2.ifm_data.ifi_baudrate, up: up)
                        }
                    }
                }
                offset += Int(hdr.ifm_msglen)
            }
        }
        return ((rx, tx), each)
    }

    // MARK: Slow-changing info

    private func refreshSlow() {
        // Boot volume capacity.
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                     .volumeAvailableCapacityForImportantUsageKey,
                                                     .volumeLocalizedNameKey,
                                                     .volumeLocalizedFormatDescriptionKey]) {
            cachedDisk.capacity = UInt64(v.volumeTotalCapacity ?? 0)
            cachedDisk.available = UInt64(v.volumeAvailableCapacityForImportantUsage ?? 0)
            cachedDisk.volumeName = v.volumeLocalizedName ?? "Macintosh HD"
            cachedDisk.fileSystem = v.volumeLocalizedFormatDescription ?? ""
        }
        // Primary interface + IPv4 address.
        if let store = SCDynamicStoreCreate(nil, "TaskManager" as CFString, nil, nil),
           let g = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let iface = g["PrimaryInterface"] as? String {
            cachedNet.interface = iface
            cachedNet.address = ""
            if let a = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(iface)/IPv4" as CFString) as? [String: Any],
               let addrs = a["Addresses"] as? [String] {
                cachedNet.address = addrs.first ?? ""
            }
        } else {
            cachedNet.interface = ""
            cachedNet.address = ""
        }
        if cachedGPU.model.isEmpty { cachedGPU = GPU.info() }
    }
}

// MARK: - GPU (IOAccelerator; no sudo)

enum GPU {
    static func info() -> GPUStats {
        var g = GPUStats()
        IOKitUtil.forEach(matching: "IOAccelerator") { s in
            if g.model.isEmpty, let m = IOKitUtil.property(s, "model") as? String { g.model = m }
            if g.cores == 0, let c = IOKitUtil.property(s, "gpu-core-count") as? NSNumber { g.cores = c.intValue }
        }
        if g.model.isEmpty { g.model = "GPU" }
        return g
    }

    /// The busiest accelerator's `PerformanceStatistics` (one on Apple silicon).
    static func performance() -> GPUStats? {
        var best: GPUStats?
        IOKitUtil.forEach(matching: "IOAccelerator") { s in
            guard let perf = IOKitUtil.property(s, "PerformanceStatistics") as? [String: Any],
                  let u = (perf["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
            guard best == nil || u > best!.utilization! else { return }
            var g = GPUStats()
            g.utilization = u
            g.memoryInUse = (perf["In use system memory"] as? NSNumber)?.uint64Value
            g.renderer = (perf["Renderer Utilization %"] as? NSNumber)?.doubleValue
            g.tiler = (perf["Tiler Utilization %"] as? NSNumber)?.doubleValue
            g.memoryAllocated = (perf["Alloc system memory"] as? NSNumber)?.uint64Value
            g.recoveries = (perf["recoveryCount"] as? NSNumber)?.intValue
            best = g
        }
        return best
    }

    /// Cumulative GPU time (ns) per client pid, from each accelerator's user
    /// clients. Diffed by `Sampler` into a per-process GPU %.
    static func clientTimes() -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        IOKitUtil.forEach(matching: "IOAccelerator") { acc in
            var it: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(acc, kIOServicePlane, &it) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(it) }
            while case let child = IOIteratorNext(it), child != 0 {
                defer { IOObjectRelease(child) }
                guard let creator = IOKitUtil.property(child, "IOUserClientCreator") as? String,
                      let usage = IOKitUtil.property(child, "AppUsage") as? [[String: Any]] else { continue }
                // "pid 159, WindowServer"
                let digits = creator.dropFirst(4).prefix { $0.isNumber }
                guard let pid = pid_t(digits) else { continue }
                let ns = usage.reduce(UInt64(0)) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                result[pid, default: 0] &+= ns
            }
        }
        return result
    }
}

enum IOKitUtil {
    static func forEach(matching cls: String, _ body: (io_object_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            body(s)
            IOObjectRelease(s)
        }
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
