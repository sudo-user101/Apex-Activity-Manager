import AppKit
import Foundation

/// Record: while it's on, everything Apex samples goes into a file, for
/// handing to an AI (or a person) to work out what the Mac was doing. The
/// window only shows that it's recording.
///
/// The file is JSON Lines in Documents › Apex Recordings: a first line that
/// describes the Mac and every field, one line per sample (the whole system,
/// plus every process doing something and the biggest by memory; the full
/// process list once a minute), alert events as they happen, and a summary
/// line (peaks, busiest and biggest processes) when it stops. About 15 MB
/// an hour. Nothing leaves the Mac.
/// What a recording covers: everything (the toolbar's Record), or one
/// Performance page's resource, each in its own folder.
enum RecordScope: String, CaseIterable, Sendable {
    case all, cpu, memory, disk, network, gpu, energy

    var folder: String {
        switch self {
        case .all: return "Everything"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        case .gpu: return "GPU"
        case .energy: return "Energy"
        }
    }

    /// The Record button's scope on a Performance page, if it has one.
    static func page(_ r: Resource) -> RecordScope? {
        switch r {
        case .cpu: return .cpu
        case .memory: return .memory
        case .disk: return .disk
        case .network: return .network
        case .gpu: return .gpu
        case .battery: return .energy
        case .cloud, .display, .sensors: return nil
        }
    }
}

@MainActor @Observable
final class Recorder {
    static let shared = Recorder()

    /// One recording, writing to its own file.
    struct Session {
        let scope: RecordScope
        let file: URL
        let started: Date
        var samples = 0
        var lastFullList = Date.distantPast
        var lastEvent: Date
        var summary = Summary()
    }

    private(set) var sessions: [RecordScope: Session] = [:]
    /// The last file written for each scope (to offer after stopping).
    private(set) var lastFiles: [RecordScope: (url: URL, samples: Int)] = [:]
    private(set) var error: String?
    var recording: Bool { !sessions.isEmpty }
    func isRecording(_ scope: RecordScope) -> Bool { sessions[scope] != nil }

    @ObservationIgnored private var handles: [RecordScope: FileHandle] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "apex.recorder", qos: .utility)

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apex Recordings", isDirectory: true)
    }

    func toggle(_ scope: RecordScope = .all) { isRecording(scope) ? stop(scope) : start(scope) }

    func start(_ scope: RecordScope = .all) {
        guard !isRecording(scope) else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dir = Self.folder.appendingPathComponent(scope.folder, isDirectory: true)
        let name = scope == .all ? "Apex Recording" : "Apex \(scope.folder) Recording"
        let url = dir.appendingPathComponent("\(name) \(f.string(from: Date())).jsonl")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handles[scope] = try FileHandle(forWritingTo: url)
        } catch {
            self.error = "Couldn’t create the recording: \(error.localizedDescription)"
            return
        }
        error = nil
        let now = Date()
        sessions[scope] = Session(scope: scope, file: url, started: now, lastEvent: now)
        var h = Self.header(AppModel.shared.snapshot, started: now)
        h["covers"] = scope == .all ? "everything" : scope.folder
        write(h, to: scope)
        AppModel.shared.recordingChanged()
    }

    func stop(_ scope: RecordScope = .all) {
        guard let s = sessions[scope], let h = handles[scope] else { return }
        sessions[scope] = nil
        write(s.summary.line(started: s.started, ended: Date(), samples: s.samples), to: scope, handle: h)
        queue.sync { try? h.close() }      // after every queued line, even when Apex is quitting
        handles[scope] = nil
        lastFiles[scope] = (s.file, s.samples)
        AppModel.shared.recordingChanged()
    }

    func stopAll() { for scope in sessions.keys { stop(scope) } }

    /// Called with every sample while recording.
    func record(_ s: Snapshot) {
        guard recording else { return }
        let battery = HardwareStore.shared.hasBattery ? HardwareStore.shared.battery : nil
        for (scope, var session) in sessions {
            let full = s.date.timeIntervalSince(session.lastFullList) >= 60
            if full { session.lastFullList = s.date }
            write(Self.sampleLine(s, allProcesses: full, battery: battery, scope: scope), to: scope)
            let fresh = EventLog.shared.events.filter { $0.date > session.lastEvent }
            if let newest = fresh.map(\.date).max() { session.lastEvent = newest }
            for e in fresh.sorted(by: { $0.date < $1.date }) {
                write(["type": "event", "time": Self.iso(e.date), "title": e.title], to: scope)
            }
            session.summary.add(s)
            session.samples += 1
            sessions[scope] = session
        }
    }

    private func write(_ object: [String: Any], to scope: RecordScope, handle: FileHandle? = nil) {
        guard let h = handle ?? handles[scope],
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        queue.async { try? h.write(contentsOf: data) }
    }

    // MARK: Lines (pure: tested)

    nonisolated static func iso(_ d: Date) -> String { d.formatted(.iso8601) }

    nonisolated static func header(_ s: Snapshot, started: Date) -> [String: Any] {
        let sys = s.system
        return [
            "type": "header",
            "app": "Apex Activity Manager",
            "started": iso(started),
            "mac": [
                "model": Sysctl.string("hw.model") ?? "",
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "cpu": sys.cpu.brand,
                "cores": ["logical": sys.cpu.logicalCores, "performance": sys.cpu.performanceCores, "efficiency": sys.cpu.efficiencyCores],
                "memoryBytes": sys.memory.total,
                "gpu": sys.gpu.model,
                "startupDiskBytes": sys.disk.capacity,
            ] as [String: Any],
            "format": [
                "lines": "One JSON object per line. type = header (this), sample, event (an Apex alert) or summary (written when recording stops).",
                "time": "ISO 8601, local clock.",
                "cpu": "Percent. system.cpu.total is the whole Mac (0-100). A process's cpu is percent of ONE core (can exceed 100).",
                "memory": "Bytes. pressure is macOS's memory pressure: Normal, Elevated or Critical.",
                "rates": "Bytes per second (disk, network, swap).",
                "processes": "Each sample lists processes doing something (CPU >= 0.5 %, disk, network or GPU) plus the 15 largest by memory. Every 60 s the sample has allProcesses: true and lists every process.",
                "power": "Watts, where the Mac reports it (laptops). batteryFlowW: + charging, - draining.",
                "kind": "app (has a Dock icon), background, system.",
            ] as [String: Any],
        ]
    }

    /// One sample, keeping only what `scope` covers: its part of the system
    /// and, per process, the figures for it. Pure: tested.
    nonisolated static func sampleLine(_ s: Snapshot, allProcesses: Bool, battery: BatteryInfo?, scope: RecordScope) -> [String: Any] {
        var line = sampleLine(s, allProcesses: allProcesses, battery: battery)
        guard scope != .all else { return line }
        let keep: [String]
        switch scope {
        case .cpu: keep = ["cpu", "thermal", "processCount", "threadCount"]
        case .memory: keep = ["memory"]
        case .disk: keep = ["disk"]
        case .network: keep = ["network"]
        case .gpu: keep = ["gpu", "thermal"]
        case .energy: keep = ["power", "battery", "thermal"]
        case .all: keep = []
        }
        if let sys = line["system"] as? [String: Any] { line["system"] = sys.filter { keep.contains($0.key) } }
        // The processes that matter for this resource, with only its figures.
        let ps = s.processes
        let picked: [ProcessInfoSample]
        let fields: [String]
        switch scope {
        case .cpu: picked = allProcesses ? ps : ps.filter { $0.cpu >= 0.5 }; fields = ["cpu", "threads"]
        case .memory: picked = allProcesses ? ps : Array(ps.sorted { $0.memory > $1.memory }.prefix(30)); fields = ["memory"]
        case .disk: picked = allProcesses ? ps : ps.filter { $0.diskReadPerSec + $0.diskWritePerSec > 0 }; fields = ["diskReadPerSec", "diskWritePerSec"]
        case .network: picked = allProcesses ? ps : ps.filter { $0.netPerSec > 0 }; fields = ["netPerSec"]
        case .gpu: picked = allProcesses ? ps : ps.filter { $0.gpu > 0 }; fields = ["gpu"]
        case .energy: picked = allProcesses ? ps : Array(ps.filter { $0.power > 0 }.sorted { $0.power > $1.power }.prefix(30)); fields = ["powerW"]
        case .all: picked = ps; fields = []
        }
        let base = ["pid", "name", "kind", "ppid"]
        line["processes"] = picked.map { processLine($0).filter { base.contains($0.key) || fields.contains($0.key) } }
        return line
    }

    nonisolated static func sampleLine(_ s: Snapshot, allProcesses: Bool, battery: BatteryInfo?) -> [String: Any] {
        let sys = s.system
        var system: [String: Any] = [
            "cpu": ["total": r(sys.cpu.total), "user": r(sys.cpu.user), "system": r(sys.cpu.system),
                    "perCore": sys.cpu.perCore.map(r), "load": sys.cpu.loadAverage.map { r($0) }] as [String: Any],
            "memory": ["used": sys.memory.used, "app": sys.memory.app, "wired": sys.memory.wired,
                       "compressed": sys.memory.compressed, "cached": sys.memory.cached, "free": sys.memory.free,
                       "swapUsed": sys.memory.swapUsed, "swapInPerSec": r(sys.memory.swapInPerSec),
                       "swapOutPerSec": r(sys.memory.swapOutPerSec), "pressure": sys.memory.pressureLevel.title,
                       "pressurePercent": r(sys.memory.pressure)] as [String: Any],
            "disk": ["readPerSec": r(sys.disk.readPerSec), "writePerSec": r(sys.disk.writePerSec),
                     "readOpsPerSec": r(sys.disk.readOpsPerSec), "writeOpsPerSec": r(sys.disk.writeOpsPerSec),
                     "freeBytes": sys.disk.available] as [String: Any],
            "network": ["inPerSec": r(sys.network.inPerSec), "outPerSec": r(sys.network.outPerSec),
                        "interface": sys.network.interface] as [String: Any],
            "thermal": thermal(sys.thermal),
            "processCount": sys.processCount, "threadCount": sys.threadCount,
        ]
        var gpu: [String: Any] = [:]
        if let u = sys.gpu.utilization { gpu["utilization"] = r(u) }
        if let m = sys.gpu.memoryInUse { gpu["memoryInUse"] = m }
        if !gpu.isEmpty { system["gpu"] = gpu }
        var power: [String: Any] = [:]
        if let w = sys.systemPower { power["macW"] = r(w) }
        if let w = sys.chargerPower { power["chargerW"] = r(w) }
        if let w = sys.batteryFlow { power["batteryFlowW"] = r(w) }
        if !power.isEmpty { system["power"] = power }
        if let b = battery { system["battery"] = ["percent": b.percent, "onPower": b.onAC] as [String: Any] }

        let procs = allProcesses ? s.processes : interesting(s.processes)
        return [
            "type": "sample",
            "time": iso(s.date),
            "system": system,
            "allProcesses": allProcesses,
            "processes": procs.map(processLine),
        ]
    }

    /// Doing something, plus the 15 biggest by memory.
    nonisolated static func interesting(_ ps: [ProcessInfoSample]) -> [ProcessInfoSample] {
        let active = ps.filter { $0.cpu >= 0.5 || $0.diskReadPerSec + $0.diskWritePerSec > 0 || $0.netPerSec > 0 || $0.gpu >= 0.5 }
        let big = ps.sorted { $0.memory > $1.memory }.prefix(15)
        var seen = Set<pid_t>()
        return (active + big).filter { seen.insert($0.pid).inserted }
    }

    nonisolated static func processLine(_ p: ProcessInfoSample) -> [String: Any] {
        var o: [String: Any] = ["pid": Int(p.pid), "name": p.name, "cpu": r(p.cpu), "memory": p.memory,
                                "kind": p.kind == .app ? "app" : p.kind == .system ? "system" : "background"]
        if p.ppid > 1 { o["ppid"] = Int(p.ppid) }
        if p.diskReadPerSec > 0 { o["diskReadPerSec"] = r(p.diskReadPerSec) }
        if p.diskWritePerSec > 0 { o["diskWritePerSec"] = r(p.diskWritePerSec) }
        if p.netPerSec > 0 { o["netPerSec"] = r(p.netPerSec) }
        if p.gpu > 0 { o["gpu"] = r(p.gpu) }
        if p.power > 0 { o["powerW"] = r(p.power) }
        if p.threads > 0 { o["threads"] = Int(p.threads) }
        if p.state == .stopped { o["paused"] = true }
        if p.background { o["optimized"] = true }
        if p.user != NSUserName() { o["user"] = p.user }
        return o
    }

    nonisolated static func thermal(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "normal"
        case .fair: return "warm"
        case .serious: return "hot (slowing down)"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Two decimals: enough for every reading, half the file size.
    nonisolated static func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// Peaks and the processes that stood out, for the closing line.
    struct Summary {
        var maxCPU = (value: 0.0, time: Date.distantPast)
        var maxMemory = (value: UInt64(0), time: Date.distantPast)
        var maxSwap: UInt64 = 0
        var worstPressure = PressureLevel.normal
        var hottest = ProcessInfo.ThermalState.nominal
        var cpuSum = 0.0, count = 0
        var procs: [String: (cpuSum: Double, samples: Int, peakMemory: UInt64)] = [:]

        mutating func add(_ s: Snapshot) {
            let sys = s.system
            if sys.cpu.total > maxCPU.value { maxCPU = (sys.cpu.total, s.date) }
            if sys.memory.used > maxMemory.value { maxMemory = (sys.memory.used, s.date) }
            maxSwap = max(maxSwap, sys.memory.swapUsed)
            if sys.memory.pressureLevel.rawValue > worstPressure.rawValue { worstPressure = sys.memory.pressureLevel }
            if sys.thermal.rawValue > hottest.rawValue { hottest = sys.thermal }
            cpuSum += sys.cpu.total; count += 1
            for p in s.processes {
                var e = procs[p.name] ?? (0, 0, 0)
                e.cpuSum += p.cpu; e.samples += 1; e.peakMemory = max(e.peakMemory, p.memory)
                procs[p.name] = e
            }
        }

        func line(started: Date, ended: Date, samples: Int) -> [String: Any] {
            let n = Double(max(1, count))
            let busiest = procs.sorted { $0.value.cpuSum > $1.value.cpuSum }.prefix(10)
                .map { ["name": $0.key, "averageCPU": r($0.value.cpuSum / n)] as [String: Any] }
            let biggest = procs.sorted { $0.value.peakMemory > $1.value.peakMemory }.prefix(10)
                .map { ["name": $0.key, "peakMemory": $0.value.peakMemory] as [String: Any] }
            return [
                "type": "summary",
                "started": iso(started), "ended": iso(ended),
                "seconds": Int(ended.timeIntervalSince(started)), "samples": samples,
                "cpu": ["average": r(cpuSum / n), "peak": r(maxCPU.value), "peakTime": iso(maxCPU.time)] as [String: Any],
                "memory": ["peakUsed": maxMemory.value, "peakTime": iso(maxMemory.time), "peakSwap": maxSwap,
                           "worstPressure": worstPressure.title] as [String: Any],
                "thermalWorst": thermal(hottest),
                "busiestProcesses": busiest,
                "biggestProcesses": biggest,
            ]
        }
    }
}
