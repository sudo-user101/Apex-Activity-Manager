import Foundation

/// Shared between Apex and its privileged fan helper. Pure logic only —
/// no hardware access — so it can be unit-tested and audited easily.
public enum FanControl {
    /// Settings file the helper reads (owned by the user who enabled it).
    public static let configPath = "/Library/Application Support/Apex/fans.json"
    public static let helperPath = "/Library/PrivilegedHelperTools/com.apex.fanhelper"
    public static let daemonPlist = "/Library/LaunchDaemons/com.apex.fanhelper.plist"
    public static let daemonLabel = "com.apex.fanhelper"
    /// If Apex stops refreshing the heartbeat (quit, crash), fans go back to automatic.
    public static let heartbeatTimeout: TimeInterval = 90

    public enum Mode: String, Codable, CaseIterable, Sendable {
        case auto, fixed, curve, max
        public var title: String {
            switch self {
            case .auto: return "Automatic"
            case .fixed: return "Fixed speed"
            case .curve: return "Temperature curve"
            case .max: return "Full speed"
            }
        }
    }

    public enum Sensor: String, Codable, CaseIterable, Sendable {
        case cpu, gpu, hottest
        public var title: String {
            switch self {
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .hottest: return "Hottest sensor"
            }
        }
    }

    public struct FanSetting: Codable, Equatable, Sendable {
        public var index: Int
        public var mode: Mode
        public var rpm: Double            // fixed mode target
        public var sensor: Sensor         // curve mode input
        public var startTemp: Double      // curve: below this, minimum speed
        public var fullTemp: Double       // curve: at/above this, maximum speed

        public init(index: Int, mode: Mode = .auto, rpm: Double = 0, sensor: Sensor = .cpu,
                    startTemp: Double = 50, fullTemp: Double = 85) {
            self.index = index; self.mode = mode; self.rpm = rpm; self.sensor = sensor
            self.startTemp = startTemp; self.fullTemp = fullTemp
        }
    }

    public struct Config: Codable, Equatable, Sendable {
        public var heartbeat: Date
        public var fans: [FanSetting]
        /// Battery charge limit in % (nil = off). Enforced even while Apex is closed.
        public var chargeLimit: Int?
        /// "Charge to 100% now": the limit is suspended until this time or until full.
        public var chargeOverrideUntil: Date?
        /// Weekly charging windows (nil in files from older versions).
        public var chargeSchedules: [ChargeSchedule]?
        /// Night charging: hold low overnight, full by morning (nil = off).
        public var nightCharging: NightCharging?
        /// Lid-closed mode: keep the Mac awake (even with the lid closed) until
        /// this time. Apex renews it every minute while it's wanted, so it
        /// lapses by itself if Apex stops (see `sleepDisabled`).
        public var stayAwakeUntil: Date?
        /// Firmware that can only stop charging by disconnecting the adapter
        /// ("hold"): may Apex hold the limit that way, running the Mac on its
        /// battery while plugged in? nil / false = never: the adapter always
        /// powers the Mac, and the limit can't be held on that firmware.
        public var holdOnBattery: Bool?
        public init(heartbeat: Date = Date(), fans: [FanSetting] = [], chargeLimit: Int? = nil, chargeOverrideUntil: Date? = nil,
                    chargeSchedules: [ChargeSchedule]? = nil, nightCharging: NightCharging? = nil, stayAwakeUntil: Date? = nil,
                    holdOnBattery: Bool? = nil) {
            self.heartbeat = heartbeat; self.fans = fans; self.chargeLimit = chargeLimit; self.chargeOverrideUntil = chargeOverrideUntil
            self.chargeSchedules = chargeSchedules; self.nightCharging = nightCharging; self.stayAwakeUntil = stayAwakeUntil
            self.holdOnBattery = holdOnBattery
        }
        public var allAutomatic: Bool { fans.allSatisfy { $0.mode == .auto } }
    }

    /// What the helper reports back (written to `statusPath`, readable by Apex).
    public struct Status: Codable, Equatable, Sendable {
        public var updated: Date
        public var fanTargets: [Int: Double]
        public var chargeMethod: String?        // "pause" | "hold" | nil (unsupported)
        public var chargingBlocked: Bool
        public var batteryPercent: Int?
        public var message: String?
        /// The power adapter is plugged in.
        public var onAdapter: Bool?
        /// Plugged in, yet the battery is powering the Mac (`drainingOnAdapter`).
        public var batteryPowering: Bool?
        /// Something else had disconnected the adapter (SMC `CHIE`); the helper connected it again.
        public var adapterRestored: Bool?
        /// The limit isn't held because that would run the Mac on battery (`holdOnBattery` off).
        public var limitNotHeld: Bool?
        /// What happened while the Mac was off (from `OffRecord`), shown until the next restart.
        public var whileOff: String?
        /// The running helper's `FanControl.helperVersion` (nil = written before versions existed).
        public var helperVersion: Int?
        public init(updated: Date = Date(), fanTargets: [Int: Double] = [:], chargeMethod: String? = nil,
                    chargingBlocked: Bool = false, batteryPercent: Int? = nil, message: String? = nil,
                    onAdapter: Bool? = nil, batteryPowering: Bool? = nil, adapterRestored: Bool? = nil,
                    limitNotHeld: Bool? = nil, whileOff: String? = nil, helperVersion: Int? = nil) {
            self.updated = updated; self.fanTargets = fanTargets; self.chargeMethod = chargeMethod
            self.chargingBlocked = chargingBlocked; self.batteryPercent = batteryPercent; self.message = message
            self.onAdapter = onAdapter; self.batteryPowering = batteryPowering; self.adapterRestored = adapterRestored
            self.limitNotHeld = limitNotHeld; self.whileOff = whileOff; self.helperVersion = helperVersion
        }
    }
    public static let statusPath = "/Library/Application Support/Apex/status.json"

    public struct Temps: Sendable {
        public var cpu: Double?, gpu: Double?, hottest: Double?
        public init(cpu: Double?, gpu: Double?, hottest: Double?) { self.cpu = cpu; self.gpu = gpu; self.hottest = hottest }
        public func value(_ s: Sensor) -> Double? {
            switch s { case .cpu: return cpu ?? hottest; case .gpu: return gpu ?? hottest; case .hottest: return hottest }
        }
    }

    /// Target RPM for a fan, or nil for "leave it to macOS".
    /// Always within the fan's own [min, max]; unknown temperature → automatic.
    public static func target(_ s: FanSetting, minRPM: Double, maxRPM: Double, temps: Temps) -> Double? {
        guard maxRPM > 0, maxRPM >= minRPM else { return nil }
        switch s.mode {
        case .auto:
            return nil
        case .max:
            return maxRPM
        case .fixed:
            return clamp(s.rpm, minRPM, maxRPM)
        case .curve:
            guard let t = temps.value(s.sensor), t.isFinite else { return nil }
            let start = clamp(s.startTemp, 20, 105)
            let full = max(start + 1, clamp(s.fullTemp, 21, 110))
            let f = clamp((t - start) / (full - start), 0, 1)
            return (minRPM + (maxRPM - minRPM) * f).rounded()
        }
    }

    /// The helper only acts on a config whose heartbeat is recent.
    public static func isFresh(_ c: Config, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(c.heartbeat)
        return age >= -60 && age <= heartbeatTimeout
    }

    /// Rejects anything out of range; the helper never trusts the file blindly.
    public static func sanitized(_ c: Config) -> Config {
        var out = c
        out.fans = c.fans.filter { (0..<8).contains($0.index) }.map { f in
            var f = f
            if !f.rpm.isFinite { f.rpm = 0 }
            f.startTemp = f.startTemp.isFinite ? clamp(f.startTemp, 20, 105) : 50
            f.fullTemp = f.fullTemp.isFinite ? clamp(f.fullTemp, f.startTemp + 1, 110) : 85
            return f
        }
        return out
    }

    /// Allowed limits (very low limits are pointless and stressful for daily use).
    public static let chargeLimitRange = 50...100
    /// Re-enable charging this many % below the limit, so it doesn't toggle constantly.
    public static let chargeHysteresis = 3

    /// Should charging be blocked right now? Unknown battery level → never block.
    public static func shouldBlockCharging(percent: Int?, limit: Int?, overrideUntil: Date?,
                                           currentlyBlocked: Bool, now: Date = Date()) -> Bool {
        guard let percent, let limit, chargeLimitRange.contains(limit), limit < 100 else { return false }
        if let until = overrideUntil, until > now { return false }
        if percent >= limit { return true }
        if currentlyBlocked && percent > limit - chargeHysteresis { return true }
        return false
    }

    // MARK: Helper version

    /// The helper's version. Raised only when the helper's own behaviour
    /// changes (its code in Sources/ApexFanHelper or this file), never for an
    /// ordinary Apex build, so Apex asks for the password to update it only
    /// when that brings something. `HelperVersionTests` fails when the
    /// helper's code changes without this being raised.
    /// 1: before versions (2026-10-25). 2: the adapter powers the Mac at the limit (#18).
    public static let helperVersion = 2

    /// What each version brings, in plain words, for the "update available" note.
    public static let helperNews: [Int: String] = [
        2: "At the limit your Mac runs from the power adapter, and charging can stay paused while it’s off.",
    ]

    /// Everything newer than the running helper, oldest first. Pure: tested.
    public static func helperNewsSince(_ running: Int?) -> [String] {
        helperNews.filter { $0.key > (running ?? 1) && $0.key <= helperVersion }.sorted { $0.key < $1.key }.map(\.value)
    }

    /// The installed helper is older than this Apex's. Not knowing (no status
    /// yet) isn't "older". Pure: tested.
    public static func helperNeedsUpdate(running: Int?, statusKnown: Bool) -> Bool {
        statusKnown && (running ?? 1) < helperVersion
    }

    // MARK: Power from the adapter

    /// May the helper stop charging with this method? "pause" stops charging
    /// and the adapter keeps powering the Mac, so always. "hold" disconnects
    /// the adapter (the Mac runs on battery), so only when the person allowed it.
    public static func mayBlock(method: String?, holdOnBattery: Bool?) -> Bool {
        switch method {
        case "pause"?: return true
        case "hold"?: return holdOnBattery == true
        default: return false
        }
    }

    /// Plugged in, but the battery is supplying the power: more than 150 mA
    /// going out of it (a few mA either way is normal at rest).
    public static func drainingOnAdapter(externalConnected: Bool?, amperageMA: Int?) -> Bool {
        externalConnected == true && (amperageMA ?? 0) <= -150
    }

    /// While charging is paused, the adapter must stay connected: SMC `CHIE`
    /// non-zero means something (another battery app, a killed helper) cut it
    /// off. True = write 0 to connect it again.
    public static func shouldReconnectAdapter(method: String?, chie: [UInt8]?) -> Bool {
        guard method == "pause", let chie else { return false }
        return chie.contains { $0 != 0 }
    }

    // MARK: While the Mac is off

    /// What the helper saw as the Mac shut down (it can't run while the Mac is off).
    public struct OffRecord: Codable, Equatable, Sendable {
        public var percent: Int
        public var at: Date
        public var limit: Int?
        /// Charging was left paused for the shutdown.
        public var paused: Bool
        public init(percent: Int, at: Date, limit: Int?, paused: Bool) {
            self.percent = percent; self.at = at; self.limit = limit; self.paused = paused
        }
    }
    public static let offRecordPath = "/Library/Application Support/Apex/off.json"

    /// On shutdown (SIGTERM): leave charging paused so a firmware that keeps
    /// the setting doesn't charge while the Mac is off. Only for "pause" (the
    /// adapter stays connected), only while the settings file is there (it's
    /// deleted first when the helper is removed) and a limit applies.
    public static func keepPausedOnExit(method: String?, configPresent: Bool, blocked: Bool, limit: Int?) -> Bool {
        method == "pause" && configPresent && blocked && limit != nil
    }

    /// After a restart: did the battery charge while the Mac was off? Nil when
    /// there's nothing worth saying (no limit, no record, or it barely moved).
    public static func whileOffNote(_ r: OffRecord?, nowPercent: Int?) -> String? {
        guard let r, let limit = r.limit, let now = nowPercent else { return nil }
        if now > max(r.percent, limit) + 1 {
            return "While this Mac was off it charged from \(r.percent)% to \(now)%, past your \(limit)% limit. "
                + "Apex can’t run while the Mac is off, and this Mac’s firmware charges anyway. Charging stays paused now; "
                + "the power adapter powers the Mac and the battery comes down as you use it unplugged."
        }
        if r.paused, now <= r.percent + 1 { return "Stayed at \(now)% while this Mac was off." }
        return nil
    }

    /// "Charge to 100% now" is active until it expires or the battery has
    /// reached full once (`consumed` holds the override that already got there).
    public static func overrideActive(until: Date?, consumed: Date?, now: Date = Date()) -> Date? {
        guard let until, until > now, until != consumed else { return nil }
        return until
    }

    /// A weekly window that changes the charge limit while it's active.
    /// `days` are Calendar weekdays (1 = Sunday … 7 = Saturday) on which the
    /// window *starts*; `start`/`end` are minutes after midnight, local time.
    /// `end <= start` means it runs past midnight into the next day.
    public struct ChargeSchedule: Codable, Equatable, Sendable, Identifiable {
        public enum Action: Codable, Equatable, Sendable {
            case fullCharge          // allow charging to 100%
            case limit(Int)          // hold at this % (also when the normal limit is off)
        }
        public var id: UUID
        public var enabled: Bool
        public var days: Set<Int>
        public var start: Int
        public var end: Int
        public var action: Action
        public init(id: UUID = UUID(), enabled: Bool = true, days: Set<Int>, start: Int, end: Int, action: Action) {
            self.id = id; self.enabled = enabled; self.days = days; self.start = start; self.end = end; self.action = action
        }

        /// Is this window active at `now`?
        public func isActive(at now: Date, calendar: Calendar = .current) -> Bool {
            guard enabled, !days.isEmpty else { return false }
            let c = calendar.dateComponents([.weekday, .hour, .minute], from: now)
            guard let wd = c.weekday else { return false }
            let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            if start < end { return days.contains(wd) && m >= start && m < end }
            // Past midnight: the late part belongs to today's start, the early part to yesterday's.
            let yesterday = wd == 1 ? 7 : wd - 1
            return (days.contains(wd) && m >= start) || (days.contains(yesterday) && m < end)
        }
    }

    public enum LimitSource: Equatable, Sendable { case normal, override, night, schedule(UUID) }

    /// Night charging: from `start` (minutes after local midnight) hold at
    /// `holdAt`, then charge so the battery is full by `fullBy`, and keep it
    /// full until the Mac is opened (`openedAt`, set by Apex when the screen
    /// wakes) or noon at the latest.
    public struct NightCharging: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var start: Int
        public var fullBy: Int
        public var holdAt: Int
        public var openedAt: Date?
        public init(enabled: Bool = true, start: Int = 20 * 60, fullBy: Int = 7 * 60, holdAt: Int = 80, openedAt: Date? = nil) {
            self.enabled = enabled; self.start = start; self.fullBy = fullBy; self.holdAt = holdAt; self.openedAt = openedAt
        }
    }

    public enum NightPhase: Equatable, Sendable {
        case off
        case hold(until: Date)       // hold at holdAt until top-up starts
        case topUp(fullBy: Date)     // charging to 100%
        case keepFull                // full; waiting for the Mac to be opened
    }

    /// Minutes allowed per percent when topping up, plus a fixed margin.
    public static let topUpMinutesPerPercent = 2.0
    public static let topUpMarginMinutes = 15.0
    /// The night never runs past this time (minutes after midnight).
    public static let nightCutoff = 12 * 60

    /// Which part of the night we're in, and its key times.
    public static func nightPlan(_ n: NightCharging, now: Date, calendar: Calendar = .current)
        -> (phase: NightPhase, start: Date, topUp: Date, fullBy: Date, cutoff: Date) {
        let day = calendar.startOfDay(for: now)
        let mins = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        func at(_ m: Int, daysAfter: Int) -> Date {
            calendar.date(byAdding: .minute, value: m, to: calendar.date(byAdding: .day, value: daysAfter, to: day)!)!
        }
        // The night that's running now started today (evening) or yesterday.
        let startedToday = mins >= n.start
        let start = at(n.start, daysAfter: startedToday ? 0 : -1)
        let fullByDays = n.fullBy > n.start ? 0 : 1
        let fullBy = calendar.date(byAdding: .day, value: fullByDays, to: start).map {
            calendar.date(bySettingHour: n.fullBy / 60, minute: n.fullBy % 60, second: 0, of: $0)!
        }!
        let cutoff = calendar.date(bySettingHour: nightCutoff / 60, minute: 0, second: 0, of: fullBy)!
        let need = (Double(100 - min(100, max(50, n.holdAt))) * topUpMinutesPerPercent + topUpMarginMinutes) * 60
        let topUp = max(start, fullBy.addingTimeInterval(-need))
        let phase: NightPhase
        if !n.enabled || now < start { phase = .off }
        else if now < topUp { phase = .hold(until: topUp) }
        else if now < fullBy { phase = .topUp(fullBy: fullBy) }
        else if now < max(cutoff, fullBy), (n.openedAt ?? .distantPast) < fullBy { phase = .keepFull }
        else { phase = .off }
        return (phase, start, topUp, fullBy, cutoff)
    }

    /// When the helper should wake a sleeping Mac next to re-check (nil = no need).
    public static func nextNightCheck(_ n: NightCharging?, now: Date, calendar: Calendar = .current) -> Date? {
        guard let n, n.enabled else { return nil }
        let p = nightPlan(n, now: now, calendar: calendar)
        let soon = now.addingTimeInterval(30 * 60)
        switch p.phase {
        case .hold(let until): return min(soon, until)
        case .topUp, .keepFull: return soon
        case .off:
            // Tonight's start, if it's within the next 12 hours.
            let next = p.start > now ? p.start : calendar.date(byAdding: .day, value: 1, to: p.start)!
            return next.timeIntervalSince(now) <= 12 * 3600 ? next : nil
        }
    }

    /// The limit that applies right now. Order: "Charge to 100% now" (manual,
    /// always wins) → night charging → an active full-charge window → an active limit window
    /// (the lowest, if several) → the normal limit.
    public static func effectiveLimit(_ c: Config, overrideActive: Bool, now: Date = Date(),
                                      calendar: Calendar = .current) -> (limit: Int?, source: LimitSource) {
        if overrideActive { return (nil, .override) }
        if let n = c.nightCharging {
            switch nightPlan(n, now: now, calendar: calendar).phase {
            case .hold: if chargeLimitRange.contains(n.holdAt) { return (n.holdAt, .night) }
            case .topUp, .keepFull: return (nil, .night)
            case .off: break
            }
        }
        let active = (c.chargeSchedules ?? []).filter { $0.isActive(at: now, calendar: calendar) }
        if let full = active.first(where: { $0.action == .fullCharge }) { return (nil, .schedule(full.id)) }
        let limits = active.compactMap { s -> (Int, UUID)? in
            if case .limit(let l) = s.action, chargeLimitRange.contains(l) { return (l, s.id) }
            return nil
        }
        if let lowest = limits.min(by: { $0.0 < $1.0 }) { return (lowest.0, .schedule(lowest.1)) }
        return (c.chargeLimit, .normal)
    }

    public static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    /// Longest the helper honours one renewal: a stale file can't keep a Mac awake.
    public static let stayAwakeMax: TimeInterval = 10 * 60

    /// Whether the helper should keep system sleep disabled right now.
    public static func sleepDisabled(until: Date?, now: Date = Date()) -> Bool {
        guard let until else { return false }
        let left = until.timeIntervalSince(now)
        return left > 0 && left <= stayAwakeMax
    }

    public static func decode(_ data: Data) -> Config? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(Config.self, from: data)
    }

    public static func encode(_ c: Config) -> Data? {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(c)
    }
}
