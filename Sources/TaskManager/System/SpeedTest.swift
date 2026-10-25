import Foundation

/// Internet connection speed, measured with macOS's own `networkQuality`
/// tool through one interface. Only runs when asked (it takes ~15 s and
/// moves real data); the last result per interface is kept.
struct SpeedResult: Codable, Equatable, Sendable {
    var download: Double        // bits per second
    var upload: Double
    var responsiveness: Int?    // round trips per minute under load (higher is better)
    var date: Date

    var downloadText: String { Self.bits(download) }
    var uploadText: String { Self.bits(upload) }

    static func bits(_ v: Double) -> String {
        v >= 1e9 ? String(format: "%.2f Gb/s", v / 1e9) : v >= 1e6 ? String(format: "%.0f Mb/s", v / 1e6) : String(format: "%.0f kb/s", v / 1e3)
    }

    /// `networkQuality -c` JSON → result.
    static func parse(_ json: String, date: Date = Date()) -> SpeedResult? {
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let dl = (o["dl_throughput"] as? NSNumber)?.doubleValue,
              let ul = (o["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
        let rpm = (o["responsiveness"] as? NSNumber)?.intValue ?? (o["dl_responsiveness"] as? NSNumber)?.intValue
        return SpeedResult(download: dl, upload: ul, responsiveness: rpm, date: date)
    }
}

enum SpeedTest {
    private static let key = "speedResults"

    static func saved(_ interface: String) -> SpeedResult? {
        guard let d = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: SpeedResult].self, from: d) else { return nil }
        return all[interface]
    }

    private static func save(_ r: SpeedResult, _ interface: String) {
        var all = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: SpeedResult].self, from: $0) } ?? [:]
        all[interface] = r
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// Blocking (~15 s): call off the main thread.
    static func run(interface: String) -> SpeedResult? {
        let r = Shell.run("/usr/bin/networkQuality", ["-c", "-I", interface, "-M", "25"])
        guard r.launched, let result = SpeedResult.parse(r.stdout) else { return nil }
        save(result, interface)
        return result
    }
}
