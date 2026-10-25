import Foundation

/// What a Bluetooth accessory is, and how much power that kind of device
/// typically uses. macOS doesn't measure an accessory's power, so these are
/// typical figures for the type (set by the user or guessed from the device's
/// Bluetooth class), always shown as an estimate.
enum BluetoothType: String, CaseIterable, Identifiable, Codable, Sendable {
    case earbuds, headphones, speaker, keyboard, mouse, trackpad, controller, watch, phone, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .earbuds: return "Earbuds"
        case .headphones: return "Headphones"
        case .speaker: return "Speaker"
        case .keyboard: return "Keyboard"
        case .mouse: return "Mouse"
        case .trackpad: return "Trackpad"
        case .controller: return "Game controller"
        case .watch: return "Watch or wearable"
        case .phone: return "Phone or tablet"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .earbuds: return "earbuds"
        case .headphones: return "headphones"
        case .speaker: return "hifispeaker"
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .controller: return "gamecontroller"
        case .watch: return "applewatch"
        case .phone: return "iphone"
        case .other: return "wave.3.right"
        }
    }

    /// Typical power the device itself uses while connected and in use, in
    /// watts (low, high). nil: varies too much to estimate.
    var typicalWatts: ClosedRange<Double>? {
        switch self {
        case .earbuds: return 0.02...0.06
        case .headphones: return 0.05...0.3        // higher end with noise cancelling
        case .speaker: return 1...5                // portable speaker at normal volume
        case .keyboard: return 0.01...0.05         // more with a backlight
        case .mouse: return 0.01...0.03
        case .trackpad: return 0.01...0.03
        case .controller: return 0.1...0.5         // more with rumble and lights
        case .watch: return 0.01...0.05
        case .phone, .other: return nil
        }
    }

    /// "about 1–5 W" / "about 20–60 mW", or nil.
    var estimateText: String? {
        guard let w = typicalWatts else { return nil }
        if w.upperBound < 1 {
            return String(format: "about %g–%g mW", (w.lowerBound * 1000).rounded(), (w.upperBound * 1000).rounded())
        }
        return String(format: "about %g–%g W", w.lowerBound, w.upperBound)
    }

    /// Best guess from the Bluetooth class of device (major / minor class).
    static func guess(major: Int, minor: Int, name: String) -> BluetoothType {
        let n = name.lowercased()
        if n.contains("airpods pro") || n.contains("buds") || n.contains("earbuds") { return .earbuds }
        if n.contains("airpods max") { return .headphones }
        if n.contains("airpods") { return .earbuds }
        if n.contains("trackpad") { return .trackpad }
        if n.contains("controller") || n.contains("dualsense") || n.contains("gamepad") { return .controller }
        switch major {
        case 0x04:                                  // audio / video
            switch minor {
            case 0x01, 0x02: return .earbuds        // wearable headset, hands-free
            case 0x06: return .headphones
            case 0x05, 0x07, 0x0A: return .speaker  // loudspeaker, portable audio, hi-fi
            default: return n.contains("speaker") ? .speaker : .headphones
            }
        case 0x05:                                  // peripheral
            if minor & 0x10 != 0 && minor & 0x20 == 0 { return .keyboard }
            if minor & 0x20 != 0 { return n.contains("trackpad") ? .trackpad : .mouse }
            if (minor & 0x0F) == 0x01 || (minor & 0x0F) == 0x02 { return .controller }   // joystick, gamepad
            return .other
        case 0x02: return .phone
        case 0x07: return .watch
        default: return .other
        }
    }
}

/// The types the user set, by device address.
enum BluetoothTypes {
    private static let key = "bluetoothTypes"

    static func saved() -> [String: BluetoothType] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return raw.compactMapValues(BluetoothType.init(rawValue:))
    }

    static func set(_ type: BluetoothType?, for address: String) {
        var raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        raw[address] = type?.rawValue
        UserDefaults.standard.set(raw, forKey: key)
    }
}

/// Which Bluetooth devices the user uses regularly: connected on at least 3
/// different days in the last 14. Those stay in Accessories while switched
/// off; others only show while connected. Removed devices are left out of
/// the remembered list (their usage starts over).
enum BluetoothUsage {
    static let regularDays = 3
    static let window = 14

    private static let daysKey = "bluetoothSeenDays"
    private static let hiddenKey = "bluetoothHidden"

    static func day(_ d: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Pure rule: distinct days seen within the window.
    static func isRegular(_ days: [String], today: Date) -> Bool {
        let cutoff = day(today.addingTimeInterval(-Double(window - 1) * 86400))
        return Set(days.filter { $0 >= cutoff }).count >= regularDays
    }

    /// Records today for each connected device; returns the regular ones.
    static func record(connected: [String], now: Date = Date()) -> Set<String> {
        var all = UserDefaults.standard.dictionary(forKey: daysKey) as? [String: [String]] ?? [:]
        let today = day(now)
        let cutoff = day(now.addingTimeInterval(-Double(window - 1) * 86400))
        for a in connected where !(all[a] ?? []).contains(today) { all[a, default: []].append(today) }
        all = all.mapValues { $0.filter { $0 >= cutoff } }.filter { !$0.value.isEmpty }
        UserDefaults.standard.set(all, forKey: daysKey)
        let hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        return Set(all.filter { isRegular($0.value, today: now) }.keys).subtracting(hidden)
    }

    /// "Remove from Accessories": forget its usage so it isn't remembered.
    static func remove(_ address: String) {
        var all = UserDefaults.standard.dictionary(forKey: daysKey) as? [String: [String]] ?? [:]
        all[address] = nil
        UserDefaults.standard.set(all, forKey: daysKey)
        var hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        hidden.insert(address)
        UserDefaults.standard.set(Array(hidden), forKey: hiddenKey)
    }

    /// Connecting it again later lets it become regular again.
    static func unhideIfConnected(_ connected: [String]) {
        var hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        let before = hidden.count
        hidden.subtract(connected)
        if hidden.count != before { UserDefaults.standard.set(Array(hidden), forKey: hiddenKey) }
    }
}
