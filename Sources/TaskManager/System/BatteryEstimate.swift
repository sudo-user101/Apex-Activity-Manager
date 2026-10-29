import Foundation

/// Battery time left from how this Mac is actually used: learns the Mac's
/// power draw on battery (the last ~10 minutes, and the usual draw over many
/// hours, kept across launches) and which apps account for it, and turns the
/// battery's remaining energy into "about 4 h 20 min at your current use".
/// Learns whenever Apex runs (window or menu bar), only while on battery.
/// Pure: tested.
struct BatteryLearner: Codable, Equatable, Sendable {
    /// Whole-Mac draw on battery (W): recent (minutes) and usual (hours).
    var recentWatts: Double?
    var usualWatts: Double?
    /// Each app's share of the draw (W), recent.
    var appWatts: [String: Double] = [:]
    var learnedMinutes = 0

    /// One reading (about once a minute) while on battery.
    mutating func learn(watts: Double, apps: [String: Double]) {
        guard watts > 0.5, watts < 200 else { return }          // ignore nonsense readings
        recentWatts = Self.ewma(recentWatts, watts, 0.15)       // ~10 minutes
        usualWatts = Self.ewma(usualWatts, watts, 0.005)        // ~3 hours of battery use
        var next: [String: Double] = [:]
        for name in Set(appWatts.keys).union(apps.keys) {
            let v = Self.ewma(appWatts[name], apps[name] ?? 0, 0.15)
            if v > 0.02 { next[name] = v }                       // apps that stopped fade out
        }
        appWatts = next
        learnedMinutes += 1
    }

    struct Estimate: Equatable, Sendable {
        var minutes: Double
        var low: Double, high: Double
        var drivers: [String]
        var basis: String
    }

    /// Time left for `percent` of a battery holding `capacityMAh` at `volts`.
    /// Nil until a few minutes on battery have been seen.
    func estimate(percent: Int, capacityMAh: Int, volts: Double) -> Estimate? {
        guard let recent = recentWatts, learnedMinutes >= 3, capacityMAh > 0, volts > 0 else { return nil }
        let wh = Double(percent) / 100 * Double(capacityMAh) * volts / 1000
        let usual = usualWatts ?? recent
        // Mostly what's happening now, a little of what's usual for this Mac.
        let blended = learnedMinutes < 30 ? recent : 0.75 * recent + 0.25 * usual
        let minutes = wh / blended * 60
        let fast = max(recent, usual), slow = min(recent, usual)
        let apps = appWatts.filter { $0.value >= 0.3 }.sorted { $0.value > $1.value }.prefix(2).map(\.key)
        let rest = recent - appWatts.values.reduce(0, +)
        var drivers = apps
        if rest > recent * 0.4 { drivers.append("the display and the rest of the Mac") }
        return Estimate(minutes: minutes, low: wh / fast * 60, high: wh / slow * 60, drivers: drivers,
                        basis: learnedMinutes < 30 ? "from the last few minutes" : "from how you’ve been using it")
    }

    static func ewma(_ old: Double?, _ new: Double, _ alpha: Double) -> Double { old.map { $0 + alpha * (new - $0) } ?? new }

    /// "about 4 h 20 min at your current use · mostly Safari and the display".
    static func describe(_ e: Estimate) -> String {
        var s = "About " + Fmt.minutes(Int(e.minutes.rounded())) + " at your current use"
        if !e.drivers.isEmpty { s += " · mostly " + (e.drivers.count == 1 ? e.drivers[0] : e.drivers.dropLast().joined(separator: ", ") + " and " + e.drivers.last!) }
        return s
    }
}
