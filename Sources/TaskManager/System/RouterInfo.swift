import Darwin
import Foundation

/// Names for the router and for this Mac on the network.
///
/// - DNS name: reverse lookup (`getnameinfo`, name required) with a short timeout.
/// - Router friendly name / maker / model: UPnP. One SSDP search for an
///   Internet Gateway Device, accepting only a reply from the router's own IP
///   whose description URL also points at the router, then that small XML file.
///
/// Runs only while the Network page is open; results are cached per router IP.
struct RouterIdentity: Sendable, Equatable {
    var dnsName = ""
    var friendlyName = ""
    var manufacturer = ""
    var model = ""
    var displayName: String { !dnsName.isEmpty ? dnsName : friendlyName }
    var modelLine: String { [manufacturer, model].filter { !$0.isEmpty }.joined(separator: " ") }
}

enum RouterLookup {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (RouterIdentity, Date)] = [:]
    nonisolated(unsafe) private static var nameCache: [String: (String, Date)] = [:]

    /// Router identity, cached for 10 minutes per router IP.
    static func identity(router ip: String) async -> RouterIdentity {
        guard isIPv4(ip) else { return RouterIdentity() }
        let hit = lock.withLock { cache[ip] }
        if let hit, Date().timeIntervalSince(hit.1) < 600 { return hit.0 }
        var id = RouterIdentity()
        async let dns = reverseName(ip)
        async let upnp = upnpDescription(router: ip)
        id.dnsName = await dns
        if let u = await upnp { id.friendlyName = u.friendly; id.manufacturer = u.manufacturer; id.model = u.model }
        let stored = id; lock.withLock { cache[ip] = (stored, Date()) }
        return id
    }

    /// This Mac's name as the network's DNS knows it (often set by the router).
    static func networkName(of ip: String) async -> String {
        guard isIPv4(ip) else { return "" }
        let hit = lock.withLock { nameCache[ip] }
        if let hit, Date().timeIntervalSince(hit.1) < 600 { return hit.0 }
        let n = await reverseName(ip)
        lock.withLock { nameCache[ip] = (n, Date()) }
        return n
    }

    static func isIPv4(_ s: String) -> Bool { var a = in_addr(); return inet_pton(AF_INET, s, &a) == 1 }

    /// Reverse DNS with a 2 s limit (getnameinfo can block much longer).
    static func reverseName(_ ip: String, timeout: TimeInterval = 2) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let done = NSLock(); var resumed = false
            func finish(_ v: String) { done.lock(); defer { done.unlock() }; if !resumed { resumed = true; cont.resume(returning: v) } }
            Thread.detachNewThread {
                var sa = sockaddr_in(); sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); sa.sin_family = sa_family_t(AF_INET)
                inet_pton(AF_INET, ip, &sa.sin_addr)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let r = withUnsafePointer(to: &sa) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                    }
                }
                finish(r == 0 ? cleanName(String(cString: host)) : "")
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish("") }
        }
    }

    static func cleanName(_ s: String) -> String { s.hasSuffix(".") ? String(s.dropLast()) : s }

    // MARK: UPnP

    struct UPnP: Equatable { var friendly = "", manufacturer = "", model = "" }

    static func upnpDescription(router ip: String) async -> UPnP? {
        guard let location = await Task.detached(priority: .utility, operation: { ssdpLocation(router: ip) }).value,
              let url = URL(string: location), url.scheme == "http", url.host == ip else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        req.setValue("Apex Activity Manager", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req), data.count < 256_000,
              let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let u = parseDescription(xml)
        return u.friendly.isEmpty && u.model.isEmpty ? nil : u
    }

    /// First value of each tag in a UPnP device description (the root device).
    static func parseDescription(_ xml: String) -> UPnP {
        func tag(_ name: String) -> String {
            guard let open = xml.range(of: "<\(name)>"), let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return "" }
            return String(xml[open.upperBound..<close.lowerBound])
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return UPnP(friendly: tag("friendlyName"), manufacturer: tag("manufacturer"), model: tag("modelName"))
    }

    /// The LOCATION header from an SSDP reply sent by the router itself.
    static func ssdpLocation(router ip: String, wait: TimeInterval = 2.5) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
        var dest = sockaddr_in(); dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)
        let sent = msg.withCString { p in
            withUnsafePointer(to: &dest) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, p, strlen(p), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard sent > 0 else { return nil }
        let deadline = Date().addingTimeInterval(wait)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buf, buf.count, 0, $0, &len) } }
            guard n > 0 else { continue }
            var addr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &addr, socklen_t(addr.count))
            guard String(cString: addr) == ip, let text = String(bytes: buf[0..<n], encoding: .utf8) else { continue }
            if let loc = locationHeader(text) { return loc }
        }
        return nil
    }

    static func locationHeader(_ reply: String) -> String? {
        for line in reply.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "location" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
