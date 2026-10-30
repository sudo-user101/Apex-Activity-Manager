import XCTest
import SwiftUI
@testable import TaskManager

/// APEX_MANAGE_TEST=host:port:code (Server Edition 1.2 with panel mode on),
/// APEX_SCREENSHOTS=dir for pictures: the terminal through Apex's own
/// emulator (a command, then htop full screen), files, updates, security.
final class ManageLiveTests: XCTestCase {
    @MainActor private func shoot(_ view: some View, _ out: String) async throws {
        let size = NSSize(width: 1120, height: 823)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(AppModel.shared)
            .environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host; w.orderFrontRegardless(); defer { w.orderOut(nil) }
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(100)) }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }

    @MainActor private func wait(_ what: String, _ seconds: Double = 15, _ ok: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !ok() { if Date() > end { return XCTFail("timed out: \(what)") }; try await Task.sleep(for: .milliseconds(200)) }
    }

    @MainActor func testManageLive() async throws {
        guard let line = ProcessInfo.processInfo.environment["APEX_MANAGE_TEST"] else { throw XCTSkip("set APEX_MANAGE_TEST=host:port:code") }
        let p = line.split(separator: ":").map(String.init)
        let paired = try await ServerEdition.pair(host: p[0], port: Int(p[1])!, code: p[2], device: "Apex manage test").get()
        var s = ServerConfig(name: "web-01", host: p[0]); s.port = Int(p[1])!; s.edition = true; s.fingerprint = paired.fingerprint; s.keyPin = paired.key
        ServerEdition.saveToken(paired.token, for: s)
        ServerStore.shared.add(s)
        defer { ServerStore.shared.remove(s) }

        let st = await ServerPanel.sendAsync(s, ["op": "status"])
        XCTAssertEqual(st.decode(ServerPanel.Status.self)?.panel, true, st.message)

        // Files
        var a = await ServerPanel.sendAsync(s, ["op": "files.write", "path": "/root/apex-note.txt", "data": Data("from the Mac\n".utf8).base64EncodedString()])
        XCTAssertTrue(a.ok, a.message)
        a = await ServerPanel.sendAsync(s, ["op": "files.read", "path": "/root/apex-note.txt"])
        XCTAssertEqual(Data(base64Encoded: a.object()["data"] as? String ?? "").map { String(decoding: $0, as: UTF8.self) }, "from the Mac\n")

        // Terminal: a command, then a full-screen program, through Apex's emulator.
        let term = ServerTerminal(server: s, cols: 120, rows: 34)
        var raw = Data()
        term.record = { raw.append($0) }
        term.start()
        try await wait("connected") { term.connected }
        try await wait("prompt") { term.screen.text.contains("#") }
        term.send(Data("echo hi-$((40+2)) && cat /root/apex-note.txt\r".utf8))
        try await wait("output") { term.screen.text.contains("hi-42") && term.screen.text.contains("from the Mac") }
        let dir = ProcessInfo.processInfo.environment["APEX_SCREENSHOTS"]
        if let dir { try await shoot(TerminalPane(session: term), dir + "/manage-terminal.png") }
        term.send(Data("htop\r".utf8))
        try await wait("htop full screen") { term.screen.altScreen && term.screen.text.contains("Tasks:") }
        try await Task.sleep(for: .seconds(3))
        if let dir {
            try raw.write(to: URL(fileURLWithPath: dir + "/htop.raw"))
            try term.screen.text.write(toFile: dir + "/htop.txt", atomically: true, encoding: .utf8)
            try await shoot(TerminalPane(session: term), dir + "/manage-htop.png")
        }
        term.send(Data("q".utf8))
        try await wait("back to the shell") { !term.screen.altScreen }
        XCTAssertTrue(term.screen.text.contains("hi-42"), "the shell's screen comes back after htop")
        term.stop()

        // Updates and security read
        a = await ServerPanel.sendAsync(s, ["op": "pkg.list"])
        XCTAssertTrue(a.ok, a.message)
        a = await ServerPanel.sendAsync(s, ["op": "fw.status"])
        XCTAssertEqual(a.object()["tool"] as? String, "ufw")

        if let dir {
            AppModel.shared.target = .server(s.id)
            defer { AppModel.shared.target = .mac }
            for pane in ["files", "updates", "security"] {
                UserDefaults.standard.set(pane, forKey: "managePane")
                UserDefaults.standard.set("/root", forKey: "manageFilesPath")
                try await shoot(ManageView(server: s), dir + "/manage-\(pane).png")
            }
            UserDefaults.standard.removeObject(forKey: "managePane"); UserDefaults.standard.removeObject(forKey: "manageFilesPath")
        }
    }
}
