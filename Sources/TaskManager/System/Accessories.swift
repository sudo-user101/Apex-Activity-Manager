import Foundation

/// USB devices plugged into this Mac and the power each one has been given.
///
/// macOS doesn't measure what each accessory actually draws. What it does
/// record is how much current each USB device asked for and was allocated
/// (`bus_power_used`, from the device's own descriptor), so that's shown as
/// "up to" a number of watts at USB's 5 V. Devices that negotiate more over
/// USB‑C Power Delivery, or have their own power supply, may use more or less.
struct USBAccessory: Hashable, Sendable, Identifiable {
    var id: String { location }
    var name: String
    var vendor: String
    var location: String
    var milliamps: Int              // allocated by macOS (declared maximum)
    var availableMilliamps: Int     // what the port offers
    var speed: String
    var serial = ""
    var children: [USBAccessory] = []   // devices plugged into this one (a hub or dock)
    var maxWatts: Double { Double(milliamps) * 5 / 1000 }
    var isHub: Bool { !children.isEmpty || name.localizedCaseInsensitiveContains("hub") }
    /// This device plus everything behind it.
    var totalWatts: Double { maxWatts + children.reduce(0) { $0 + $1.totalWatts } }
    var flattened: [USBAccessory] { [self] + children.flatMap(\.flattened) }
}

enum Accessories {
    /// `system_profiler SPUSBDataType -json` (~0.5 s, so it's read on demand).
    static func usb() -> [USBAccessory] {
        guard let out = Shell.capture("/usr/sbin/system_profiler", ["SPUSBDataType", "-json"]) else { return [] }
        return parse(Data(out.utf8))
    }

    /// Top-level devices, each with whatever is plugged into it (hubs, docks).
    static func parse(_ data: Data) -> [USBAccessory] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buses = root["SPUSBDataType"] as? [[String: Any]] else { return [] }
        func devices(_ node: [String: Any]) -> [USBAccessory] {
            (node["_items"] as? [[String: Any]] ?? []).compactMap { item in
                guard let name = item["_name"] as? String else { return nil }
                let vendor = (item["vendor_id"] as? String).flatMap { v in
                    v.range(of: "(").map { String(v[$0.upperBound...].dropLast()) }
                } ?? (item["manufacturer"] as? String ?? "")
                return USBAccessory(name: name.trimmingCharacters(in: .whitespaces),
                                    vendor: vendor.trimmingCharacters(in: .whitespaces),
                                    location: item["location_id"] as? String ?? name,
                                    milliamps: Self.int(item["bus_power_used"]) + Self.int(item["extra_current_used"]),
                                    availableMilliamps: Self.int(item["bus_power"]),
                                    speed: speedName(item["device_speed"] as? String ?? ""),
                                    serial: (item["serial_num"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                                    children: devices(item))
            }
        }
        return buses.flatMap(devices)
    }

    private static func int(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s.filter(\.isNumber)) ?? 0 }
        return 0
    }

    static func speedName(_ s: String) -> String {
        switch s {
        case "low_speed": return "USB 1.0"
        case "full_speed": return "USB 1.1"
        case "high_speed": return "USB 2.0"
        case "super_speed": return "USB 3 (5 Gb/s)"
        case "super_speed_plus": return "USB 3 (10 Gb/s)"
        default: return s.isEmpty ? "" : s.replacingOccurrences(of: "_", with: " ")
        }
    }
}
