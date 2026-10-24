import Foundation
import DetectionCore

// Drive health: learns how each drive is used and how it performs while busy.
//
// Every drive (the startup drive and anything plugged in) gets a record that
// survives unplugging, keyed by its USB serial number (or model + size):
// time connected, data moved, apps run from it, large transfers and their
// speeds, response time per operation and error counters where the drive
// reports them, and the SSD's own health log for internal NVMe drives.
// The status only appears once there's enough to judge ("Learning" before).

struct TransferEpisode: Codable, Equatable, Sendable {
    var date: Date
    var seconds: Double
    var readMBps: Double
    var writeMBps: Double
    var megabytes: Double
}

struct DriveRecord: Codable, Equatable, Sendable {
    var key: String
    var name: String
    var model: String
    var connection: String
    var isStartup = false
    var firstSeen: Date
    var lastSeen: Date
    var sessions = 1
    var secondsConnected: Double = 0
    var activeSeconds: Double = 0          // reading or writing over 1 MB/s
    var appSeconds: Double = 0             // apps running from it
    var appNames: [String] = []
    var bytesRead: Double = 0
    var bytesWritten: Double = 0
    var transfers: [TransferEpisode] = []  // last 30 sustained transfers
    var bestReadMBps: Double = 0
    var bestWriteMBps: Double = 0
    var latencyMs: Double?                 // recent average response time per operation
    var latencyBaselineMs: Double?         // its usual response time
    var errors: Double = 0
    var retries: Double = 0
    var reportsErrors = false
    var smart: SMARTHealth?
    var smartFirst: SMARTHealth?           // first reading, to show change over time
    var isTimeMachine = false
}

enum DriveHealthStatus: String, Codable, Sendable { case learning, good, watch, poor
    var title: String {
        switch self {
        case .learning: return "Learning"
        case .good: return "Good"
        case .watch: return "Keep an eye on it"
        case .poor: return "At risk"
        }
    }
}

enum DriveUsage: Equatable, Sendable {
    case startup, apps([String]), transfers, backups, storage, unknown
    var title: String {
        switch self {
        case .startup: return "Startup drive: macOS and your apps run from it"
        case .apps(let names): return "Runs apps" + (names.isEmpty ? "" : ": " + names.prefix(3).joined(separator: ", "))
        case .transfers: return "Mostly used for copying files"
        case .backups: return "Time Machine backups"
        case .storage: return "Plugged in for storage; used now and then"
        case .unknown: return "Not enough use yet to tell"
        }
    }
}

/// Pure rules: record in, status / usage / reasons out (unit-tested).
enum DriveHealthRules {
    static let learnSeconds: Double = 30 * 60     // judge usage after 30 min connected
    static let transferMinMBps = 10.0
    static let transferMinSeconds = 10.0
    static let slowRatio = 0.5                    // recent transfers under half its best
    static let slowRecentCount = 3

    static func usage(_ r: DriveRecord) -> DriveUsage {
        if r.isStartup { return .startup }
        if r.isTimeMachine { return .backups }
        guard r.secondsConnected >= learnSeconds else { return .unknown }
        if r.appSeconds >= r.secondsConnected * 0.1 { return .apps(r.appNames) }
        if r.transfers.count >= 2 { return .transfers }
        return .storage
    }

    static func assess(_ r: DriveRecord) -> (status: DriveHealthStatus, reasons: [String]) {
        var poor: [String] = [], watch: [String] = [], good: [String] = []
        if let s = r.smart {
            if s.criticalWarning != 0 { poor.append("The drive itself reports a critical warning.") }
            if s.availableSpare < s.spareThreshold { poor.append("Spare blocks (\(s.availableSpare)%) are below the drive’s safe limit (\(s.spareThreshold)%).") }
            if s.percentageUsed >= 90 { poor.append("\(s.percentageUsed)% of its rated lifespan is used.") }
            else if s.percentageUsed >= 70 { watch.append("\(s.percentageUsed)% of its rated lifespan is used.") }
            else { good.append("\(s.percentageUsed)% of its rated lifespan used.") }
            if s.mediaErrors > 0 { watch.append("\(s.mediaErrors) data errors recorded by the drive.") }
            else { good.append("No data errors recorded by the drive.") }
            if s.temperatureC >= 70 { watch.append("Running hot (\(s.temperatureC) °C).") }
        }
        if r.reportsErrors {
            if r.errors > 0 { watch.append("\(Int(r.errors)) read or write errors while Apex was watching.") }
            else if r.retries > 10 { watch.append("macOS had to retry \(Int(r.retries)) operations.") }
        }
        if let lat = r.latencyMs, let base = r.latencyBaselineMs, base > 0, r.activeSeconds > 600, lat > base * 3, lat > 2 {
            watch.append(String(format: "Responding slower than usual (%.1f ms per operation, usually %.1f ms).", lat, base))
        }
        let recent = r.transfers.suffix(slowRecentCount)
        if recent.count == slowRecentCount, r.transfers.count > slowRecentCount {
            let speed = { (t: TransferEpisode) in max(t.readMBps, t.writeMBps) }
            let best = r.transfers.dropLast(slowRecentCount).map(speed).max() ?? 0
            if best > 0, recent.allSatisfy({ speed($0) < best * slowRatio }) {
                watch.append(String(format: "Its last %d large transfers were under half its best speed (%.0f MB/s). Drives slow down as they wear or get very full.", slowRecentCount, best))
            }
        }
        if !poor.isEmpty { return (.poor, poor + watch) }
        if !watch.isEmpty { return (.watch, watch) }
        // Without the drive's own health log, judge only after real use.
        let enough = r.smart != nil || (r.secondsConnected >= learnSeconds && (r.transfers.count >= 2 || r.activeSeconds >= 300))
        if !enough { return (.learning, ["Apex is still learning how this drive behaves. Status appears after about 30 minutes of use and a couple of larger transfers."]) }
        if r.transfers.count >= 2 { good.append("Transfer speeds are steady.") }
        if r.reportsErrors { good.append("No read or write errors seen.") }
        return (.good, good)
    }

    /// Exponential moving average.
    /// Earlier builds could store an implausible USB response time; drop it.
    static func plausibleLatency(_ ms: Double?) -> Double? { ms.flatMap { $0 > 0 && $0 < 100 ? $0 : nil } }

    static func ewma(_ old: Double?, _ new: Double, _ alpha: Double) -> Double { old.map { $0 + alpha * (new - $0) } ?? new }
}

@MainActor
@Observable
final class DriveHealthStore {
    static let shared = DriveHealthStore()
    private(set) var records: [String: DriveRecord] = [:]

    @ObservationIgnored private var lastTick: [String: Date] = [:]
    @ObservationIgnored private var lastIO: [String: DriveIO] = [:]
    @ObservationIgnored private var episode: [String: (start: Date, last: Date, read: Double, write: Double, secs: Double)] = [:]
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var lastSMART = Date.distantPast
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastStatus: [String: DriveHealthStatus] = [:]
    @ObservationIgnored private var lastCheck = Date.distantPast
    @ObservationIgnored private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apex Activity Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("drives.json")
    }()
    static let startupKey = "startup"

    init() {
        if let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
            records = (try? dec.decode([String: DriveRecord].self, from: d)) ?? [:]
            for k in records.keys where DriveHealthRules.plausibleLatency(records[k]?.latencyMs) == nil {
                records[k]?.latencyMs = nil; records[k]?.latencyBaselineMs = nil
            }
        }
    }

    static func key(for d: StorageDevice) -> String {
        d.serial.isEmpty ? "model:\(d.model)|\(d.size)" : "usb:\(d.serial)"
    }

    func record(for d: StorageDevice) -> DriveRecord? { records[Self.key(for: d)] }
    var startup: DriveRecord? { records[Self.startupKey] }

    /// Called on every sample (cheap: a few additions per drive).
    func update(_ s: Snapshot) {
        let now = s.date
        let disk = s.system.disk
        var present: [(key: String, name: String, model: String, connection: String, startup: Bool,
                       read: Double, write: Double, io: DriveIO, volumes: [String])] = [
            (Self.startupKey, disk.volumeName, "", "Internal", true, disk.readPerSec, disk.writePerSec, s.system.bootIO, []),
        ]
        for d in s.system.storageDevices where d.connection != "Disk image" {
            present.append((Self.key(for: d), d.name, d.model, d.usb?.short ?? d.connection, false,
                            d.readPerSec, d.writePerSec, d.io, d.volumes.map(\.path)))
        }
        for p in present {
            var r = records[p.key] ?? DriveRecord(key: p.key, name: p.name, model: p.model, connection: p.connection,
                                                   isStartup: p.startup, firstSeen: now, lastSeen: now)
            let newSession = lastTick[p.key] == nil
            if newSession && records[p.key] != nil && !p.startup { r.sessions += 1 }
            let dt = lastTick[p.key].map { min(max(now.timeIntervalSince($0), 0), 15) } ?? 0
            lastTick[p.key] = now
            r.name = p.name; if !p.model.isEmpty { r.model = p.model }; r.connection = p.connection; r.lastSeen = now
            r.secondsConnected += dt
            r.bytesRead += p.read * dt; r.bytesWritten += p.write * dt
            if p.read + p.write >= 1_000_000 { r.activeSeconds += dt }

            // Apps running from this drive.
            if !p.volumes.isEmpty {
                let onDrive = s.processes.filter { proc in p.volumes.contains { proc.path.hasPrefix($0 + "/") } }
                if !onDrive.isEmpty {
                    r.appSeconds += dt
                    for n in Set(onDrive.map { $0.appName ?? $0.name }) where !r.appNames.contains(n) && r.appNames.count < 10 { r.appNames.append(n) }
                }
                if newSession { r.isTimeMachine = p.volumes.contains { FileManager.default.fileExists(atPath: $0 + "/Backups.backupdb") } }
            }

            // Large transfers: sustained over 10 MB/s; record their speed when they end.
            let mbps = (p.read + p.write) / 1_000_000
            if mbps >= DriveHealthRules.transferMinMBps {
                var e = episode[p.key] ?? (now, now, 0, 0, 0)
                e.last = now; e.read += p.read * dt; e.write += p.write * dt; e.secs += dt
                episode[p.key] = e
            } else if let e = episode[p.key], now.timeIntervalSince(e.last) > 5 {
                episode[p.key] = nil
                if e.secs >= DriveHealthRules.transferMinSeconds {
                    let t = TransferEpisode(date: e.start, seconds: e.secs, readMBps: e.read / e.secs / 1_000_000,
                                            writeMBps: e.write / e.secs / 1_000_000, megabytes: (e.read + e.write) / 1_000_000)
                    r.transfers.append(t)
                    if r.transfers.count > 30 { r.transfers.removeFirst(r.transfers.count - 30) }
                    r.bestReadMBps = max(r.bestReadMBps, t.readMBps)
                    r.bestWriteMBps = max(r.bestWriteMBps, t.writeMBps)
                }
            }

            // Response time and errors, where the drive reports them.
            if let prev = lastIO[p.key] {
                let ops = Double((p.io.readOps &- prev.readOps) &+ (p.io.writeOps &- prev.writeOps))
                if p.io.hasTiming, dt > 0, ops >= 20 * dt, p.io.readOps >= prev.readOps, p.io.writeOps >= prev.writeOps {
                    let ns = Double((p.io.readTimeNs &- prev.readTimeNs) &+ (p.io.writeTimeNs &- prev.writeTimeNs))
                    let ms = ns / ops / 1_000_000
                    // Some drivers (many USB bridges) count time in a way that can't be
                    // per-operation time: more than 32 requests' worth per second of real time.
                    if ms.isFinite, ms > 0, ms < 10_000, ns <= dt * 1e9 * 32 {
                        r.latencyMs = DriveHealthRules.ewma(r.latencyMs, ms, 0.05)
                        r.latencyBaselineMs = DriveHealthRules.ewma(r.latencyBaselineMs, ms, 0.002)
                    }
                }
                if p.io.hasErrors {
                    r.reportsErrors = true
                    if p.io.errors >= prev.errors { r.errors += Double(p.io.errors - prev.errors) }
                    if p.io.retries >= prev.retries { r.retries += Double(p.io.retries - prev.retries) }
                }
            }
            lastIO[p.key] = p.io
            records[p.key] = r
            dirty = true
        }
        // Unplugged drives: their next appearance is a new session.
        let keys = Set(present.map(\.key))
        for k in lastTick.keys where !keys.contains(k) { lastTick[k] = nil; lastIO[k] = nil; episode[k] = nil }

        if now.timeIntervalSince(lastSMART) > 600 { lastSMART = now; refreshSMART() }
        // Once a minute: has any connected drive's status got worse?
        if now.timeIntervalSince(lastCheck) > 60 {
            lastCheck = now
            for k in keys {
                guard let r = records[k] else { continue }
                let st = DriveHealthRules.assess(r).status
                if let before = lastStatus[k], before != st { reportChange(r, from: before) }
                lastStatus[k] = st
            }
        }
        if dirty, now.timeIntervalSince(lastSave) > 300 { save() }
    }

    private func refreshSMART() {
        Task.detached(priority: .utility) {
            guard let h = NVMeSMART.readInternal() else { return }
            await MainActor.run {
                guard var r = DriveHealthStore.shared.records[Self.startupKey] else { return }
                r.smart = h
                if r.smartFirst == nil { r.smartFirst = h }
                DriveHealthStore.shared.records[Self.startupKey] = r
            }
        }
    }

    /// A drive getting worse goes into the event history (and notifies when at risk).
    func reportChange(_ r: DriveRecord, from before: DriveHealthStatus) {
        let now = DriveHealthRules.assess(r)
        guard now.status == .watch || now.status == .poor, now.status != before, before != .poor || now.status == .poor else { return }
        let ev = DetectionEvent(rule: .driveHealth, key: "drivehealth:\(r.key)", date: Date(), started: Date(),
                                severity: now.status == .poor ? .critical : .warning, kind: .instant,
                                title: "\(r.name): drive health \(now.status.title.lowercased())",
                                summary: now.reasons.first ?? "", reason: now.reasons.joined(separator: " "),
                                evidence: [], subject: r.name, notify: now.status == .poor)
        Alerts.shared.deliver([ev])
    }

    func save() {
        dirty = false; lastSave = Date()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(records) { try? d.write(to: url, options: .atomic) }
    }

    func forget(_ key: String) { records[key] = nil; save() }
}
