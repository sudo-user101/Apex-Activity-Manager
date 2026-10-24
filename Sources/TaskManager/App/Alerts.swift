import AppKit
import UserNotifications
import DetectionCore

/// Bridges live samples to the detection engine (pure rules in DetectionCore),
/// records every event in the event history, and sends a notification for the
/// ones that warrant it. Runs on each sample; costs a few dictionary lookups.
@MainActor
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()

    var enabled = UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true
    var settings: DetectionSettings {
        didSet {
            engine.settings = settings
            if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "detectionSettings") }
        }
    }
    /// Whether macOS lets Apex show notifications (events are recorded either way).
    private(set) var authorized = false
    private var engine: DetectionEngine
    private let center = UNUserNotificationCenter.current()

    override init() {
        let s = Self.loadSettings()
        settings = s
        engine = DetectionEngine(settings: s, formatValue: Self.format)
        super.init()
    }

    /// Saved settings, or the pre-Phase-2 individual keys.
    private static func loadSettings() -> DetectionSettings {
        if let d = UserDefaults.standard.data(forKey: "detectionSettings"),
           let s = try? JSONDecoder().decode(DetectionSettings.self, from: d) { return s }
        var s = DetectionSettings()
        let u = UserDefaults.standard
        if let v = u.object(forKey: "alertCPU") as? Double { s.cpuThreshold = v }
        if let v = u.object(forKey: "alertCPUMinutes") as? Double { s.cpuMinutes = v }
        if let v = u.object(forKey: "alertMemory") as? Bool { s.memory = v }
        if let v = u.object(forKey: "alertHeat") as? Bool { s.heat = v }
        if let v = u.object(forKey: "alertDisk") as? Bool { s.disk = v }
        return s
    }

    nonisolated static func format(_ rule: Rule, _ v: Double) -> String {
        switch rule {
        case .appCPU, .memoryPressure: return "\(Int(v.rounded()))%"
        case .thermal, .driveHealth: return String(format: "%.0f", v)
        case .diskSpace, .diskFilling:
            return ByteCountFormatter.string(fromByteCount: Int64(max(0, v)), countStyle: .file)
        case .memoryGrowth, .swapGrowth:
            return ByteCountFormatter.string(fromByteCount: Int64(max(0, v)), countStyle: .memory)
        case .diskWrites:
            return ByteCountFormatter.string(fromByteCount: Int64(max(0, v)), countStyle: .file) + "/s"
        }
    }

    func start() {
        center.delegate = self
        let quit = UNNotificationAction(identifier: "quit", title: "Quit")
        let optimize = UNNotificationAction(identifier: "optimize", title: "Optimize")
        let free = UNNotificationAction(identifier: "free", title: "Free Up Memory…", options: [.foreground])
        let clean = UNNotificationAction(identifier: "clean", title: "Clean Up Disk…", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "app", actions: [optimize, quit], intentIdentifiers: []),
            UNNotificationCategory(identifier: "memory", actions: [free], intentIdentifiers: []),
            UNNotificationCategory(identifier: "disk", actions: [clean], intentIdentifiers: []),
            UNNotificationCategory(identifier: "leak", actions: [quit], intentIdentifiers: []),
        ])
        if enabled { requestAuthorization() }
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in self.authorized = ok }
        }
    }

    func evaluate(_ s: Snapshot) {
        guard enabled else { return }
        let sample = Self.sample(s)
        let events = engine.evaluate(sample)
        deliver(events)
    }

    /// Records events from any source and notifies for the ones that ask for it.
    func deliver(_ events: [DetectionEvent]) {
        guard !events.isEmpty else { return }
        EventLog.shared.add(events)
        if enabled && authorized { for e in events where e.notify { post(e) } }
    }

    /// Live snapshot → engine input (apps grouped like the Processes list).
    static func sample(_ s: Snapshot) -> DetectionSample {
        var names: [String: String] = [:]
        for p in s.processes where p.isRegularApp && !p.bundlePath.isEmpty { names[p.bundlePath] = p.name }
        var apps: [String: AppLoad] = [:]
        let me = getuid()
        for p in s.processes where !p.restricted && p.uid == me {
            let key = p.appKey
            var a = apps[key] ?? AppLoad(key: key, name: names[p.bundlePath] ?? p.name, cpu: 0)
            a.cpu += p.cpu; a.diskWritePerSec += p.diskWritePerSec; a.memory += p.memory; a.pids.append(p.pid)
            apps[key] = a
        }
        let m = s.system.memory
        return DetectionSample(
            date: s.date, apps: Array(apps.values),
            pressure: m.pressureLevel == .critical ? .critical : m.pressureLevel == .warning ? .warning : .normal,
            memoryUsedPercent: m.percent, swapUsed: m.swapUsed, memoryTotal: m.total,
            thermal: ThermalState(rawValue: s.system.thermal.rawValue) ?? .nominal,
            diskAvailable: s.system.disk.available, diskCapacity: s.system.disk.capacity,
            volumeName: s.system.disk.volumeName, diskWritePerSec: s.system.disk.writePerSec)
    }

    private func post(_ e: DetectionEvent) {
        let c = UNMutableNotificationContent()
        c.title = e.title
        c.body = e.summary
        switch e.rule {
        case .appCPU: c.categoryIdentifier = "app"
        case .memoryGrowth: c.categoryIdentifier = "leak"
        case .memoryPressure, .swapGrowth: c.categoryIdentifier = "memory"
        case .diskSpace, .diskFilling, .driveHealth: c.categoryIdentifier = "disk"
        default: c.categoryIdentifier = ""
        }
        c.userInfo = ["pids": e.pids.map(Int.init), "event": e.id.uuidString]
        c.sound = e.severity == .critical ? .defaultCritical : .default
        center.add(UNNotificationRequest(identifier: e.key, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let pids = (info["pids"] as? [Int])?.map { pid_t($0) } ?? []
        let event = (info["event"] as? String).flatMap(UUID.init)
        Task { @MainActor in
            let model = AppModel.shared
            switch action {
            case "quit": model.end(pids: pids, force: false)
            case "optimize": model.setOptimized(pids: pids, true)
            case "free": model.openMainWindow?(); model.section = .performance; model.showFreeMemory = true
            case "clean": model.openMainWindow?(); model.showCleanup = true
            default:
                // Clicking the notification itself: show why it fired.
                model.openMainWindow?()
                model.section = .history
                model.historyMode = "events"
                model.selectedEvent = event
            }
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

/// Everything the detection engine found: alerts and recorded spikes.
/// Kept for 30 days (at most 1000 events) in Application Support.
@MainActor
@Observable
final class EventLog {
    static let shared = EventLog()
    private(set) var events: [DetectionEvent] = []     // newest first
    static let keepDays = 30.0
    static let maxEvents = 1000

    @ObservationIgnored private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apex Activity Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.json")
    }()

    init() {
        if let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
            events = (try? dec.decode([DetectionEvent].self, from: d)) ?? []
            // Older builds called yellow pressure "high"; relabel saved events.
            for i in events.indices where events[i].key == "memory:warning" && events[i].title.contains("high") {
                events[i].title = "Memory pressure has been elevated for a while"
                events[i].summary = "Elevated (yellow) for a while. Your Mac was relying on compression and swap, but it wasn’t critical."
                events[i].reason = "Memory pressure stayed elevated (yellow) or above for at least 5m. Only critical (red) pressure sends an alert."
            }
        }
        prune()
    }

    func add(_ new: [DetectionEvent]) {
        events.insert(contentsOf: new.sorted { $0.date > $1.date }, at: 0)
        prune()
        save()
    }

    func remove(_ id: UUID) { events.removeAll { $0.id == id }; save() }
    func clear() { events = []; save() }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.keepDays * 86400)
        events.removeAll { $0.date < cutoff }
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(events) { try? d.write(to: url, options: .atomic) }
    }
}
