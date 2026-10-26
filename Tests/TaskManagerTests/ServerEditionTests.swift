import XCTest
import SwiftUI
@testable import TaskManager

final class ServerEditionTests: XCTestCase {
    func testActionsFromTheSSHCommands() {
        typealias A = ServerEdition.Action
        XCTAssertEqual(A.parse("kill 12"), A(kind: "process", verb: "end", target: "12", force: false))
        XCTAssertEqual(A.parse("kill -9 12 34"), A(kind: "process", verb: "end", target: "12 34", force: true))
        XCTAssertEqual(A.parse("sudo systemctl restart 'nginx'"), A(kind: "service", verb: "restart", target: "nginx", force: false))
        XCTAssertEqual(A.parse("docker stop 'web'"), A(kind: "container", verb: "stop", target: "web", force: false))
        XCTAssertNil(A.parse("rm -rf /"), "only the actions Apex offers")
        XCTAssertNil(A.parse("systemctl mask x"))
        XCTAssertNil(A.parse("kill abc"))
    }

    func testAddressesAndWords() {
        XCTAssertEqual(ServerEdition.url("203.0.113.9", 7443, "/api/hello")?.absoluteString, "https://203.0.113.9:7443/api/hello")
        XCTAssertEqual(ServerEdition.url("fe80::1", 7443, "/x")?.absoluteString, "https://[fe80::1]:7443/x")
        XCTAssertNil(ServerEdition.url(" ", 7443, "/x"))
        XCTAssertEqual(ServerEdition.fingerprint(Data("abc".utf8)).count, 95)
        XCTAssertTrue(ServerEdition.problem(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), pinned: "AA").message.contains("certificate"))
        XCTAssertTrue(ServerEdition.problem(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost), pinned: "AA").message.contains("port"))
    }

    func testOldSavedServersStaySSH() throws {
        let old = #"{"id":"6E2B8F57-0A0E-4E5C-9C79-3B1E3A2D7E10","name":"web","host":"h","user":"u","port":22,"container":""}"#
        let s = try JSONDecoder().decode(ServerConfig.self, from: Data(old.utf8))
        XCTAssertFalse(s.isEdition)
    }

    /// APEX_EDITION_TEST=host:port:code (a running Server Edition) [+ APEX_RENDER_SERVERS=dir]:
    /// pairs, reads, stops and starts a service, refuses another certificate, renders the pages.
    @MainActor func testLiveServer() async throws {
        guard let spec = ProcessInfo.processInfo.environment["APEX_EDITION_TEST"] else { throw XCTSkip("set APEX_EDITION_TEST=host:port:code") }
        let p = spec.split(separator: ":").map(String.init)
        let host = p[0], port = Int(p[1])!, code = p[2]
        let t0 = Date()
        let paired = try await ServerEdition.pair(host: host, port: port, code: code, device: "Apex test").get()
        print("APEX-EDITION paired in", String(format: "%.2f s", Date().timeIntervalSince(t0)), "with", paired.host, paired.fingerprint.prefix(11))
        var s = ServerConfig(name: "edition-test", host: host); s.port = port; s.edition = true; s.fingerprint = paired.fingerprint
        ServerEdition.saveToken(paired.token, for: s)
        defer { ServerEdition.forget(s) }

        // Wrong code: refused, in words.
        if case .success = await ServerEdition.pair(host: host, port: port, code: "AAAA-AAAA", device: "x") { XCTFail("wrong code accepted") }

        // Readings, the way the app reads them.
        let store = ServerStore.shared
        var times: [Double] = []
        for _ in 0..<3 { let t = Date(); await store.refresh(s); times.append(Date().timeIntervalSince(t)); try await Task.sleep(for: .seconds(2)) }
        print("APEX-EDITION reading seconds", times.map { String(format: "%.2f", $0) })
        if let e = store.errors[s.id] { return XCTFail(e.message) }
        let snap = try XCTUnwrap(store.snapshots[s.id])
        print("APEX-EDITION", snap.os, "·", snap.processes.count, "processes ·", snap.services?.count ?? 0, "services ·", snap.disks.count, "disks ·", snap.network.count, "interfaces")
        XCTAssertFalse(snap.processes.isEmpty)
        XCTAssertGreaterThan(snap.memory.total, 0)
        XCTAssertTrue(snap.processes.contains { $0.cpu > 0 || $0.memory > 0 })

        // A service: stop it, see it stopped, start it again.
        if let svc = snap.services?.first(where: { $0.name == "nginx" }) {
            XCTAssertTrue(svc.running)
            let stop = ServerEdition.action(s, ServerCommands.service(s, "stop", "nginx"))
            XCTAssertEqual(stop.status, 0, stop.stderr)
            try await Task.sleep(for: .seconds(6)); await store.refresh(s)
            XCTAssertEqual(store.snapshots[s.id]?.services?.first { $0.name == "nginx" }?.running, false, "stopped")
            let start = ServerEdition.action(s, ServerCommands.service(s, "start", "nginx"))
            XCTAssertEqual(start.status, 0, start.stderr)
            try await Task.sleep(for: .seconds(6)); await store.refresh(s)
            XCTAssertEqual(store.snapshots[s.id]?.services?.first { $0.name == "nginx" }?.running, true, "running again")
            let bad = ServerEdition.action(s, ServerCommands.service(s, "restart", "no-such-thing"))
            XCTAssertNotEqual(bad.status, 0); print("APEX-EDITION unknown service says:", bad.stderr)
        }

        // Someone else's certificate: refused.
        var forged = s; forged.fingerprint = String(repeating: "AB:", count: 31) + "AB"
        if case .success = ServerEdition.snapshot(forged) { XCTFail("another certificate was accepted") }
        if case .failure(let e) = ServerEdition.snapshot(forged) { print("APEX-EDITION forged certificate:", e.message) }

        if let dir = ProcessInfo.processInfo.environment["APEX_RENDER_SERVERS"] {
            store.add(s); defer { store.remove(s) }
            AppModel.shared.target = .server(s.id)
            for (v, n) in [(AnyView(RemotePerformanceView(server: s)), "perf"), (AnyView(RemoteProcessesView(server: s)), "processes"),
                           (AnyView(RemoteServicesView(server: s)), "services"), (AnyView(RemoteUsersView(server: s)), "users")] {
                let host = NSHostingView(rootView: v.frame(width: 1100, height: 700).environment(AppModel.shared).environment(\.colorScheme, .dark)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
                let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1100, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
                w.contentView = host; w.orderFrontRegardless()
                for _ in 0..<10 { try await Task.sleep(for: .milliseconds(100)) }
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "/edition-\(n).png"))
                w.orderOut(nil)
            }
            AppModel.shared.target = .mac
        }
    }
}
