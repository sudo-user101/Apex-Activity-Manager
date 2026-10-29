import XCTest
import SwiftUI
@testable import TaskManager

final class SitesTests: XCTestCase {
    private func fixture() throws -> ProxyReport {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sites-ubuntu-nginx.json")
        return try JSONDecoder().decode(ProxyReport.self, from: Data(contentsOf: url))
    }

    /// Server Edition 1.1's own answer (`apex-server sites` on Ubuntu 24.04 with nginx).
    func testReadsServerEditionReport() throws {
        let r = try fixture()
        XCTAssertEqual(r.proxies.first?.kind, "nginx")
        XCTAssertEqual(r.proxies.first?.editable, true)
        let app = try XCTUnwrap(r.sites.first { $0.name == "app.test" })
        XCTAssertTrue(app.managed)
        XCTAssertEqual(app.spec?.upstream, "http://127.0.0.1:3000")
        XCTAssertEqual(app.targets, ["http://127.0.0.1:3000"])
        XCTAssertGreaterThan(app.traffic?.requests ?? 0, 0)
        let def = try XCTUnwrap(r.sites.first { $0.name == "(any name)" })
        XCTAssertNil(def.traffic)
        XCTAssertNotNil(def.trafficNote)
        XCTAssertTrue(def.canToggle)
    }

    func testHealth() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func site(enabled: Bool = true, expires: Double? = nil, problem: String? = nil, requests: Int = 0, fiveXX: Int = 0) -> ProxyReport.Site {
            ProxyReport.Site(id: "x", proxy: "nginx", domains: ["a.example.com"], targets: [], https: expires != nil || problem != nil, enabled: enabled,
                             managed: false, canToggle: false,
                             cert: expires == nil && problem == nil ? nil : .init(expires: expires, issuer: "Let's Encrypt", problem: problem),
                             traffic: requests > 0 ? .init(requests: requests, window: 600, perMinute: Double(requests) / 10, bytes: 0, statuses: ["5xx": fiveXX]) : nil)
        }
        XCTAssertEqual(SiteHealth.of(site(), now: now), .ok)
        XCTAssertEqual(SiteHealth.of(site(enabled: false, expires: 0), now: now), .off, "an off site isn't a problem")
        XCTAssertEqual(SiteHealth.of(site(expires: now.timeIntervalSince1970 + 40 * 86_400), now: now), .ok)
        XCTAssertEqual(SiteHealth.of(site(expires: now.timeIntervalSince1970 + 5.5 * 86_400), now: now), .certSoon(days: 5))
        XCTAssertEqual(SiteHealth.of(site(expires: now.timeIntervalSince1970 - 60), now: now), .certExpired)
        XCTAssertEqual(SiteHealth.of(site(problem: "The certificate is for another name."), now: now), .certProblem("The certificate is for another name."))
        XCTAssertEqual(SiteHealth.of(site(requests: 100, fiveXX: 10), now: now), .errors(share: 0.1))
        XCTAssertEqual(SiteHealth.of(site(requests: 10, fiveXX: 5), now: now), .ok, "too few requests to judge")
        XCTAssertEqual(SiteHealth.of(site(requests: 100, fiveXX: 2), now: now), .ok)
        XCTAssertEqual(SiteHealth.certSoon(days: 1).text, "Certificate ends in 1 day")
    }

    func testDomainsAsTyped() {
        XCTAssertEqual(siteDomains("Example.com, www.example.com  https://shop.example.com/cart\nexample.com"),
                       ["example.com", "www.example.com", "shop.example.com"])
        XCTAssertEqual(siteDomains(" , "), [])
    }

    func testOldServerEditionSaysUpdate() {
        var s = ServerConfig(name: "old", host: "203.0.113.9"); s.edition = true; s.fingerprint = "AA"
        // Not paired on this Mac: the message says so (no network needed).
        if case .failure(let e) = ServerEdition.proxies(s) { XCTAssertTrue(e.message.contains("paired")) } else { XCTFail() }
    }

    /// APEX_SITES_TEST=host:port:code (Server Edition 1.1 with nginx and an
    /// app on 127.0.0.1:3000), APEX_RENDER_SERVERS=dir for pictures: pairs,
    /// reads the sites, adds one, switches it off and on, edits and removes
    /// it, and a site the server refuses.
    @MainActor func testLiveSites() async throws {
        guard let line = ProcessInfo.processInfo.environment["APEX_SITES_TEST"] else { throw XCTSkip("set APEX_SITES_TEST=host:port:code") }
        let p = line.split(separator: ":").map(String.init)
        let paired = try await ServerEdition.pair(host: p[0], port: Int(p[1])!, code: p[2], device: "Apex sites test").get()
        var s = ServerConfig(name: "web-01", host: p[0]); s.port = Int(p[1])!; s.edition = true; s.fingerprint = paired.fingerprint
        ServerEdition.saveToken(paired.token, for: s)
        let servers = ServerStore.shared, store = SitesStore.shared
        servers.add(s)
        defer { servers.remove(s) }
        await store.refresh(s, fresh: true)
        if let e = store.errors[s.id] { return XCTFail(e) }
        let before = try XCTUnwrap(store.reports[s.id])
        print("APEX-SITES", before.proxies.map(\.name), before.sites.map(\.name))
        XCTAssertTrue(before.proxies.contains { $0.kind == "nginx" && $0.editable })

        let spec = ProxyReport.Spec(domains: ["shop.test", "www.shop.test"], upstream: "127.0.0.1:3000", https: false, websockets: true)
        var r = await store.change(s, proxy: "nginx", verb: "add", site: nil, spec: spec)
        XCTAssertTrue(r.ok, r.message)
        var shop = try XCTUnwrap(store.reports[s.id]?.sites.first { $0.name == "shop.test" })
        XCTAssertTrue(shop.managed && shop.enabled)
        XCTAssertEqual(shop.spec?.upstream, "http://127.0.0.1:3000", "written in its one form")

        r = await store.change(s, proxy: "nginx", verb: "add", site: nil, spec: spec)
        XCTAssertFalse(r.ok, "the same domain twice"); print("APEX-SITES duplicate:", r.message)
        r = await store.change(s, proxy: "nginx", verb: "add", site: nil,
                               spec: .init(domains: ["bad.test"], upstream: "http://no-such-host-apex.invalid", https: false, websockets: false))
        XCTAssertFalse(r.ok); print("APEX-SITES refused:", r.message)
        XCTAssertNil(store.reports[s.id]?.sites.first { $0.name == "bad.test" }, "nothing left behind")

        r = await store.change(s, proxy: "nginx", verb: "disable", site: shop.id, spec: nil)
        XCTAssertTrue(r.ok, r.message)
        shop = try XCTUnwrap(store.reports[s.id]?.sites.first { $0.name == "shop.test" })
        XCTAssertFalse(shop.enabled)
        r = await store.change(s, proxy: "nginx", verb: "enable", site: shop.id, spec: nil)
        XCTAssertTrue(r.ok, r.message)
        shop = try XCTUnwrap(store.reports[s.id]?.sites.first { $0.name == "shop.test" })
        XCTAssertTrue(shop.enabled)

        if let dir = ProcessInfo.processInfo.environment["APEX_RENDER_SERVERS"] {
            AppModel.shared.target = .server(s.id)
            try await render(SitesView(serverID: s.id), dir + "/sites-server.png")
            AppModel.shared.target = .allServers
            try await render(SitesView(serverID: nil), dir + "/sites-all.png")
            AppModel.shared.target = .mac
        }

        var edited = spec; edited.upstream = "http://127.0.0.1:3001"
        r = await store.change(s, proxy: "nginx", verb: "update", site: shop.id, spec: edited)
        XCTAssertTrue(r.ok, r.message)
        shop = try XCTUnwrap(store.reports[s.id]?.sites.first { $0.name == "shop.test" })
        XCTAssertEqual(shop.targets, ["http://127.0.0.1:3001"])
        r = await store.change(s, proxy: "nginx", verb: "remove", site: shop.id, spec: nil)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertNil(store.reports[s.id]?.sites.first { $0.name == "shop.test" })
    }

    @MainActor private func render(_ view: some View, _ out: String, width: CGFloat = 1100, height: CGFloat = 700) async throws {
        let host = NSHostingView(rootView: view.frame(width: width, height: height).environment(AppModel.shared).environment(\.colorScheme, .dark)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = host; w.orderFrontRegardless(); defer { w.orderOut(nil) }
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(100)) }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}

final class KeychainTests: XCTestCase {
    /// Saving says whether it worked, and a missing item says "never saved".
    func testRoundTripAndStatus() {
        let account = "apex-test:" + UUID().uuidString
        defer { Keychain.remove(account: account) }
        XCTAssertEqual(Keychain.read(account: account).status, errSecItemNotFound)
        XCTAssertEqual(Keychain.set("one", account: account), errSecSuccess)
        XCTAssertEqual(Keychain.read(account: account).value, "one")
        XCTAssertEqual(Keychain.set("two", account: account), errSecSuccess, "saving again replaces it")
        XCTAssertEqual(Keychain.get(account: account), "two")
        Keychain.remove(account: account)
        XCTAssertNil(Keychain.get(account: account))
    }

    func testNotPairedSaysWhatToDo() {
        var s = ServerConfig(name: "lab-vm", host: "10.20.30.40"); s.edition = true
        guard case .failure(let e) = ServerEdition.proxies(s) else { return XCTFail() }
        XCTAssertTrue(e.message.contains("Pair Again"), e.message)
    }
}
