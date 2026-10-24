import Foundation
import SystemConfiguration

/// This Mac's IPv4 addresses, one per active interface (getifaddrs, no network
/// traffic). The primary interface, the one macOS routes through, comes first.
/// Nothing here contacts the internet, so the public address is never shown,
/// and a private address is never called public.
struct LocalAddress: Hashable, Sendable {
    var interface: String        // "en0"
    var kind: String             // "Wi-Fi", "Ethernet", "VPN", "iPhone"…
    var address: String
    var isPrimary: Bool

    enum Scope: String, Sendable { case privateLAN = "Private", linkLocal = "Link-local", carrierNAT = "Shared (CGNAT)", publicIP = "Public" }
    var scope: Scope { Self.scope(of: address) }

    static func scope(of ip: String) -> Scope {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return .privateLAN }
        switch (p[0], p[1]) {
        case (10, _), (192, 168), (172, 16...31): return .privateLAN
        case (169, 254): return .linkLocal
        case (100, 64...127): return .carrierNAT
        default: return .publicIP
        }
    }
}

enum LocalAddresses {
    static func read() -> [LocalAddress] {
        let primary = primaryInterface()
        let names = displayNames()
        var out: [LocalAddress] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(p.pointee.ifa_flags)
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: p.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            out.append(LocalAddress(interface: name, kind: kind(name, names[name]), address: ip, isPrimary: name == primary))
        }
        return sort(out)
    }

    /// Primary first, then real interfaces before VPN tunnels, then by name.
    static func sort(_ a: [LocalAddress]) -> [LocalAddress] {
        a.sorted { x, y in
            if x.isPrimary != y.isPrimary { return x.isPrimary }
            if (x.kind == "VPN") != (y.kind == "VPN") { return y.kind == "VPN" }
            return x.interface < y.interface
        }
    }

    static func kind(_ bsd: String, _ display: String?) -> String {
        if bsd.hasPrefix("utun") || bsd.hasPrefix("ipsec") || bsd.hasPrefix("ppp") || bsd.hasPrefix("tun") || bsd.hasPrefix("tap") { return "VPN" }
        if bsd.hasPrefix("bridge") { return "Bridge" }
        return display ?? "Network"
    }

    private static func primaryInterface() -> String {
        guard let store = SCDynamicStoreCreate(nil, "Apex" as CFString, nil, nil),
              let g = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return "" }
        return g["PrimaryInterface"] as? String ?? ""
    }

    private static func displayNames() -> [String: String] {
        var m: [String: String] = [:]
        for i in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            if let b = SCNetworkInterfaceGetBSDName(i) as String?, let n = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? { m[b] = n }
        }
        return m
    }
}
