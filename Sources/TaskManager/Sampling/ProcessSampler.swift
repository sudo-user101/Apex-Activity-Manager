import Darwin
import Foundation

/// Enumerates processes straight from the kernel via libproc.
///
/// Cost per tick is two syscalls per process (task info + resource usage); the
/// path, user name and bundle for each pid are cached for its lifetime. No
/// tools are spawned per tick; a child process is only spawned for the processes the
/// kernel won't let a normal user inspect (root / other users), and only when
/// the visible view actually shows per-process data.
///
/// Not thread-safe: owned and called exclusively by `Sampler`'s queue.
final class ProcessSampler {
    private struct Previous { var userNs: Double; var systemNs: Double; var diskRead: UInt64; var diskWrite: UInt64; var energy: UInt64 }
    private struct Static { var name: String; var path: String; var bundlePath: String; var started: UInt64 }
    private struct Restricted { var cpu: Double; var user: Double; var system: Double; var rss: UInt64; var nice: Int32 }
    private struct RestrictedTimes { var user: Double; var total: Double }

    private var previous: [pid_t: Previous] = [:]
    private var previousTime: UInt64 = 0
    private var statics: [pid_t: Static] = [:]
    private var restricted: [pid_t: Restricted] = [:]
    private var restrictedTimes: [pid_t: RestrictedTimes] = [:]
    private var startCache: [pid_t: UInt64] = [:]
    private var restrictedTime: UInt64 = 0
    private var userNames: [uid_t: String] = [:]
    private var pidBuffer: [pid_t] = []
    private var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    private let currentUID = getuid()

    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/Library/Apple/"]

    struct RegularApp: Sendable { let name: String; let bundlePath: String }

    /// - Parameters:
    ///   - refreshRestricted: re-run the `ps` fallback for inaccessible pids;
    ///     when false the last known values are reused.
    ///   - netRates / gpuNs: optional per-pid extras (only gathered while the
    ///     Processes view is on screen).
    func sample(regularApps: [pid_t: RegularApp],
                refreshRestricted: Bool,
                netRates: [pid_t: Double],
                gpuPercent: [pid_t: Double]) -> [ProcessInfoSample] {
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = previousTime == 0 ? 0 : Double(now - previousTime)
        previousTime = now

        let pids = listPids()
        var out: [ProcessInfoSample] = []
        out.reserveCapacity(pids.count)
        var nextPrevious: [pid_t: Previous] = [:]
        nextPrevious.reserveCapacity(pids.count)
        var restrictedPids: [pid_t] = []
        var alive = Set<pid_t>()
        alive.reserveCapacity(pids.count)

        let allSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        for pid in pids {
            var all = proc_taskallinfo()
            let ok = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all, allSize) == allSize

            var uid: uid_t, ppid: pid_t, status: UInt32, comm: String
            var nice: Int32 = 0, threads: Int32 = 0, started: UInt64 = 0
            var cpuU = 0.0, cpuS = 0.0, memory: UInt64 = 0, diskR = 0.0, diskW = 0.0
            var background = false
            var power = 0.0

            if ok {
                uid = all.pbsd.pbi_uid
                ppid = pid_t(all.pbsd.pbi_ppid)
                status = all.pbsd.pbi_status
                nice = all.pbsd.pbi_nice
                started = all.pbsd.pbi_start_tvsec
                threads = all.ptinfo.pti_threadnum
                // PROC_FLAG_DARWINBG (self) | PROC_FLAG_EXT_DARWINBG (set by another process).
                background = (all.pbsd.pbi_flags & 0x18000) != 0
                let name = String(cTuple: all.pbsd.pbi_name)
                comm = name.isEmpty ? String(cTuple: all.pbsd.pbi_comm) : name

                let userNs = MachTime.ns(all.ptinfo.pti_total_user)
                let systemNs = MachTime.ns(all.ptinfo.pti_total_system)
                var ru = rusage_info_v6()
                let ruOK = withUnsafeMutablePointer(to: &ru) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) == 0
                    }
                }
                let energy = ruOK ? ru.ri_energy_nj : 0
                memory = ruOK ? ru.ri_phys_footprint : all.ptinfo.pti_resident_size
                let read = ruOK ? ru.ri_diskio_bytesread : 0
                let write = ruOK ? ru.ri_diskio_byteswritten : 0
                if let p = previous[pid], dt > 0 {
                    cpuU = max(0, (userNs - p.userNs) / dt * 100)
                    cpuS = max(0, (systemNs - p.systemNs) / dt * 100)
                    let secs = dt / 1e9
                    diskR = read >= p.diskRead ? Double(read - p.diskRead) / secs : 0
                    diskW = write >= p.diskWrite ? Double(write - p.diskWrite) / secs : 0
                    power = energy >= p.energy ? Double(energy - p.energy) / 1e9 / secs : 0
                }
                nextPrevious[pid] = Previous(userNs: userNs, systemNs: systemNs, diskRead: read, diskWrite: write, energy: energy)
            } else {
                var short = proc_bsdshortinfo()
                let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) == shortSize else {
                    if pid != 0 { continue }   // exited between list and read
                    uid = 0; ppid = 0; status = 2; comm = "kernel_task"
                    restrictedPids.append(pid)
                    alive.insert(pid)
                    let st = staticInfo(pid: pid, started: 0, fallbackName: comm)
                    out.append(makeSample(pid: pid, ppid: ppid, uid: uid, status: status, nice: 0,
                                          threads: 0, started: 0, cpuU: 0, cpuS: 0, memory: 0, diskR: 0, diskW: 0,
                                          background: false, st: st, restricted: true, regularApps: regularApps,
                                          netRates: netRates, gpuPercent: gpuPercent))
                    continue
                }
                uid = short.pbsi_uid
                ppid = pid_t(short.pbsi_ppid)
                status = short.pbsi_status
                comm = String(cTuple: short.pbsi_comm)
                started = startCache[pid] ?? Self.startTime(pid)
                startCache[pid] = started
                restrictedPids.append(pid)
            }

            alive.insert(pid)
            let st = staticInfo(pid: pid, started: started, fallbackName: comm)
            var sample = makeSample(pid: pid, ppid: ppid, uid: uid, status: status, nice: nice,
                                    threads: threads, started: started, cpuU: cpuU, cpuS: cpuS, memory: memory,
                                    diskR: diskR, diskW: diskW, background: background, st: st, restricted: !ok,
                                    regularApps: regularApps, netRates: netRates, gpuPercent: gpuPercent)
            sample.power = power
            out.append(sample)
        }
        previous = nextPrevious

        // Fill CPU / memory for processes we may not inspect directly.
        if refreshRestricted && !restrictedPids.isEmpty {
            restricted = psFallback(pids: restrictedPids)
        }
        if !restricted.isEmpty {
            for i in out.indices where out[i].restricted {
                if let r = restricted[out[i].pid] {
                    out[i].cpu = r.cpu
                    out[i].cpuUser = r.user
                    out[i].cpuSystem = r.system
                    out[i].memory = r.rss
                    out[i].nice = r.nice
                }
            }
        }

        // Drop caches for exited processes.
        if statics.count > alive.count + 64 {
            statics = statics.filter { alive.contains($0.key) }
            startCache = startCache.filter { alive.contains($0.key) }
        }
        return out
    }

    // MARK: - Helpers

    private func listPids() -> [pid_t] {
        let needed = Int(proc_listallpids(nil, 0)) + 32
        if pidBuffer.count < needed { pidBuffer = [pid_t](repeating: 0, count: needed + 64) }
        let n = pidBuffer.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        return n > 0 ? Array(pidBuffer.prefix(Int(n))) : []
    }

    private func staticInfo(pid: pid_t, started: UInt64, fallbackName: String) -> Static {
        if let s = statics[pid], s.started == started { return s }
        var path = ""
        let len = pathBuffer.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        if len > 0 { path = String(cString: pathBuffer) }
        let base = path.isEmpty ? "" : (path as NSString).lastPathComponent
        let name = base.isEmpty ? fallbackName : base
        let s = Static(name: name, path: path, bundlePath: Self.outerBundle(path), started: started)
        statics[pid] = s
        return s
    }

    private func makeSample(pid: pid_t, ppid: pid_t, uid: uid_t, status: UInt32, nice: Int32,
                            threads: Int32, started: UInt64, cpuU: Double, cpuS: Double, memory: UInt64,
                            diskR: Double, diskW: Double, background: Bool, st: Static, restricted: Bool,
                            regularApps: [pid_t: RegularApp], netRates: [pid_t: Double],
                            gpuPercent: [pid_t: Double]) -> ProcessInfoSample {
        let app = regularApps[pid]
        let kind: ProcessKind
        if app != nil {
            kind = .app
        } else if uid == 0 || (uid < 500 && uid != currentUID)
                    || Self.systemPrefixes.contains(where: { st.path.hasPrefix($0) }) {
            kind = .system
        } else {
            kind = .background
        }
        return ProcessInfoSample(
            pid: pid, ppid: ppid, uid: uid, user: userName(uid),
            name: app?.name ?? st.name, path: st.path,
            bundlePath: app?.bundlePath ?? st.bundlePath,
            kind: kind, state: ProcessState(bsdStatus: status), nice: nice,
            started: started > 0 ? Date(timeIntervalSince1970: TimeInterval(started)) : nil,
            threads: threads, cpu: cpuU + cpuS, cpuUser: cpuU, cpuSystem: cpuS, memory: memory,
            diskReadPerSec: diskR, diskWritePerSec: diskW,
            netPerSec: netRates[pid] ?? 0, gpu: gpuPercent[pid] ?? 0,
            restricted: restricted, isRegularApp: app != nil, appName: app?.name, background: background)
    }

    private func userName(_ uid: uid_t) -> String {
        if let n = userNames[uid] { return n }
        var name = String(uid)
        if let pw = getpwuid(uid), let c = pw.pointee.pw_name { name = String(cString: c) }
        userNames[uid] = name
        return name
    }

    /// "/Applications/Foo.app/Contents/Frameworks/Bar.app/..." -> "/Applications/Foo.app"
    static func outerBundle(_ path: String) -> String {
        guard let r = path.range(of: ".app/") else {
            return path.hasSuffix(".app") ? path : ""
        }
        return String(path[..<path.index(r.lowerBound, offsetBy: 4)])
    }

    /// `/bin/ps` is setuid root, so it can read CPU / RSS for processes the
    /// kernel hides from us. One call for just the restricted pids (~20 ms).
    /// CPU is derived from cumulative user / total time deltas (like the
    /// direct path) rather than ps's decaying %CPU average.
    private func psFallback(pids: [pid_t]) -> [pid_t: Restricted] {
        let list = pids.map(String.init).joined(separator: ",")
        guard let out = Shell.capture("/bin/ps", ["-o", "pid=,rss=,nice=,utime=,time=", "-p", list]) else { return restricted }
        let now = DispatchTime.now().uptimeNanoseconds
        let secs = restrictedTime == 0 ? 0 : Double(now - restrictedTime) / 1e9
        restrictedTime = now
        var result: [pid_t: Restricted] = [:]
        var times: [pid_t: RestrictedTimes] = [:]
        result.reserveCapacity(pids.count)
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 5, let pid = pid_t(f[0]) else { continue }
            let t = RestrictedTimes(user: Self.cpuSeconds(f[3]), total: Self.cpuSeconds(f[4]))
            times[pid] = t
            var u = 0.0, sys = 0.0
            if let p = restrictedTimes[pid], secs > 0 {
                u = max(0, t.user - p.user) / secs * 100
                sys = max(0, (t.total - t.user) - (p.total - p.user)) / secs * 100
            }
            result[pid] = Restricted(cpu: u + sys, user: u, system: sys,
                                     rss: (UInt64(f[1]) ?? 0) * 1024, nice: Int32(f[2]) ?? 0)
        }
        restrictedTimes = times
        return result
    }

    /// Start time (Unix seconds) via sysctl — readable for every process,
    /// unlike libproc's task info for root / other users' processes.
    static func startTime(_ pid: pid_t) -> UInt64 {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return UInt64(max(0, info.kp_proc.p_starttime.tv_sec))
    }

    /// "[[dd-]hh:]mm:ss.cc" -> seconds
    static func cpuSeconds(_ s: Substring) -> Double {
        var days = 0.0
        var rest = s
        if let dash = s.firstIndex(of: "-") {
            days = Double(s[..<dash]) ?? 0
            rest = s[s.index(after: dash)...]
        }
        var total = 0.0
        for part in rest.split(separator: ":") { total = total * 60 + (Double(part) ?? 0) }
        return days * 86400 + total
    }
}
