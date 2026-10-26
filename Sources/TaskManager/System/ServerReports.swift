import Foundation

/// The Report tab for servers and containers: one reading a minute per
/// machine (averages and peaks of the readings in that minute), kept for 24
/// hours in ~/Library/Application Support/Apex Activity Manager/server-reports.json.
/// Apex reads every saved server and running container once a minute while
/// it's open, so a report only covers the time Apex was open.
struct ReportPoint: Codable, Sendable, Equatable {
    struct Proc: Codable, Sendable, Equatable { var name: String; var cpu: Double; var memory: Int64 }

    var t: Date                 // the minute it covers
    var cpu = 0.0, cpuPeak = 0.0
    var mem = 0.0, memPeak = 0.0
    var disk: Double?           // the fullest disk, % used (nil: size unknown)
    var diskMount: String?
    var netIn = 0.0, netOut = 0.0   // average bytes a second
    var uptime: Double?
    var top: [Proc] = []        // busiest this minute
    var failed: Int?            // failed services
    var down: Bool?             // couldn't be read in this minute
}

struct ReportMachine: Codable, Sendable {
    var name: String
    var isContainer: Bool       // a container on this Mac (not a saved server)
    var points: [ReportPoint]
}

/// One minute's readings, added up until the minute ends.
private struct MinuteBucket {
    var t: Date
    var name: String
    var isContainer: Bool
    var n = 0, failures = 0
    var cpu = 0.0, cpuPeak = 0.0, mem = 0.0, memPeak = 0.0
    var netIn = 0.0, netOut = 0.0
    var disk: Double?, diskMount: String?
    var uptime: Double?
    var failed: Int?
    var procs: [String: ReportPoint.Proc] = [:]

    var point: ReportPoint {
        guard n > 0 else { return ReportPoint(t: t, down: true) }
        let d = Double(n)
        let top = procs.values.sorted { $0.cpu > $1.cpu }.prefix(5)
        return ReportPoint(t: t, cpu: cpu / d, cpuPeak: cpuPeak, mem: mem / d, memPeak: memPeak, disk: disk, diskMount: diskMount,
                           netIn: netIn / d, netOut: netOut / d, uptime: uptime, top: Array(top), failed: failed)
    }
}

@MainActor @Observable
final class ServerReports {
    static let shared = ServerReports()
    static let keep: TimeInterval = 24 * 3600

    private(set) var machines: [UUID: ReportMachine] = [:]
    private var buckets: [UUID: MinuteBucket] = [:]
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private let url: URL?

    private init() {
        // Tests have no app bundle: nothing is read or saved.
        guard Bundle.main.bundleURL.pathExtension == "app" else { url = nil; return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apex Activity Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("server-reports.json")
        if let url, let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
            if let v = try? dec.decode([UUID: ReportMachine].self, from: d) { machines = v }
        }
    }

    static func minute(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded(.down) * 60) }

    func record(_ s: ServerConfig, _ snap: ServerSnapshot, at now: Date = Date()) {
        var b = bucket(s, now)
        b.n += 1
        b.cpu += snap.cpu.total; b.cpuPeak = max(b.cpuPeak, snap.cpu.total)
        b.mem += snap.memory.percent; b.memPeak = max(b.memPeak, snap.memory.percent)
        b.netIn += snap.network.reduce(0) { $0 + $1.inPerSec }
        b.netOut += snap.network.reduce(0) { $0 + $1.outPerSec }
        if let d = snap.disks.filter({ $0.total > 0 }).max(by: { $0.percent < $1.percent }) { b.disk = d.percent; b.diskMount = d.mount }
        b.uptime = snap.uptime
        if let v = snap.services { b.failed = v.filter(\.failed).count } else if let f = snap.failedServices { b.failed = f.count }
        for p in snap.processes where p.cpu > 0 || p.memory > 0 {
            var q = b.procs[p.name] ?? .init(name: p.name, cpu: 0, memory: 0)
            q.cpu = max(q.cpu, p.cpu); q.memory = max(q.memory, p.memory)
            b.procs[p.name] = q
        }
        // Only the busiest are kept, so a minute stays small.
        if b.procs.count > 40 { b.procs = Dictionary(uniqueKeysWithValues: b.procs.values.sorted { $0.cpu > $1.cpu }.prefix(20).map { ($0.name, $0) }) }
        buckets[s.id] = b
    }

    func recordDown(_ s: ServerConfig, at now: Date = Date()) {
        var b = bucket(s, now); b.failures += 1; buckets[s.id] = b
    }

    /// The bucket for this minute; a finished minute moves into the log.
    private func bucket(_ s: ServerConfig, _ now: Date) -> MinuteBucket {
        let m = Self.minute(now)
        if let b = buckets[s.id], b.t == m { return b }
        if let b = buckets[s.id] { append(s.id, b) }
        return MinuteBucket(t: m, name: s.name, isContainer: s.isLocal)
    }

    private func append(_ id: UUID, _ b: MinuteBucket) {
        var m = machines[id] ?? ReportMachine(name: b.name, isContainer: b.isContainer, points: [])
        m.name = b.name
        m.points.append(b.point)
        let cutoff = b.t.addingTimeInterval(-Self.keep)
        if let first = m.points.first, first.t < cutoff { m.points.removeAll { $0.t < cutoff } }
        machines[id] = m
        dirty = true
        if Date().timeIntervalSince(lastSave) > 300 { save() }
    }

    /// The saved minutes plus the one in progress, from `since`.
    func points(_ id: UUID, since: Date) -> [ReportPoint] {
        var p = (machines[id]?.points ?? []).filter { $0.t >= since }
        if let b = buckets[id], b.t >= since { p.append(b.point) }
        return p
    }

    func name(_ id: UUID) -> String? { machines[id]?.name ?? buckets[id]?.name }

    /// Every machine with readings: saved servers or containers.
    func ids(containers: Bool) -> [UUID] {
        var all = Set(machines.filter { $0.value.isContainer == containers }.keys)
        for (id, b) in buckets where b.isContainer == containers { all.insert(id) }
        return all.sorted { (name($0) ?? "") < (name($1) ?? "") }
    }

    func forget(_ id: UUID) { machines[id] = nil; buckets[id] = nil; dirty = true; save() }

    func save() {
        guard dirty, let url else { return }
        let cutoff = Date().addingTimeInterval(-Self.keep)
        for (id, m) in machines {
            var m = m; m.points.removeAll { $0.t < cutoff }
            machines[id] = m.points.isEmpty ? nil : m
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(machines) { try? d.write(to: url, options: .atomic) }
        dirty = false
        lastSave = Date()
    }
}

/// What a report says about one machine over a time range. Pure: tested.
struct ReportSummary {
    struct Event: Identifiable, Equatable {
        enum Level { case warning, critical, info }
        var id: String { "\(at.timeIntervalSince1970)-\(title)" }
        let at: Date
        let level: Level
        let title: String
        let detail: String
    }
    struct Busy: Identifiable, Equatable {
        var id: String { name }
        let name: String
        var minutes: Int
        var avgCPU: Double
        var peakCPU: Double
        var peakMemory: Int64
    }

    var minutesRead = 0
    var minutesDown = 0
    var first: Date?
    var cpuAvg = 0.0, cpuPeak = 0.0, cpuPeakAt: Date?
    var memAvg = 0.0, memPeak = 0.0, memPeakAt: Date?
    var disk: Double?, diskMount: String?, diskChange: Double?
    var received = 0.0, sent = 0.0
    var failedNow: Int?
    var events: [Event] = []
    var busiest: [Busy] = []

    /// Minutes in a row above this, at least this long, are worth telling.
    static let high = 90.0
    static let longEnough = 5

    static func make(_ points: [ReportPoint]) -> ReportSummary {
        var r = ReportSummary()
        let up = points.filter { $0.down != true }
        r.minutesRead = up.count
        r.minutesDown = points.count - up.count
        r.first = points.first?.t
        if !up.isEmpty {
            let n = Double(up.count)
            r.cpuAvg = up.reduce(0) { $0 + $1.cpu } / n
            r.memAvg = up.reduce(0) { $0 + $1.mem } / n
            if let p = up.max(by: { $0.cpuPeak < $1.cpuPeak }) { r.cpuPeak = p.cpuPeak; r.cpuPeakAt = p.t }
            if let p = up.max(by: { $0.memPeak < $1.memPeak }) { r.memPeak = p.memPeak; r.memPeakAt = p.t }
            r.received = up.reduce(0) { $0 + $1.netIn * 60 }
            r.sent = up.reduce(0) { $0 + $1.netOut * 60 }
            let disks = up.compactMap { p in p.disk.map { (p, $0) } }
            if let last = disks.last {
                r.disk = last.1; r.diskMount = last.0.diskMount
                if let f = disks.first, f.0.t < last.0.t { r.diskChange = last.1 - f.1 }
            }
            r.failedNow = up.last?.failed
        }

        // Long stretches of high CPU or memory, and times it couldn't be read.
        r.events += runs(points, { $0.down != true && $0.cpu >= high }, min: longEnough).map { a, b, len in
            Event(at: a, level: .warning, title: "CPU above \(Int(high))% for \(Fmt.minutes(len))",
                  detail: "From \(time(a)) to \(time(b.addingTimeInterval(60))). Peak \(Int(points.filter { $0.t >= a && $0.t <= b }.map(\.cpuPeak).max() ?? 0))%.")
        }
        r.events += runs(points, { $0.down != true && $0.mem >= high }, min: longEnough).map { a, b, len in
            Event(at: a, level: .warning, title: "Memory above \(Int(high))% for \(Fmt.minutes(len))",
                  detail: "From \(time(a)) to \(time(b.addingTimeInterval(60))). Programs may have been slowed or stopped.")
        }
        r.events += runs(points, { $0.down == true }, min: 1).map { a, b, len in
            Event(at: a, level: .critical, title: "Couldn’t be read for \(Fmt.minutes(len))",
                  detail: "From \(time(a)) to \(time(b.addingTimeInterval(60))). It was off, unreachable, or stopped.")
        }
        // Up-time going backwards means it started again.
        for (a, b) in zip(up, up.dropFirst()) {
            if let ua = a.uptime, let ub = b.uptime, ub + 120 < ua + b.t.timeIntervalSince(a.t) {
                let at = b.t.addingTimeInterval(30 - ub)
                r.events.append(Event(at: at, level: .info, title: "Restarted", detail: "Started again at \(time(at))."))
            }
        }
        if let d = r.disk, d >= high {
            r.events.append(Event(at: up.last?.t ?? Date(), level: d >= 95 ? .critical : .warning,
                                  title: "\(r.diskMount ?? "Disk") is \(Int(d))% full", detail: "Free up space before it fills."))
        }
        if let f = r.failedNow, f > 0 {
            r.events.append(Event(at: up.last?.t ?? Date(), level: .warning, title: "\(f) service\(f == 1 ? "" : "s") failed",
                                  detail: "See the Services tab for which, and restart them there."))
        }
        r.events.sort { $0.at > $1.at }

        // Busiest processes: how long each was among the busiest, and how busy.
        var busy: [String: Busy] = [:]
        for p in up {
            for q in p.top.prefix(3) where q.cpu >= 1 {
                var b = busy[q.name] ?? Busy(name: q.name, minutes: 0, avgCPU: 0, peakCPU: 0, peakMemory: 0)
                b.avgCPU = (b.avgCPU * Double(b.minutes) + q.cpu) / Double(b.minutes + 1)
                b.minutes += 1
                b.peakCPU = max(b.peakCPU, q.cpu); b.peakMemory = max(b.peakMemory, q.memory)
                busy[q.name] = b
            }
        }
        r.busiest = Array(busy.values.sorted { $0.avgCPU * Double($0.minutes) > $1.avgCPU * Double($1.minutes) }.prefix(8))
        return r
    }

    /// Stretches of minutes in a row (a gap of over 2 minutes ends one) where
    /// `test` holds, at least `min` long: (first minute, last minute, length).
    static func runs(_ points: [ReportPoint], _ test: (ReportPoint) -> Bool, min: Int) -> [(Date, Date, Int)] {
        var out: [(Date, Date, Int)] = []
        var start: ReportPoint?, last: ReportPoint?, len = 0
        func close() { if let s = start, let l = last, len >= min { out.append((s.t, l.t, len)) }; start = nil; last = nil; len = 0 }
        for p in points {
            if test(p) {
                if let l = last, p.t.timeIntervalSince(l.t) > 120 { close() }
                if start == nil { start = p }
                last = p; len += 1
            } else { close() }
        }
        close()
        return out
    }

    static func time(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
