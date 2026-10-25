import Foundation

// Apex's detection engine: samples in, events out.
//
// Pure value types with no AppKit, no clock and no I/O: time comes only from
// each sample's date, so the same rules can be unit-tested, replayed, and later
// run against samples from remote machines.

// MARK: Input

public struct AppLoad: Sendable, Equatable {
    public var key: String           // stable app identity (bundle path or "n:name")
    public var name: String
    public var cpu: Double           // % of one core, summed over the app's processes
    public var diskWritePerSec: Double
    public var netPerSec: Double     // sent + received; 0 when per-app traffic isn't being measured
    public var memory: UInt64        // footprint, summed over the app's processes
    public var pids: [Int32]
    public init(key: String, name: String, cpu: Double, diskWritePerSec: Double = 0, netPerSec: Double = 0,
                memory: UInt64 = 0, pids: [Int32] = []) {
        self.key = key; self.name = name; self.cpu = cpu; self.diskWritePerSec = diskWritePerSec
        self.netPerSec = netPerSec; self.memory = memory; self.pids = pids
    }
}

public enum PressureState: Int, Sendable, Codable, Comparable {
    case normal, warning, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum ThermalState: Int, Sendable, Codable, Comparable {
    case nominal, fair, serious, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct DetectionSample: Sendable {
    public var date: Date
    public var apps: [AppLoad]
    public var pressure: PressureState
    public var memoryUsedPercent: Double
    public var swapUsed: UInt64
    public var memoryTotal: UInt64
    public var thermal: ThermalState
    public var diskAvailable: UInt64
    public var diskCapacity: UInt64
    public var volumeName: String
    public var diskWritePerSec: Double
    public var networkPerSec: Double     // received + sent, all interfaces

    public init(date: Date, apps: [AppLoad] = [], pressure: PressureState = .normal, memoryUsedPercent: Double = 0,
                swapUsed: UInt64 = 0, memoryTotal: UInt64 = 0, thermal: ThermalState = .nominal, diskAvailable: UInt64 = 0,
                diskCapacity: UInt64 = 0, volumeName: String = "Macintosh HD", diskWritePerSec: Double = 0,
                networkPerSec: Double = 0) {
        self.date = date; self.apps = apps; self.pressure = pressure; self.memoryUsedPercent = memoryUsedPercent
        self.swapUsed = swapUsed; self.memoryTotal = memoryTotal; self.thermal = thermal; self.diskAvailable = diskAvailable
        self.diskCapacity = diskCapacity; self.volumeName = volumeName; self.diskWritePerSec = diskWritePerSec
        self.networkPerSec = networkPerSec
    }
}

// MARK: Output

public enum Severity: String, Sendable, Codable, Comparable, CaseIterable {
    case info, warning, critical
    private var rank: Int { self == .info ? 0 : self == .warning ? 1 : 2 }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public enum Rule: String, Sendable, Codable, CaseIterable {
    case appCPU, memoryPressure, thermal, diskSpace, diskFilling, diskWrites, memoryGrowth, swapGrowth, driveHealth, network
    public var title: String {
        switch self {
        case .driveHealth: return "Drive health"
        case .appCPU: return "High app CPU"
        case .memoryPressure: return "Memory pressure"
        case .memoryGrowth: return "Memory keeps growing"
        case .swapGrowth: return "Swap growing"
        case .thermal: return "Heat"
        case .diskSpace: return "Low disk space"
        case .diskFilling: return "Disk filling fast"
        case .diskWrites: return "Heavy disk writing"
        case .network: return "Heavy network traffic"
        }
    }
}

/// Sustained = held long enough to alert. Spike = went over but recovered
/// before that (recorded, never notified). Instant = a state, not a trend.
public enum EventKind: String, Sendable, Codable { case sustained, spike, instant }

public struct Evidence: Sendable, Codable, Equatable {
    public var label: String
    public var value: String
    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

public struct DetectionEvent: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var rule: Rule
    public var key: String           // dedupe / cooldown identity, e.g. "appCPU:/Applications/X.app"
    public var date: Date            // when it was detected
    public var started: Date         // when the condition began
    public var severity: Severity
    public var kind: EventKind
    public var title: String
    public var summary: String
    /// Plain-language "why this fired": the rule and the numbers that met it.
    public var reason: String
    public var evidence: [Evidence]
    public var subject: String?      // app name, volume…
    public var pids: [Int32]
    public var notify: Bool
    /// Optional values behind the event, evenly spaced from `started` to `date`
    /// (e.g. an app's memory, one point a minute) for a small chart.
    public var series: [Double]?

    public init(id: UUID = UUID(), rule: Rule, key: String, date: Date, started: Date, severity: Severity, kind: EventKind,
                title: String, summary: String, reason: String, evidence: [Evidence], subject: String? = nil,
                pids: [Int32] = [], notify: Bool, series: [Double]? = nil) {
        self.id = id; self.rule = rule; self.key = key; self.date = date; self.started = started
        self.severity = severity; self.kind = kind; self.title = title; self.summary = summary; self.reason = reason
        self.evidence = evidence; self.subject = subject; self.pids = pids; self.notify = notify; self.series = series
    }
}

// MARK: Settings

public struct DetectionSettings: Sendable, Codable, Equatable {
    public var appCPU = true
    public var cpuThreshold: Double = 80          // % of one core
    public var cpuMinutes: Double = 3
    public var memory = true
    public var heat = true
    public var disk = true
    public var diskWrites = true
    public var writeThreshold: Double = 100_000_000   // bytes/s
    public var writeMinutes: Double = 2
    /// Keep short spikes in the event history (never notified).
    public var recordSpikes = true
    /// Apps whose memory climbs steadily (possible leak), and swap growing fast.
    public var memoryGrowth = true
    /// Record heavy network traffic (sent + received) in History.
    public var network = true
    public var networkThreshold: Double = 10_000_000  // bytes/s
    public var networkMinutes: Double = 2
    public init() {}

    // Decode older saved settings that lack newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DetectionSettings()
        appCPU = try c.decodeIfPresent(Bool.self, forKey: .appCPU) ?? d.appCPU
        cpuThreshold = try c.decodeIfPresent(Double.self, forKey: .cpuThreshold) ?? d.cpuThreshold
        cpuMinutes = try c.decodeIfPresent(Double.self, forKey: .cpuMinutes) ?? d.cpuMinutes
        memory = try c.decodeIfPresent(Bool.self, forKey: .memory) ?? d.memory
        heat = try c.decodeIfPresent(Bool.self, forKey: .heat) ?? d.heat
        disk = try c.decodeIfPresent(Bool.self, forKey: .disk) ?? d.disk
        diskWrites = try c.decodeIfPresent(Bool.self, forKey: .diskWrites) ?? d.diskWrites
        writeThreshold = try c.decodeIfPresent(Double.self, forKey: .writeThreshold) ?? d.writeThreshold
        writeMinutes = try c.decodeIfPresent(Double.self, forKey: .writeMinutes) ?? d.writeMinutes
        recordSpikes = try c.decodeIfPresent(Bool.self, forKey: .recordSpikes) ?? d.recordSpikes
        memoryGrowth = try c.decodeIfPresent(Bool.self, forKey: .memoryGrowth) ?? d.memoryGrowth
        network = try c.decodeIfPresent(Bool.self, forKey: .network) ?? d.network
        networkThreshold = try c.decodeIfPresent(Double.self, forKey: .networkThreshold) ?? d.networkThreshold
        networkMinutes = try c.decodeIfPresent(Double.self, forKey: .networkMinutes) ?? d.networkMinutes
    }
}

// MARK: Spike vs sustained

/// Tracks one condition over time. Brief dips shorter than `grace` don't
/// break an episode (so a 3-minute CPU burn with one quiet sample still
/// counts), and the episode's peak and average are kept as evidence.
public struct Sustained: Sendable, Equatable {
    public struct Episode: Sendable, Equatable {
        public var start: Date, end: Date, peak: Double, average: Double
        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }
    public var grace: TimeInterval
    public private(set) var start: Date?
    private var lastActive: Date?
    private var lastSeen: Date?
    private var peak = 0.0, sum = 0.0, count = 0
    public private(set) var fired = false

    public init(grace: TimeInterval = 10) { self.grace = grace }

    public var isActive: Bool { start != nil }

    /// Feeds one sample. Returns the finished episode when it ends.
    /// Each sample stands for the interval since the previous one, so an
    /// episode starts one sample step before its first active sample (capped,
    /// so a gap after sleep doesn't count). This keeps durations right when
    /// Apex samples slowly in the background (every 10 s).
    public mutating func update(active: Bool, value: Double, at now: Date) -> Episode? {
        let step = lastSeen.map { min(max(now.timeIntervalSince($0), 0), Self.maxStep) } ?? 0
        lastSeen = now
        if active {
            if start == nil { start = now.addingTimeInterval(-step); peak = value; sum = 0; count = 0; fired = false }
            lastActive = now
            peak = max(peak, value); sum += value; count += 1
            return nil
        }
        guard let s = start, let last = lastActive else { return nil }
        if now.timeIntervalSince(last) <= grace { return nil }     // a brief dip
        let ep = Episode(start: s, end: last, peak: peak, average: count > 0 ? sum / Double(count) : 0)
        reset()
        return ep
    }

    /// The running episode (for "has it lasted long enough?").
    public func current(at now: Date) -> Episode? {
        guard let s = start, let last = lastActive else { return nil }
        return Episode(start: s, end: max(last, now), peak: peak, average: count > 0 ? sum / Double(count) : 0)
    }

    public static let maxStep: TimeInterval = 10
    public mutating func markFired() { fired = true }
    public mutating func reset() { start = nil; lastActive = nil; peak = 0; sum = 0; count = 0; fired = false }
}

// MARK: Engine

public struct DetectionEngine: Sendable {
    public var settings: DetectionSettings
    public var formatValue: @Sendable (Rule, Double) -> String

    private var appCPU: [String: Sustained] = [:]
    private var appNames: [String: (String, [Int32])] = [:]
    private var critical = Sustained(grace: 5)
    private var pressureWarning = Sustained(grace: 15)
    private var hot = Sustained(grace: 10)
    private var writes = Sustained(grace: 10)
    private var traffic = Sustained(grace: 10)
    private var diskTrail: [(Date, UInt64)] = []
    private var memoryTrails: [String: [(Date, Double)]] = [:]
    private var swapTrail: [(Date, UInt64)] = []
    private var lastFired: [String: Date] = [:]

    // Durations (seconds).
    public static let memoryCriticalAfter: TimeInterval = 30
    public static let memoryWarningAfter: TimeInterval = 300
    public static let heatAfter: TimeInterval = 30
    public static let lowDiskBytes: UInt64 = 10_000_000_000
    public static let veryLowDiskBytes: UInt64 = 2_000_000_000
    public static let fillingBytes: UInt64 = 5_000_000_000
    public static let fillingWindow: TimeInterval = 600
    // Memory growth (leak): one point a minute, judged over 30–60 minutes.
    public static let growthPointEvery: TimeInterval = 60
    public static let growthWindow: TimeInterval = 3600
    public static let growthMinSpan: TimeInterval = 1800
    public static let growthMinBytes: Double = 500_000_000
    public static let growthMinRatio = 0.5          // grew by at least half its starting size
    public static let growthMinFit = 0.8            // steady climb, not spikes (R²)
    public static let growthTrackFrom: UInt64 = 150_000_000
    // Swap growth: +1 GB within 15 minutes.
    public static let swapGrowthBytes: UInt64 = 1_000_000_000
    public static let swapWindow: TimeInterval = 900
    /// Shortest over-threshold run worth recording as a spike, per rule.
    static func minSpike(_ r: Rule) -> TimeInterval {
        switch r { case .appCPU: return 30; case .diskWrites, .network: return 20; default: return 0 }
    }
    static func cooldown(_ r: Rule, _ kind: EventKind) -> TimeInterval {
        if kind == .spike { return 600 }
        switch r {
        case .appCPU, .memoryPressure: return 1800
        case .thermal, .diskFilling, .diskWrites, .network, .swapGrowth: return 3600
        case .memoryGrowth: return 6 * 3600
        case .diskSpace, .driveHealth: return 86400
        }
    }

    public init(settings: DetectionSettings = DetectionSettings(),
                formatValue: @escaping @Sendable (Rule, Double) -> String = { _, v in String(format: "%.0f", v) }) {
        self.settings = settings
        self.formatValue = formatValue
    }

    public mutating func evaluate(_ s: DetectionSample) -> [DetectionEvent] {
        var out: [DetectionEvent] = []
        let now = s.date
        if settings.appCPU { evaluateApps(s, &out) } else { appCPU.removeAll() }
        if settings.memory { evaluateMemory(s, &out) } else { critical.reset(); pressureWarning.reset() }
        if settings.heat { evaluateHeat(s, &out) } else { hot.reset() }
        if settings.disk { evaluateDisk(s, &out) } else { diskTrail.removeAll() }
        if settings.diskWrites { evaluateWrites(s, &out) } else { writes.reset() }
        if settings.network { evaluateNetwork(s, &out) } else { traffic.reset() }
        if settings.memoryGrowth { evaluateGrowth(s, &out); evaluateSwap(s, &out) } else { memoryTrails.removeAll(); swapTrail.removeAll() }
        return out.filter { e in
            if let last = lastFired[e.key], now.timeIntervalSince(last) < Self.cooldown(e.rule, e.kind) { return false }
            lastFired[e.key] = now
            return true
        }
    }

    private func f(_ r: Rule, _ v: Double) -> String { formatValue(r, v) }
    private static func dur(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
    private static let clock: DateFormatter = { let d = DateFormatter(); d.dateFormat = "HH:mm:ss"; return d }()
    private static func time(_ d: Date) -> String { clock.string(from: d) }

    // 1. An app using lots of CPU for a while.
    private mutating func evaluateApps(_ s: DetectionSample, _ out: inout [DetectionEvent]) {
        let need = settings.cpuMinutes * 60
        let byKey = Dictionary(s.apps.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for a in s.apps { appNames[a.key] = (a.name, a.pids) }
        for key in Set(appCPU.keys).union(byKey.keys) {
            let load = byKey[key]?.cpu ?? 0
            var t = appCPU[key] ?? Sustained(grace: 10)
            let (name, pids) = appNames[key] ?? (key, [])
            let wasFired = t.fired
            if let ep = t.update(active: load >= settings.cpuThreshold, value: load, at: s.date) {
                if !wasFired, settings.recordSpikes, ep.duration >= Self.minSpike(.appCPU), ep.duration < need {
                    out.append(event(.appCPU, key: "spike:appCPU:\(key)", s.date, ep, .info, .spike,
                        title: "\(name) briefly used a lot of CPU",
                        summary: "Up to \(f(.appCPU, ep.peak)) for \(Self.dur(ep.duration)), then settled.",
                        reason: "Went over your \(f(.appCPU, settings.cpuThreshold)) threshold but recovered before \(Self.dur(need)), so no alert was sent.",
                        subject: name, pids: pids, notify: false))
                }
            }
            if !t.fired, let ep = t.current(at: s.date), ep.duration >= need {
                t.markFired()
                out.append(event(.appCPU, key: "appCPU:\(key)", s.date, ep, .warning, .sustained,
                    title: "\(name) is using a lot of CPU",
                    summary: "\(f(.appCPU, load)) now, averaging \(f(.appCPU, ep.average)) for \(Self.dur(ep.duration)).",
                    reason: "Stayed above your \(f(.appCPU, settings.cpuThreshold)) threshold for \(Self.dur(ep.duration)) (alert after \(Self.dur(need))). Short spikes don’t alert.",
                    subject: name, pids: pids, notify: true))
            }
            if t.isActive { appCPU[key] = t } else { appCPU[key] = nil; if byKey[key] == nil { appNames[key] = nil } }
        }
    }

    // 2. Memory pressure: critical for 30 s alerts; yellow for 5 min is recorded.
    private mutating func evaluateMemory(_ s: DetectionSample, _ out: inout [DetectionEvent]) {
        let swap = Evidence("Swap used", f(.diskSpace, Double(s.swapUsed)))
        let critFired = critical.fired
        if let ep = critical.update(active: s.pressure == .critical, value: s.memoryUsedPercent, at: s.date),
           !critFired, settings.recordSpikes, ep.duration < Self.memoryCriticalAfter {
            out.append(event(.memoryPressure, key: "spike:memory", s.date, ep, .info, .spike,
                title: "Memory pressure briefly went critical",
                summary: "Critical for \(Self.dur(ep.duration)), then recovered.",
                reason: "macOS reported critical memory pressure for less than \(Self.dur(Self.memoryCriticalAfter)), so no alert was sent.",
                extra: [swap], notify: false))
        }
        if !critical.fired, let ep = critical.current(at: s.date), ep.duration >= Self.memoryCriticalAfter {
            critical.markFired()
            out.append(event(.memoryPressure, key: "memory:critical", s.date, ep, .critical, .sustained,
                title: "Your Mac is running out of memory",
                summary: "Memory pressure has been critical for \(Self.dur(ep.duration)). Free up memory to keep things responsive.",
                reason: "macOS reported critical (red) memory pressure for \(Self.dur(ep.duration)); Apex alerts after \(Self.dur(Self.memoryCriticalAfter)).",
                extra: [swap], notify: true))
        }
        _ = pressureWarning.update(active: s.pressure >= .warning, value: s.memoryUsedPercent, at: s.date)
        if !pressureWarning.fired, let ep = pressureWarning.current(at: s.date), ep.duration >= Self.memoryWarningAfter {
            pressureWarning.markFired()
            out.append(event(.memoryPressure, key: "memory:warning", s.date, ep, .warning, .sustained,
                title: "Memory pressure has been elevated for a while",
                summary: "Elevated (yellow) for \(Self.dur(ep.duration)). Your Mac is relying on compression and swap, but it isn’t critical.",
                reason: "Memory pressure stayed elevated (yellow) or above for \(Self.dur(ep.duration)); this is recorded after \(Self.dur(Self.memoryWarningAfter)). Only critical (red) pressure sends an alert.",
                extra: [swap], notify: false))
        }
    }

    // 3. Running hot (macOS thermal state).
    private mutating func evaluateHeat(_ s: DetectionSample, _ out: inout [DetectionEvent]) {
        let level = Double(s.thermal.rawValue)
        let hotFired = hot.fired
        if let ep = hot.update(active: s.thermal >= .serious, value: level, at: s.date),
           !hotFired, settings.recordSpikes, ep.duration < Self.heatAfter {
            out.append(event(.thermal, key: "spike:heat", s.date, ep, .info, .spike,
                title: "Your Mac briefly ran hot",
                summary: "macOS throttled for \(Self.dur(ep.duration)), then cooled down.",
                reason: "The thermal state was serious or critical for less than \(Self.dur(Self.heatAfter)).",
                notify: false))
        }
        if !hot.fired, let ep = hot.current(at: s.date), ep.duration >= Self.heatAfter {
            hot.markFired()
            let worst = ep.peak >= Double(ThermalState.critical.rawValue)
            out.append(event(.thermal, key: "heat", s.date, ep, worst ? .critical : .warning, .sustained,
                title: "Your Mac is running hot",
                summary: "macOS is slowing things down to cool off. Check which apps use the most CPU.",
                reason: "macOS’s thermal state has been \(worst ? "critical" : "serious") for \(Self.dur(ep.duration)) (alert after \(Self.dur(Self.heatAfter))).",
                notify: true))
        }
    }

    // 4. Low space, and space disappearing fast.
    private mutating func evaluateDisk(_ s: DetectionSample, _ out: inout [DetectionEvent]) {
        guard s.diskCapacity > 0 else { return }
        let left = Evidence("Available", f(.diskSpace, Double(s.diskAvailable)))
        let cap = Evidence("Capacity", f(.diskSpace, Double(s.diskCapacity)))
        if s.diskAvailable < Self.lowDiskBytes {
            let very = s.diskAvailable < Self.veryLowDiskBytes
            out.append(DetectionEvent(rule: .diskSpace, key: "disk:low", date: s.date, started: s.date,
                severity: very ? .critical : .warning, kind: .instant,
                title: "Your disk is almost full",
                summary: "Only \(f(.diskSpace, Double(s.diskAvailable))) left on \(s.volumeName).",
                reason: "Free space is below \(f(.diskSpace, Double(Self.lowDiskBytes))). macOS needs room for swap, updates and caches.",
                evidence: [left, cap, Evidence("Free", String(format: "%.1f%%", Double(s.diskAvailable) / Double(s.diskCapacity) * 100))],
                subject: s.volumeName, notify: true))
        }
        diskTrail.append((s.date, s.diskAvailable))
        diskTrail.removeAll { s.date.timeIntervalSince($0.0) > Self.fillingWindow }
        if let most = diskTrail.max(by: { $0.1 < $1.1 }), most.1 > s.diskAvailable, most.1 - s.diskAvailable >= Self.fillingBytes {
            let used = most.1 - s.diskAvailable
            let over = s.date.timeIntervalSince(most.0)
            let writers = s.apps.filter { $0.diskWritePerSec > 1_000_000 }.sorted { $0.diskWritePerSec > $1.diskWritePerSec }.prefix(3)
            out.append(DetectionEvent(rule: .diskFilling, key: "disk:filling", date: s.date, started: most.0,
                severity: .warning, kind: .sustained,
                title: "Your disk is filling up fast",
                summary: "\(f(.diskSpace, Double(used))) used in \(Self.dur(over)); \(f(.diskSpace, Double(s.diskAvailable))) left.",
                reason: "Free space dropped by at least \(f(.diskSpace, Double(Self.fillingBytes))) within \(Self.dur(Self.fillingWindow)).",
                evidence: [Evidence("Used", f(.diskSpace, Double(used))), Evidence("Over", Self.dur(over)), left]
                    + writers.map { Evidence("Writing now", "\($0.name) · \(f(.diskWrites, $0.diskWritePerSec))") },
                subject: s.volumeName, pids: writers.flatMap(\.pids), notify: true))
            diskTrail.removeAll()
        }
    }

    // 5. Heavy disk writing for minutes (recorded; wears the SSD, slows the Mac).
    private mutating func evaluateWrites(_ s: DetectionSample, _ out: inout [DetectionEvent]) {
        let need = settings.writeMinutes * 60
        let writers = s.apps.filter { $0.diskWritePerSec > 1_000_000 }.sorted { $0.diskWritePerSec > $1.diskWritePerSec }.prefix(3)
        let top = writers.map { Evidence("Top writer", "\($0.name) · \(f(.diskWrites, $0.diskWritePerSec))") }
        let writesFired = writes.fired
        if let ep = writes.update(active: s.diskWritePerSec >= settings.writeThreshold, value: s.diskWritePerSec, at: s.date),
           !writesFired, settings.recordSpikes, ep.duration >= Self.minSpike(.diskWrites), ep.duration < need {
            out.append(event(.diskWrites, key: "spike:writes", s.date, ep, .info, .spike,
                title: "Burst of disk writing",
                summary: "Up to \(f(.diskWrites, ep.peak)) for \(Self.dur(ep.duration)).",
                reason: "Writes went over \(f(.diskWrites, settings.writeThreshold)) but stopped before \(Self.dur(need)).",
                notify: false))
        }
        if !writes.fired, let ep = writes.current(at: s.date), ep.duration >= need {
            writes.markFired()
            out.append(event(.diskWrites, key: "writes", s.date, ep, .info, .sustained,
                title: "Heavy disk writing",
                summary: "Averaging \(f(.diskWrites, ep.average)) for \(Self.dur(ep.duration)).",
                reason: "The disk was written at over \(f(.diskWrites, settings.writeThreshold)) for \(Self.dur(ep.duration)) (recorded after \(Self.dur(need))).",
                extra: top, subject: writers.first?.name, pids: writers.flatMap(\.pids), notify: false))
        }
    }

    // 5b. Heavy network traffic for minutes (recorded: a big upload or download,
    // a sync or backup, or something unexpected sending data).
    private mutating func evaluateNetwork(_ s: DetectionSample, _ out: inout [DetectionEvent]) {
        let need = settings.networkMinutes * 60
        let users = s.apps.filter { $0.netPerSec > 100_000 }.sorted { $0.netPerSec > $1.netPerSec }.prefix(3)
        let top = users.map { Evidence("Top app", "\($0.name) · \(f(.network, $0.netPerSec))") }
        let trafficFired = traffic.fired
        if let ep = traffic.update(active: s.networkPerSec >= settings.networkThreshold, value: s.networkPerSec, at: s.date),
           !trafficFired, settings.recordSpikes, ep.duration >= Self.minSpike(.network), ep.duration < need {
            out.append(event(.network, key: "spike:network", s.date, ep, .info, .spike,
                title: "Burst of network traffic",
                summary: "Up to \(f(.network, ep.peak)) for \(Self.dur(ep.duration)).",
                reason: "Traffic went over \(f(.network, settings.networkThreshold)) but dropped before \(Self.dur(need)).",
                notify: false))
        }
        if !traffic.fired, let ep = traffic.current(at: s.date), ep.duration >= need {
            traffic.markFired()
            out.append(event(.network, key: "network", s.date, ep, .info, .sustained,
                title: "Heavy network traffic",
                summary: "Averaging \(f(.network, ep.average)) for \(Self.dur(ep.duration)).",
                reason: "This Mac sent and received over \(f(.network, settings.networkThreshold)) for \(Self.dur(ep.duration)) (recorded after \(Self.dur(need))).",
                extra: top, subject: users.first?.name, pids: users.flatMap(\.pids), notify: false))
        }
    }

    // 6. An app whose memory climbs steadily for 30+ minutes (possible leak).
    private mutating func evaluateGrowth(_ s: DetectionSample, _ out: inout [DetectionEvent]) {
        let present = Dictionary(s.apps.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for key in memoryTrails.keys where present[key] == nil { memoryTrails[key] = nil }   // quit: forget
        for a in s.apps {
            var trail = memoryTrails[a.key] ?? []
            if trail.isEmpty && a.memory < Self.growthTrackFrom { continue }     // too small to matter
            if let last = trail.last, s.date.timeIntervalSince(last.0) < Self.growthPointEvery { continue }
            trail.append((s.date, Double(a.memory)))
            trail.removeAll { s.date.timeIntervalSince($0.0) > Self.growthWindow }
            memoryTrails[a.key] = trail
            guard let g = Self.growth(trail) else { continue }
            out.append(DetectionEvent(rule: .memoryGrowth, key: "growth:\(a.key)", date: s.date, started: trail[0].0,
                severity: .warning, kind: .sustained,
                title: "\(a.name)’s memory keeps growing",
                summary: "From \(f(.memoryGrowth, g.start)) to \(f(.memoryGrowth, g.end)) in \(Self.dur(g.span)), about \(f(.memoryGrowth, g.perHour)) an hour. Quitting and reopening it usually gives the memory back.",
                reason: "Its memory rose steadily for \(Self.dur(g.span)) (alert after \(Self.dur(Self.growthMinSpan)) of growth of at least \(f(.memoryGrowth, Self.growthMinBytes)) and half its starting size). A steady climb like this, rather than ups and downs, often means a memory leak.",
                evidence: [Evidence("Started at", f(.memoryGrowth, g.start)), Evidence("Now", f(.memoryGrowth, g.end)),
                           Evidence("Grew by", f(.memoryGrowth, g.end - g.start)), Evidence("Rate", f(.memoryGrowth, g.perHour) + " an hour"),
                           Evidence("Over", Self.dur(g.span)), Evidence("Steadiness", String(format: "%.0f%% (fit R² %.2f)", g.fit * 100, g.fit))],
                subject: a.name, pids: a.pids, notify: true, series: trail.map(\.1)))
        }
    }

    struct Growth: Equatable { var start, end, perHour, fit: Double; var span: TimeInterval }

    /// Steady growth over a memory trail, or nil. Uses a least-squares line so
    /// a single jump or a sawtooth (normal caching) doesn't count.
    static func growth(_ trail: [(Date, Double)]) -> Growth? {
        guard trail.count >= 10, let first = trail.first, let last = trail.last else { return nil }
        let span = last.0.timeIntervalSince(first.0)
        guard span >= growthMinSpan else { return nil }
        let xs = trail.map { $0.0.timeIntervalSince(first.0) }, ys = trail.map(\.1)
        let n = Double(trail.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in xs.indices { let dx = xs[i] - mx, dy = ys[i] - my; sxy += dx * dy; sxx += dx * dx; syy += dy * dy }
        guard sxx > 0, syy > 0 else { return nil }
        let slope = sxy / sxx
        let fit = (sxy * sxy) / (sxx * syy)
        let start = my - slope * mx, end = start + slope * span          // the fitted line's ends
        guard slope > 0, fit >= growthMinFit, end - start >= growthMinBytes,
              start > 0, (end - start) / start >= growthMinRatio else { return nil }
        // Show what was measured (first and latest point); the line only decides.
        return Growth(start: ys[0], end: ys[ys.count - 1], perHour: slope * 3600, fit: fit, span: span)
    }

    // 7. Swap growing fast while memory is under pressure.
    private mutating func evaluateSwap(_ s: DetectionSample, _ out: inout [DetectionEvent]) {
        swapTrail.append((s.date, s.swapUsed))
        swapTrail.removeAll { s.date.timeIntervalSince($0.0) > Self.swapWindow }
        guard s.pressure >= .warning, let low = swapTrail.min(by: { $0.1 < $1.1 }),
              s.swapUsed > low.1, s.swapUsed - low.1 >= Self.swapGrowthBytes else { return }
        let grew = s.swapUsed - low.1
        let over = s.date.timeIntervalSince(low.0)
        let biggest = s.apps.sorted { $0.memory > $1.memory }.prefix(3)
        out.append(DetectionEvent(rule: .swapGrowth, key: "swap:growing", date: s.date, started: low.0,
            severity: .warning, kind: .sustained,
            title: "Your Mac is swapping more and more",
            summary: "Swap grew by \(f(.swapGrowth, Double(grew))) in \(Self.dur(over)) and is now \(f(.swapGrowth, Double(s.swapUsed))). Things may start to feel slow.",
            reason: "Swap use rose by at least \(f(.swapGrowth, Double(Self.swapGrowthBytes))) within \(Self.dur(Self.swapWindow)) while memory pressure was elevated or critical. macOS is moving memory to the disk because RAM is full.",
            evidence: [Evidence("Swap now", f(.swapGrowth, Double(s.swapUsed))), Evidence("Grew by", f(.swapGrowth, Double(grew))),
                       Evidence("Over", Self.dur(over))]
                + (s.memoryTotal > 0 ? [Evidence("RAM", f(.swapGrowth, Double(s.memoryTotal)))] : [])
                + biggest.map { Evidence("Largest app", "\($0.name) · \(f(.swapGrowth, Double($0.memory)))") },
            pids: biggest.flatMap(\.pids), notify: true))
        swapTrail.removeAll()
    }

    private func event(_ rule: Rule, key: String, _ now: Date, _ ep: Sustained.Episode, _ sev: Severity, _ kind: EventKind,
                       title: String, summary: String, reason: String, extra: [Evidence] = [],
                       subject: String? = nil, pids: [Int32] = [], notify: Bool) -> DetectionEvent {
        var ev = [Evidence("Started", Self.time(ep.start)), Evidence("Lasted", Self.dur(ep.duration))]
        if rule != .thermal {
            ev += [Evidence("Average", f(rule, ep.average)), Evidence("Peak", f(rule, ep.peak))]
        }
        return DetectionEvent(rule: rule, key: key, date: now, started: ep.start, severity: sev, kind: kind,
                              title: title, summary: summary, reason: reason, evidence: ev + extra,
                              subject: subject, pids: pids, notify: notify)
    }
}
