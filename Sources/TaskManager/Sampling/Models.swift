import Foundation

/// Which part of the process tree a process belongs to.
enum ProcessKind: Int, Sendable, CaseIterable {
    case app, background, system

    var title: String {
        switch self {
        case .app: return "Apps"
        case .background: return "Background Processes"
        case .system: return "System Processes"
        }
    }
}

enum ProcessState: String, Sendable {
    case running = "Running", sleeping = "Sleeping", stopped = "Paused"
    case zombie = "Zombie", idle = "Idle", unknown = "—"

    init(bsdStatus: UInt32) {
        switch bsdStatus {
        case 1: self = .idle      // SIDL
        case 2: self = .running   // SRUN
        case 3: self = .sleeping  // SSLEEP
        case 4: self = .stopped   // SSTOP (paused)
        case 5: self = .zombie    // SZOMB
        default: self = .unknown
        }
    }
}

/// One process, as sampled on a single tick. Plain value type so it can be
/// handed from the sampling queue to the main thread without copying costs
/// beyond the array itself.
struct ProcessInfoSample: Identifiable, Sendable, Equatable {
    var id: pid_t { pid }
    let pid: pid_t
    var ppid: pid_t
    var uid: uid_t
    var user: String
    var name: String
    var path: String
    /// Outermost enclosing `.app` bundle, if any ("/Applications/Safari.app").
    var bundlePath: String
    var kind: ProcessKind
    var state: ProcessState
    var nice: Int32
    var started: Date?
    var threads: Int32
    /// Percent of ONE core (macOS convention); the UI rescales if
    /// the user prefers "share of all cores".
    var cpu: Double
    /// User-mode and kernel-mode parts of `cpu` (same units).
    var cpuUser: Double
    var cpuSystem: Double
    var memory: UInt64
    var diskReadPerSec: Double
    var diskWritePerSec: Double
    var netPerSec: Double
    var gpu: Double
    /// Estimated power of the process's CPU work (W), from the kernel's
    /// per-process energy counter — the basis of energy-per-app figures.
    var power: Double = 0
    /// True when the kernel refused direct access (another user's process) and
    /// values came from the setuid `ps` fallback (no disk / thread data).
    var restricted: Bool
    /// Set for regular GUI apps (NSRunningApplication with a Dock icon).
    var isRegularApp: Bool
    var appName: String?
    /// In Darwin background mode (our "Optimize", or set by macOS / the app
    /// itself). Read from the kernel every tick, so it is always truthful.
    var background: Bool
}

extension ProcessInfoSample {
    /// Groups a process with its app: helpers share the app's outer .app
    /// bundle; anything else is keyed by name.
    var appKey: String { bundlePath.isEmpty ? "n:" + name : bundlePath }
}

struct CPUStats: Sendable {
    var total: Double = 0          // 0-100, all cores
    var user: Double = 0
    var system: Double = 0
    var perCore: [Double] = []
    var brand: String = ""
    var physicalCores = 0
    var logicalCores = 0
    var performanceCores = 0
    var efficiencyCores = 0
    var loadAverage: [Double] = [0, 0, 0]
}

struct MemoryStats: Sendable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    /// Original (uncompressed) size of the app data held by the compressor,
    /// whether those compressed pages are in RAM or swapped out.
    var compressorStored: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// Bytes per second moved between RAM and the swap file.
    var swapInPerSec: Double = 0
    var swapOutPerSec: Double = 0
    /// 0-100, from kern.memorystatus_level (what drives macOS's
    /// "Memory Pressure" graph).
    var pressure: Double = 0
    /// Kernel pressure level, the same signal macOS itself uses.
    var pressureLevel: PressureLevel = .normal
    var percent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
}

enum PressureLevel: Int, Sendable {
    case normal = 1, warning = 2, critical = 4
    var title: String { self == .normal ? "Normal" : self == .warning ? "Elevated" : "Critical" }
}

struct DiskStats: Sendable {
    var readPerSec: Double = 0
    var writePerSec: Double = 0
    /// Operation counts (I/O requests) per second and cumulative since boot.
    var readOpsPerSec: Double = 0
    var writeOpsPerSec: Double = 0
    var totalReadOps: UInt64 = 0
    var totalWriteOps: UInt64 = 0
    var totalBytesRead: UInt64 = 0
    var totalBytesWritten: UInt64 = 0
    var capacity: UInt64 = 0
    var available: UInt64 = 0
    var volumeName: String = "Macintosh HD"
    var fileSystem: String = ""
}

struct NetworkStats: Sendable {
    var inPerSec: Double = 0
    var outPerSec: Double = 0
    var interface: String = ""
    var address: String = ""
}

struct GPUStats: Sendable {
    var model: String = ""
    var cores: Int = 0
    var utilization: Double? = nil
    var memoryInUse: UInt64? = nil
    var renderer: Double? = nil        // shading / drawing units busy %
    var tiler: Double? = nil           // geometry (tiling) units busy %
    var memoryAllocated: UInt64? = nil // system memory the GPU driver has reserved
    var recoveries: Int? = nil         // GPU restarts after a hang, since startup
}

struct SystemSnapshot: Sendable {
    var cpu = CPUStats()
    var memory = MemoryStats()
    var disk = DiskStats()
    var network = NetworkStats()
    var gpu = GPUStats()
    var uptime: TimeInterval = 0
    /// Whole-Mac power draw (W) where the hardware reports it (laptops).
    var systemPower: Double?
    var processCount = 0
    var threadCount = 0
    var thermal: ProcessInfo.ThermalState = .nominal
    /// Drives other than the startup drive, and plugged-in network adapters.
    var storageDevices: [StorageDevice] = []
    /// Startup drive's response-time and error counters (for drive health).
    var bootIO = DriveIO()
    var networkDevices: [NetworkDevice] = []
}

/// Everything produced by one sampling tick.
struct Snapshot: Sendable {
    var date = Date()
    var processes: [ProcessInfoSample] = []
    var system = SystemSnapshot()
}

/// Rolling record of the last 10 minutes for the Performance graphs.
/// Every array is aligned with `times`; samples older than `window` are
/// dropped on each push, so memory use stays small and constant.
struct History: Sendable {
    static let window: TimeInterval = 600          // keep 10 minutes
    static let length = 60                         // index-based graphs (sensors)
    var times: [Date] = []
    var cpu: [Double] = []
    var cpuUser: [Double] = []
    var cpuSystem: [Double] = []
    var perCore: [[Double]] = []
    var memory: [Double] = []
    var pressure: [Double] = []
    var pressureLevels: [PressureLevel] = []
    var memOpen: [Double] = []
    var memSystem: [Double] = []
    var memCompressed: [Double] = []
    var memCache: [Double] = []
    var memAvailable: [Double] = []
    var memFree: [Double] = []
    var memSwap: [Double] = []
    var diskRead: [Double] = []
    var diskWrite: [Double] = []
    var netIn: [Double] = []
    var netOut: [Double] = []
    var gpu: [Double] = []
    var gpuAI: [Double] = []          // GPU % used by local AI runtimes (0 when none)
    var power: [Double] = []
    /// Per-device read/write or in/out, each with its own timestamps (devices
    /// come and go, so they can't share `times`). Keyed "disk:<id>" / "net:<id>".
    var devices: [String: DeviceSeries] = [:]

    mutating func push(_ s: SystemSnapshot, at date: Date = Date(), aiGPU: Double = 0) {
        times.append(date)
        cpu.append(s.cpu.total); cpuUser.append(s.cpu.user); cpuSystem.append(s.cpu.system)
        if perCore.count != s.cpu.perCore.count {
            perCore = Array(repeating: Array(repeating: 0, count: times.count - 1), count: s.cpu.perCore.count)
        }
        for i in s.cpu.perCore.indices { perCore[i].append(s.cpu.perCore[i]) }
        memory.append(s.memory.percent); pressure.append(s.memory.pressure)
        pressureLevels.append(s.memory.pressureLevel)
        let total = Double(max(1, s.memory.total))
        memOpen.append(Double(s.memory.app) / total * 100)
        memSystem.append(Double(s.memory.wired) / total * 100)
        memCompressed.append(Double(s.memory.compressed) / total * 100)
        memCache.append(Double(s.memory.cached) / total * 100)
        memAvailable.append(Double(s.memory.total > s.memory.used ? s.memory.total - s.memory.used : 0) / total * 100)
        let free = s.memory.total > s.memory.used + s.memory.cached ? s.memory.total - s.memory.used - s.memory.cached : 0
        memFree.append(Double(free) / total * 100)
        memSwap.append(Double(s.memory.swapUsed) / total * 100)
        diskRead.append(s.disk.readPerSec); diskWrite.append(s.disk.writePerSec)
        netIn.append(s.network.inPerSec); netOut.append(s.network.outPerSec)
        gpu.append(s.gpu.utilization ?? 0)
        gpuAI.append(aiGPU)
        power.append(s.systemPower ?? 0)
        var present = Set<String>()
        for d in s.storageDevices {
            let k = "disk:" + d.id; present.insert(k)
            devices[k, default: DeviceSeries()].push(date, d.readPerSec, d.writePerSec)
        }
        for d in s.networkDevices {
            let k = "net:" + d.id; present.insert(k)
            devices[k, default: DeviceSeries()].push(date, d.inPerSec, d.outPerSec)
        }
        for k in devices.keys where !present.contains(k) { devices[k] = nil }   // unplugged

        // Drop everything older than 10 minutes (keep one point just outside
        // the window so graphs start at the left edge).
        let cutoff = date.addingTimeInterval(-Self.window)
        var drop = 0
        while drop + 1 < times.count && times[drop + 1] < cutoff { drop += 1 }
        if drop > 0 { trim(drop) }
    }

    private mutating func trim(_ n: Int) {
        times.removeFirst(n)
        for k in [\History.cpu, \.cpuUser, \.cpuSystem, \.memory, \.pressure, \.memOpen, \.memSystem, \.memCompressed,
                  \.memCache, \.memAvailable, \.memFree, \.memSwap, \.diskRead, \.diskWrite, \.netIn, \.netOut, \.gpu, \.gpuAI, \.power] as [WritableKeyPath<History, [Double]>] {
            self[keyPath: k].removeFirst(min(n, self[keyPath: k].count))
        }
        pressureLevels.removeFirst(min(n, pressureLevels.count))
        for i in perCore.indices { perCore[i].removeFirst(min(n, perCore[i].count)) }
    }
}

/// Two series (read/write or in/out) for one device, last 10 minutes.
struct DeviceSeries: Sendable {
    var times: [Date] = []
    var a: [Double] = []
    var b: [Double] = []
    mutating func push(_ date: Date, _ x: Double, _ y: Double) {
        times.append(date); a.append(x); b.append(y)
        let cutoff = date.addingTimeInterval(-History.window)
        var drop = 0
        while drop + 1 < times.count && times[drop + 1] < cutoff { drop += 1 }
        if drop > 0 { times.removeFirst(drop); a.removeFirst(drop); b.removeFirst(drop) }
    }
}
