import XCTest
import SwiftUI
@testable import TaskManager

final class DockerManagementTests: XCTestCase {
    private func load(_ name: String) throws -> DockerReport {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try JSONDecoder().decode(DockerReport.self, from: Data(contentsOf: url))
    }

    /// The same daemon read by Server Edition (Go) and over SSH (Python): one shape.
    func testBothSidesDecodeTheSame() throws {
        for name in ["docker-edition", "docker-ssh"] {
            let r = try load(name)
            XCTAssertTrue(r.available, name)
            XCTAssertEqual(Set(r.managers.map(\.name)), ["Portainer", "Dockge"], name)
            let demo = try XCTUnwrap(r.stacks.first { $0.name == "demo" }, name)
            XCTAssertEqual(demo.manager, "dockge")
            XCTAssertEqual(demo.managerName, "Dockge")
            XCTAssertTrue(demo.editable && demo.canDeploy)
            XCTAssertEqual(r.managers.first { $0.name == "Portainer" }?.url, "https://:19443")
            XCTAssertTrue(r.loose.contains { $0.name == "apex-loose" })
            XCTAssertTrue(r.networks.contains { $0.name == "bridge" && $0.builtin })
        }
    }

    func testAnswers() {
        let ok = DockerAnswer.parse(Data(#"{"ok": true, "result": {"text": "hi"}}"#.utf8))
        XCTAssertTrue(ok.ok); XCTAssertEqual(ok.text(), "hi")
        let no = DockerAnswer.parse(Data(#"{"ok": false, "message": "There's no stack called x."}"#.utf8))
        XCTAssertFalse(no.ok); XCTAssertEqual(no.message, "There's no stack called x.")
        XCTAssertFalse(DockerAnswer.parse(Data("oops".utf8)).ok)
    }

    func testManagerLinks() {
        XCTAssertEqual(DockerView.managerURL(host: "203.0.113.10", "https://:9443")?.absoluteString, "https://203.0.113.10:9443")
        XCTAssertEqual(DockerView.managerURL(host: "fe80::1", "http://:5001")?.absoluteString, "http://[fe80::1]:5001")
        XCTAssertNil(DockerView.managerURL(host: "x", "nonsense"))
    }

    func testDockerTabIsForServers() {
        XCTAssertTrue(AppSection.tabs(.allServers).contains(.docker))
        XCTAssertFalse(AppSection.tabs(.allContainers).contains(.docker))
        XCTAssertFalse(AppSection.tabs(.mac).contains(.docker))
    }

    /// APEX_RENDER_SERVERS=dir: Docker Management drawn from the saved report.
    @MainActor func testRender() async throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_RENDER_SERVERS"] else { throw XCTSkip("set APEX_RENDER_SERVERS") }
        var s = ServerConfig(name: "web-01", host: "203.0.113.9"); s.edition = true; s.fingerprint = "AA"
        ServerStore.shared.add(s)
        defer { ServerStore.shared.remove(s) }
        DockerStore.shared.use(try load("docker-edition"), for: s.id)
        AppModel.shared.target = .server(s.id)
        defer { AppModel.shared.target = .mac }
        for pane in ["containers", "images", "networks"] {
            UserDefaults.standard.set(pane, forKey: "dockerPane")
            let view = DockerView(serverID: s.id).frame(width: 1100, height: 700).environment(AppModel.shared)
                .environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
            let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1100, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
            w.contentView = host; w.orderFrontRegardless()
            for _ in 0..<6 { try await Task.sleep(for: .milliseconds(100)) }
            DockerStore.shared.use(try load("docker-edition"), for: s.id)     // the page's own read fails (no server); keep the saved one
            for _ in 0..<4 { try await Task.sleep(for: .milliseconds(100)) }
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "/docker-\(pane).png"))
            w.orderOut(nil)
        }
        UserDefaults.standard.removeObject(forKey: "dockerPane")
    }
}
