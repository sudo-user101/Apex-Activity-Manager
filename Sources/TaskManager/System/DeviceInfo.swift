import Darwin
import Foundation
import SystemConfiguration

/// Identity + network configuration of this Mac, read from SystemConfiguration
/// and getifaddrs (no tools spawned). Cheap; refreshed on demand.
struct DeviceInfo: Sendable {
    var computerName = ""
    var localHostName = ""
    var userName = ""
    var fullName = ""
    var model = ""
    var osVersion = ""
    var interface = ""
    var interfaceName = ""      // "Wi-Fi", "Ethernet"
    var macAddress = ""
    var ipv4 = ""
    var subnetMask = ""
    var router = ""
    var ipv6 = ""
    var dns: [String] = []
    var searchDomains: [String] = []

    static func read() -> DeviceInfo {
        var d = DeviceInfo()
        let store = SCDynamicStoreCreate(nil, "TaskManager" as CFString, nil, nil)
        d.computerName = (SCDynamicStoreCopyComputerName(store, nil) as String?) ?? Host.current().localizedName ?? ""
        d.localHostName = (SCDynamicStoreCopyLocalHostName(store) as String?).map { $0 + ".local" } ?? ""
        d.userName = NSUserName()
        d.fullName = NSFullUserName()
        d.model = Sysctl.string("hw.model") ?? ""
        let v = ProcessInfo.processInfo.operatingSystemVersion
        d.osVersion = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"

        guard let store else { return d }
        if let g = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            d.interface = g["PrimaryInterface"] as? String ?? ""
            d.router = g["Router"] as? String ?? ""
        }
        if !d.interface.isEmpty {
            if let a = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(d.interface)/IPv4" as CFString) as? [String: Any] {
                d.ipv4 = (a["Addresses"] as? [String])?.first ?? ""
                d.subnetMask = (a["SubnetMasks"] as? [String])?.first ?? ""
            }
            if let a = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(d.interface)/IPv6" as CFString) as? [String: Any] {
                d.ipv6 = (a["Addresses"] as? [String])?.first { !$0.hasPrefix("fe80") } ?? ""
            }
            d.macAddress = mac(of: d.interface)
            if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
               let match = all.first(where: { (SCNetworkInterfaceGetBSDName($0) as String?) == d.interface }) {
                d.interfaceName = (SCNetworkInterfaceGetLocalizedDisplayName(match) as String?) ?? ""
            }
        }
        if let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
            d.dns = dns["ServerAddresses"] as? [String] ?? []
            d.searchDomains = dns["SearchDomains"] as? [String] ?? []
        }
        return d
    }

    /// Current link-layer address of an interface (may be a per-network
    /// "private Wi-Fi address" if that is turned on).
    private static func mac(of iface: String) -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return "" }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
               String(cString: cur.pointee.ifa_name) == iface {
                return sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> String in
                    let len = Int(dl.pointee.sdl_alen)
                    guard len == 6 else { return "" }
                    let offset = Int(dl.pointee.sdl_nlen)
                    return withUnsafeBytes(of: dl.pointee.sdl_data) { raw in
                        (0..<len).map { String(format: "%02x", raw[offset + $0]) }.joined(separator: ":")
                    }
                }
            }
            p = cur.pointee.ifa_next
        }
        return ""
    }
}

/// RAM type and speed. Intel Macs report the speed; on Apple Silicon macOS
/// only reports the type, so the speed comes from Apple's published specs
/// for the chip.
struct MemorySpec: Sendable {
    var type = ""
    var speed = ""          // e.g. "4266 MT/s"
    var manufacturer = ""
    var fromSpecSheet = false

    static func read() -> MemorySpec {
        var m = MemorySpec()
        if let out = Shell.capture("/usr/sbin/system_profiler", ["SPMemoryDataType", "-json"]),
           let d = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
           let list = d["SPMemoryDataType"] as? [[String: Any]], let first = list.first {
            let dimm = (first["_items"] as? [[String: Any]])?.first ?? first
            m.type = (dimm["dimm_type"] as? String) ?? ""
            m.manufacturer = (dimm["dimm_manufacturer"] as? String) ?? ""
            if let sp = dimm["dimm_speed"] as? String, !sp.isEmpty, sp != "Empty" { m.speed = sp }
        }
        if m.speed.isEmpty, let chip = Sysctl.string("machdep.cpu.brand_string"), chip.hasPrefix("Apple ") {
            let spec = appleSilicon(chip)
            if let spec { m.speed = spec.speed; if m.type.isEmpty || spec.type.hasPrefix(m.type) { m.type = spec.type }; m.fromSpecSheet = true }
        }
        return m
    }

    private static func appleSilicon(_ chip: String) -> (type: String, speed: String)? {
        let c = chip.replacingOccurrences(of: "Apple ", with: "")
        if c.hasPrefix("M1") { return c == "M1" ? ("LPDDR4X", "4266 MT/s") : ("LPDDR5", "6400 MT/s") }
        if c.hasPrefix("M2") || c.hasPrefix("M3") { return ("LPDDR5", "6400 MT/s") }
        if c.hasPrefix("M4") { return c == "M4" ? ("LPDDR5X", "7500 MT/s") : ("LPDDR5X", "8533 MT/s") }
        return nil
    }
}
