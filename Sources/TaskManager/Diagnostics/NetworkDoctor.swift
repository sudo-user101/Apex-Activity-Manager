import CoreWLAN
import Foundation
import SystemConfiguration

/// Network Doctor: why the internet is slow or not working, in plain words.
/// `NetworkProbe` measures (~10 s), `NetworkDoctor.diagnose` is pure rules:
/// the checks go from the Mac outwards (link → address → router → internet →
/// names → sign-in page), so the first thing that fails is the place to fix.
enum NetworkDoctor {
    struct Ping: Equatable, Sendable {
        var sent: Int, received: Int, avgMs: Double?
        var loss: Double { sent > 0 ? 1 - Double(received) / Double(sent) : 1 }
        var reachable: Bool { received > 0 }
    }

    struct Input: Sendable {
        var name = "Wi-Fi"                   // the connection's name (tab)
        var kind = "Wi-Fi"                   // "Wi-Fi", "Ethernet", "VPN"…
        var interface = "en0"
        var isUp = true
        var address = ""
        var gateway = ""
        var rssi: Int? = nil                 // dBm (Wi-Fi)
        var noise: Int? = nil
        var txRate: Double? = nil            // Mb/s the Wi-Fi link runs at
        var band: String? = nil              // "2.4 GHz", "5 GHz", "6 GHz"
        var router: Ping? = nil
        var internet: Ping? = nil
        var httpsOK: Bool? = nil             // reached a well-known HTTPS site
        var dnsOK: Bool? = nil
        var dnsMs: Double? = nil
        var signInPage: Bool? = nil          // a captive portal is in the way
        var speed: SpeedResult? = nil
    }

    static func diagnose(_ i: Input) -> DiagnosisReport {
        var f: [Finding] = []
        let wifi = i.kind == "Wi-Fi"
        func m(_ l: String, _ v: String) -> Evidence { Evidence(label: l, value: v, source: .measured) }
        var wifiEvidence: [Evidence] {
            guard wifi else { return [] }
            return [i.rssi.map { m("Signal", "\($0) dBm (\(signalWord($0)))") }, i.noise.map { m("Noise", "\($0) dBm") },
                    i.txRate.map { m("Wi-Fi link speed", String(format: "%.0f Mb/s", $0)) }, i.band.map { m("Band", $0) }]
                .compactMap { $0 }
        }

        // 1. The link itself.
        guard i.isUp else {
            f.append(Finding(id: "net.down", title: wifi ? "Wi-Fi isn’t connected to a network" : "\(i.name) has no connection",
                             why: "Nothing can get online until this connection is up.",
                             severity: .critical, confidence: .confirmed, evidence: [m("Status", "Not connected")],
                             causes: wifi ? ["Wi-Fi is turned off", "Not joined to a network, or the password changed", "Out of range of the router"]
                                          : ["The cable is unplugged or damaged", "The router or switch port is off"],
                             steps: wifi ? [.init(title: "Turn Wi-Fi on and choose your network", expected: "Status changes to Connected.")]
                                         : [.init(title: "Check both ends of the cable, or try another port on the router")],
                             actions: wifi ? [.openWiFiSettings] : [.openNetworkSettings]))
            return DiagnosisReport(subject: i.name, findings: f)
        }

        // 2. An address from the router (DHCP).
        if i.address.isEmpty || i.address.hasPrefix("169.254.") {
            f.append(Finding(id: "net.dhcp", title: "The router didn’t give this Mac an address",
                             why: "Without an address from the router, the Mac is connected but can’t talk to anything.",
                             severity: .critical, confidence: .confirmed,
                             evidence: [m("Address", i.address.isEmpty ? "none" : i.address + " (made up by the Mac)")],
                             causes: ["The router is busy or needs a restart", "The router has run out of addresses for new devices"],
                             steps: [.init(title: "Turn Wi-Fi off and on again", expected: "An address like 192.168.x.x appears."),
                                     .init(title: "Restart the router (unplug it for 10 seconds)")],
                             actions: wifi ? [.restartWiFi, .openNetworkSettings] : [.openNetworkSettings]))
        }

        // 3. The router.
        if let r = i.router, !i.gateway.isEmpty {
            let weak = wifi && (i.rssi ?? 0) < -70
            if !r.reachable {
                f.append(Finding(id: "net.router", title: "The router doesn’t answer",
                                 why: "Everything goes through the router; if it doesn’t answer, nothing gets online.",
                                 severity: .critical, confidence: .likely,
                                 evidence: [m("Router", i.gateway), m("Answers", "0 of \(r.sent)")] + wifiEvidence,
                                 causes: (weak ? ["The Wi-Fi signal is too weak here"] : []) + ["The router has frozen", "Some routers ignore these checks (then the next results tell more)"],
                                 steps: [.init(title: "Move closer to the router, or restart it (unplug for 10 seconds)", expected: "The router answers again.")],
                                 actions: wifi ? [.restartWiFi] : [.openNetworkSettings]))
            } else if r.loss >= 0.2 {
                f.append(Finding(id: "net.router.loss", title: "The connection to your router keeps dropping",
                                 why: "\(Int((r.loss * 100).rounded()))% of messages to the router were lost. Pages stall, calls break up.",
                                 severity: .warning, confidence: .likely,
                                 evidence: [m("Lost", "\(r.sent - r.received) of \(r.sent)")] + wifiEvidence,
                                 causes: wifi ? ["Weak signal or walls in the way", "Interference from other networks or devices"] : ["A damaged cable or loose plug"],
                                 steps: wifi ? [.init(title: "Move closer to the router"), .init(title: "Use the 5 GHz network if your router has one")]
                                             : [.init(title: "Try another cable")],
                                 actions: wifi ? [.restartWiFi] : []))
            } else if wifi, let avg = r.avgMs, avg > 30 {
                f.append(Finding(id: "net.router.slow", title: "Your Wi-Fi is congested",
                                 why: String(format: "The router takes %.0f ms to answer; on a healthy Wi-Fi it's under 10 ms.", avg),
                                 severity: .notice, confidence: .possible,
                                 evidence: [m("Router answers in", String(format: "%.0f ms", avg))] + wifiEvidence,
                                 causes: ["Many devices busy on the same Wi-Fi", "Neighbouring networks on the same channel", "A weak signal"],
                                 steps: [.init(title: "Pause big downloads or streams on other devices"), .init(title: "Restart the router so it picks a quieter channel")]))
            }
        }

        // 4. The internet beyond the router.
        let routerOK = i.router?.reachable ?? true
        let internetOK = (i.internet?.reachable ?? false) || (i.httpsOK ?? false)
        if routerOK, i.internet != nil || i.httpsOK != nil, !internetOK, i.signInPage != true {
            f.append(Finding(id: "net.internet", title: "Your router is fine, but the internet behind it isn’t",
                             why: "The Mac reaches the router, but nothing past it. The problem is the internet connection itself, not this Mac.",
                             severity: .critical, confidence: .likely,
                             evidence: [m("Router", "answers"), m("Internet", "no answer")],
                             causes: ["Your internet provider has an outage", "The modem or router lost its internet connection", "An unpaid or expired plan"],
                             steps: [.init(title: "Restart the modem and router (unplug both for 30 seconds, then the modem first)",
                                           expected: "Other devices get online again too."),
                                     .init(title: "If other devices can't get online either, contact your internet provider")],
                             escalate: "If it lasts, your internet provider can check the line from their side."))
        } else if let p = i.internet, p.reachable, let avg = p.avgMs, avg > 150 {
            f.append(Finding(id: "net.latency", title: "The internet is slow to respond",
                             why: String(format: "Messages take %.0f ms to get a reply; video calls and games feel laggy above about 100 ms.", avg),
                             severity: .notice, confidence: .possible, evidence: [m("Reply time", String(format: "%.0f ms", avg))],
                             causes: ["Busy network at home", "A VPN routing traffic far away", "Congestion at your internet provider"]))
        }

        // 5. Names (DNS).
        if internetOK, i.dnsOK == false {
            f.append(Finding(id: "net.dns", title: "Website names don’t work (DNS)",
                             why: "The internet is reachable, but turning names like apple.com into addresses fails, so websites won't open.",
                             severity: .warning, confidence: .likely, evidence: [m("Looking up apple.com", "failed")],
                             causes: ["The router's name service has stopped", "Your provider's name service is down"],
                             steps: [.init(title: "Restart the router"),
                                     .init(title: "Or set DNS servers to 1.1.1.1 and 8.8.8.8 in Network settings › Details › DNS",
                                           expected: "Websites open again.")],
                             actions: [.openNetworkSettings]))
        } else if let ms = i.dnsMs, ms > 300 {
            f.append(Finding(id: "net.dns.slow", title: "Website names are slow to look up",
                             why: String(format: "Each new website waits %.0f ms before it starts loading.", ms),
                             severity: .notice, confidence: .possible, evidence: [m("Looking up apple.com", String(format: "%.0f ms", ms))],
                             steps: [.init(title: "Set DNS servers to 1.1.1.1 and 8.8.8.8 in Network settings › Details › DNS")],
                             actions: [.openNetworkSettings]))
        }

        // 6. A sign-in page (hotels, cafés, airports).
        if i.signInPage == true {
            f.append(Finding(id: "net.portal", title: "This network wants you to sign in",
                             why: "Until you accept its terms or sign in, the network blocks the internet.",
                             severity: .warning, confidence: .confirmed, evidence: [m("Test page", "replaced by the network's own page")],
                             steps: [.init(title: "Open the sign-in page and accept or log in", expected: "The internet works right after.")],
                             actions: [.openLoginPage]))
        }

        // 7. Wi-Fi signal.
        if wifi, let rssi = i.rssi, !f.contains(where: { $0.id.hasPrefix("net.router") }) {
            if rssi < -75 {
                f.append(Finding(id: "net.signal", title: "The Wi-Fi signal is weak here",
                                 why: "At \(rssi) dBm the connection slows down and drops now and then.",
                                 severity: .warning, confidence: .confirmed, evidence: wifiEvidence,
                                 steps: [.init(title: "Move closer to the router, or remove walls and metal in the way"),
                                         .init(title: "A mesh system or extender helps in far rooms")]))
            } else if rssi < -67 {
                f.append(Finding(id: "net.signal", title: "The Wi-Fi signal is only fair",
                                 why: "Fine for browsing; video calls and big downloads may stutter.",
                                 severity: .info, confidence: .confirmed, evidence: wifiEvidence))
            }
            if let n = i.noise, rssi - n < 20 {
                f.append(Finding(id: "net.noise", title: "Lots of Wi-Fi interference",
                                 why: "The signal is barely louder than the background noise (\(rssi - n) dB apart; 25+ is good).",
                                 severity: .notice, confidence: .likely, evidence: wifiEvidence,
                                 causes: ["Many networks nearby on the same channel", "Microwaves, Bluetooth and cordless phones on 2.4 GHz"],
                                 steps: [.init(title: "Use the 5 GHz network if you have one"), .init(title: "Restart the router so it picks a quieter channel")]))
            }
        }

        // 8. Speed (from the last test, if any).
        if let s = i.speed, s.download < 5e6 {
            f.append(Finding(id: "net.speed", title: "The internet speed is low",
                             why: "\(s.downloadText) down: enough for email and browsing, slow for video.",
                             severity: .notice, confidence: .confirmed,
                             evidence: [m("Download", s.downloadText), m("Upload", s.uploadText), m("Tested", s.date.formatted(date: .abbreviated, time: .shortened))],
                             causes: ["Your plan's speed", "Others using the internet at the same time", "Wi-Fi limits (check the signal above)"]))
        }

        if f.isEmpty {
            var ev = [m("Address", i.address)]
            if let r = i.router { ev.append(m("Router", r.avgMs.map { String(format: "answers in %.0f ms", $0) } ?? "answers")) }
            if let p = i.internet, p.reachable { ev.append(m("Internet", p.avgMs.map { String(format: "answers in %.0f ms", $0) } ?? "answers")) }
            if let d = i.dnsMs { ev.append(m("Names (DNS)", String(format: "%.0f ms", d))) }
            f.append(Finding(id: "net.ok", title: "Everything checks out",
                             why: "This Mac, the router, the internet and website names all work. If something still feels slow, it's likely the website or app itself.",
                             severity: .ok, confidence: .confirmed, evidence: ev + wifiEvidence))
        }
        var missing: [String] = []
        if i.speed == nil { missing.append("No speed test yet: use Internet connection speed on the Network page to add one.") }
        return DiagnosisReport(subject: i.name, findings: f, missing: missing)
    }

    static func signalWord(_ rssi: Int) -> String {
        rssi >= -55 ? "excellent" : rssi >= -67 ? "good" : rssi >= -75 ? "fair" : "weak"
    }

    /// `ping -q` summary → result. Pure: tested.
    static func parsePing(_ out: String) -> Ping? {
        guard let line = out.split(separator: "\n").first(where: { $0.contains("packets transmitted") }) else { return nil }
        let nums = line.split(separator: " ").compactMap { Int($0) }
        guard nums.count >= 2 else { return nil }
        var avg: Double?
        if let rt = out.split(separator: "\n").first(where: { $0.contains("round-trip") || $0.contains("rtt") }),
           let eq = rt.split(separator: "=").last {
            let parts = eq.trimmingCharacters(in: .whitespaces).split(separator: "/")
            if parts.count >= 2 { avg = Double(parts[1]) }
        }
        return Ping(sent: nums[0], received: nums[1], avgMs: avg)
    }
}

/// Runs the Network Doctor's checks for one connection. Blocking (~10 s):
/// call off the main thread.
enum NetworkProbe {
    static func run(device: NetworkDevice, primary: String) -> NetworkDoctor.Input {
        var i = NetworkDoctor.Input(name: device.name, kind: device.kind, interface: device.id, isUp: device.isUp, address: device.address)
        guard device.isUp else { return i }
        if device.kind == "Wi-Fi", let w = CWWiFiClient.shared().interface(withName: device.id) {
            let rssi = w.rssiValue(), noise = w.noiseMeasurement()
            if rssi != 0 { i.rssi = rssi }
            if noise != 0 { i.noise = noise }
            if w.transmitRate() > 0 { i.txRate = w.transmitRate() }
            switch w.wlanChannel()?.channelBand {
            case .band2GHz: i.band = "2.4 GHz"
            case .band5GHz: i.band = "5 GHz"
            case .band6GHz: i.band = "6 GHz"
            default: break
            }
        }
        if let store = SCDynamicStoreCreate(nil, "Apex" as CFString, nil, nil),
           let g = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           g["PrimaryInterface"] as? String == device.id {
            i.gateway = g["Router"] as? String ?? ""
        }
        let group = DispatchGroup()
        var router: NetworkDoctor.Ping?, internet: NetworkDoctor.Ping?, https: Bool?, dns: (Bool, Double)?, portal: Bool?
        let lock = NSLock()
        func bg(_ work: @escaping () -> Void) { group.enter(); DispatchQueue.global(qos: .userInitiated).async { work(); group.leave() } }
        if !i.gateway.isEmpty { bg { let p = ping(i.gateway, interface: device.id); lock.withLock { router = p } } }
        bg { let p = ping("1.1.1.1", interface: device.id); lock.withLock { internet = p } }
        if device.id == primary {
            bg { let ok = fetch("https://www.apple.com/library/test/success.html", expect: "Success"); lock.withLock { https = ok } }
            bg { let d = lookup("www.apple.com"); lock.withLock { dns = d } }
            bg { let ok = fetch("http://captive.apple.com/hotspot-detect.html", expect: "Success"); lock.withLock { portal = ok.map { !$0 } } }
        }
        _ = group.wait(timeout: .now() + 15)
        lock.withLock {
            i.router = router; i.internet = internet; i.httpsOK = https; i.signInPage = portal
            if let dns { i.dnsOK = dns.0; i.dnsMs = dns.0 ? dns.1 : nil }
        }
        // A sign-in page answers the test with its own page, so HTTPS "fails" too; don't blame the provider.
        if i.signInPage == true { i.httpsOK = nil }
        i.speed = SpeedTest.saved(device.id)
        return i
    }

    static func ping(_ host: String, interface: String) -> NetworkDoctor.Ping? {
        let r = Shell.run("/sbin/ping", ["-q", "-c", "8", "-i", "0.25", "-t", "5", "-b", interface, host])
        return NetworkDoctor.parsePing(r.stdout)
    }

    /// nil = couldn't tell (e.g. timed out before any answer).
    static func fetch(_ url: String, expect: String) -> Bool? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.setValue("Apex Activity Manager", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var result: Bool?
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let data, (resp as? HTTPURLResponse) != nil { result = String(decoding: data.prefix(4096), as: UTF8.self).contains(expect) }
            else if err != nil { result = false }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 8)
        return result
    }

    /// (resolved, milliseconds), with a 4 s limit.
    static func lookup(_ host: String) -> (Bool, Double) {
        let start = DispatchTime.now()
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        Thread.detachNewThread {
            var res: UnsafeMutablePointer<addrinfo>?
            var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
            ok = getaddrinfo(host, "443", &hints, &res) == 0
            if let res { freeaddrinfo(res) }
            sem.signal()
        }
        let done = sem.wait(timeout: .now() + 4) == .success
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        return (done && ok, ms)
    }
}
