import Foundation

/// Per-app resource use per day (Windows "App history"), kept for 30 days in
/// ~/Library/Application Support/Apex Activity Manager/history.json.
/// Updated from each sample; written to disk at most every 5 minutes.
struct AppUsageDay: Codable, Sendable {
    var name: String
    var bundlePath: String
    var cpuSeconds: Double = 0
    var diskBytes: Double = 0
    var netBytes: Double = 0
    var peakMemory: UInt64 = 0
    var energyJoules: Double? = 0
    var lastSeen: Date = .distantPast
}

@MainActor
final class HistoryStore {
    static let shared = HistoryStore()
    /// day ("yyyy-MM-dd") -> app key -> usage
    private(set) var days: [String: [String: AppUsageDay]] = [:]
    private var lastSample: Date?
    private var lastSave = Date()
    private var dirty = false

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apex Activity Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private init() {
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([String: [String: AppUsageDay]].self, from: d) {
            days = v
        }
    }

    func record(_ s: Snapshot) {
        defer { lastSample = s.date }
        guard let last = lastSample else { return }
        let dt = s.date.timeIntervalSince(last)
        guard dt > 0, dt < 120 else { return }   // ignore gaps (sleep, pauses)
        let day = Self.dayFormat.string(from: s.date)
        var today = days[day] ?? [:]
        // Helpers count towards their app (by outer .app bundle).
        var appNames: [String: String] = [:]
        for p in s.processes where p.isRegularApp && !p.bundlePath.isEmpty { appNames[p.bundlePath] = p.name }
        var memByKey: [String: UInt64] = [:]
        for p in s.processes {
            let key = p.appKey
            let cpu = p.cpu / 100 * dt
            let disk = (p.diskReadPerSec + p.diskWritePerSec) * dt
            let net = p.netPerSec * dt
            let joules = p.power * dt
            memByKey[key, default: 0] += p.memory
            guard cpu > 0.001 || disk > 0 || net > 0 || joules > 0 || today[key] != nil else { continue }
            var u = today[key] ?? AppUsageDay(name: appNames[p.bundlePath] ?? Self.displayName(p), bundlePath: p.bundlePath)
            u.cpuSeconds += cpu
            u.diskBytes += disk
            u.netBytes += net
            u.energyJoules = (u.energyJoules ?? 0) + joules
            u.lastSeen = s.date
            today[key] = u
        }
        for (k, m) in memByKey where today[k] != nil { today[k]!.peakMemory = max(today[k]!.peakMemory, m) }
        days[day] = today
        dirty = true
        if Date().timeIntervalSince(lastSave) > 300 { save() }
    }

    private static func displayName(_ p: ProcessInfoSample) -> String {
        p.bundlePath.isEmpty ? p.name : ((p.bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    func save() {
        guard dirty else { return }
        // Keep 30 days.
        let cutoff = Self.dayFormat.string(from: Date().addingTimeInterval(-30 * 86400))
        days = days.filter { $0.key >= cutoff }
        if let d = try? JSONEncoder().encode(days) { try? d.write(to: url, options: .atomic) }
        dirty = false
        lastSave = Date()
    }

    func clear() { days = [:]; dirty = true; save() }

    /// Totals over the last `numberOfDays` days, largest CPU first.
    func totals(days numberOfDays: Int) -> [(key: String, usage: AppUsageDay)] {
        let cutoff = Self.dayFormat.string(from: Date().addingTimeInterval(-Double(numberOfDays - 1) * 86400))
        var sum: [String: AppUsageDay] = [:]
        for (day, apps) in days where day >= cutoff {
            for (k, u) in apps {
                var t = sum[k] ?? AppUsageDay(name: u.name, bundlePath: u.bundlePath)
                t.cpuSeconds += u.cpuSeconds; t.diskBytes += u.diskBytes; t.netBytes += u.netBytes
                t.energyJoules = (t.energyJoules ?? 0) + (u.energyJoules ?? 0)
                t.peakMemory = max(t.peakMemory, u.peakMemory); t.lastSeen = max(t.lastSeen, u.lastSeen)
                sum[k] = t
            }
        }
        return sum.map { ($0.key, $0.value) }.sorted { $0.usage.cpuSeconds > $1.usage.cpuSeconds }
    }

    /// Per-day usage of one app over the last `numberOfDays` days (oldest first).
    func daily(key: String, days numberOfDays: Int) -> [(String, AppUsageDay)] {
        let cutoff = Self.dayFormat.string(from: Date().addingTimeInterval(-Double(numberOfDays - 1) * 86400))
        return days.filter { $0.key >= cutoff }.compactMap { d, apps in apps[key].map { (d, $0) } }.sorted { $0.0 < $1.0 }
    }

    var since: Date? { days.keys.min().flatMap { Self.dayFormat.date(from: $0) } }
}
