import XCTest
import SwiftUI
@testable import TaskManager

@MainActor final class TrafficHistoryTests: XCTestCase {
    private func conn(_ key: String, _ app: String, host: String, in bin: UInt64, out: UInt64, rate: Double = 0) -> NetConnection {
        var c = NetConnection(key: key, process: app, pid: 1, proto: "tcp4", local: "", remoteHost: host, remotePort: "443",
                              interface: "en0", state: "Established", bytesIn: bin, bytesOut: out)
        c.inPerSec = rate
        return c
    }

    func testCountsWhatWasSentWhileWatchingAndKeepsClosedConnections() {
        let h = TrafficHistory()
        let t0 = Date()
        h.record([conn("a", "Safari", host: "1.1.1.1", in: 1_000, out: 100)], at: t0)
        h.record([conn("a", "Safari", host: "1.1.1.1", in: 6_000, out: 300, rate: 1_000)], at: t0.addingTimeInterval(5))
        h.record([], at: t0.addingTimeInterval(10))           // the connection closed
        let p = h.peers(of: "Safari")
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].received, 5_000, "only what came in while Apex watched")
        XCTAssertEqual(p[0].sent, 200)
        XCTAssertFalse(p[0].open, "closed connections stay listed")
        XCTAssertEqual(h.points["Safari"]?.count, 3)
        XCTAssertEqual(h.points["Safari"]?[1].inRate, 1_000)
    }

    func testForgetsAfterTenMinutes() {
        let h = TrafficHistory()
        let t0 = Date()
        h.record([conn("a", "Mail", host: "2.2.2.2", in: 10, out: 10)], at: t0)
        h.record([conn("b", "Notes", host: "3.3.3.3", in: 10, out: 10)], at: t0.addingTimeInterval(601))
        XCTAssertTrue(h.peers(of: "Mail").isEmpty)
        XCTAssertNil(h.points["Mail"])
        XCTAssertEqual(h.peers(of: "Notes").count, 1)
    }
}

/// APEX_RENDER_TRAFFIC=out.png: the detail window for the busiest app right now.
final class TrafficSheetRenderTests: XCTestCase {
    @MainActor func testRender() async throws {
        guard let out = ProcessInfo.processInfo.environment["APEX_RENDER_TRAFFIC"] else { throw XCTSkip("set APEX_RENDER_TRAFFIC") }
        var prev: [String: (UInt64, UInt64)] = [:]
        var last: [NetConnection] = []
        for i in 0..<4 {
            var list = Connections.snapshot().filter { !$0.isLocal }
            for j in list.indices { if let p = prev[list[j].key] {
                list[j].inPerSec = Double(list[j].bytesIn &- p.0) / 5; list[j].outPerSec = Double(list[j].bytesOut &- p.1) / 5 } }
            prev = Dictionary(list.map { ($0.key, ($0.bytesIn, $0.bytesOut)) }, uniquingKeysWith: { a, _ in a })
            TrafficHistory.shared.record(list)
            last = list
            if i < 3 { try await Task.sleep(for: .seconds(5)) }
        }
        let app = Dictionary(grouping: last, by: \.process).max { $0.value.count < $1.value.count }!.key
        let ref = TrafficAppRef(pid: last.first { $0.process == app }!.pid, name: app, displayName: app, path: "")
        let host = NSHostingView(rootView: AppTrafficSheet(ref: ref, hostnames: [:]).environment(\.colorScheme, .dark)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 620)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 680, height: 620), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = host; w.orderFrontRegardless(); defer { w.orderOut(nil) }
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(100)) }
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}

final class TrafficServersTests: XCTestCase {
    func testOneRowPerServer() {
        let t = Date()
        func peer(_ id: String, _ host: String, _ r: UInt64, open: Bool) -> TrafficHistory.Peer {
            var p = TrafficHistory.Peer(id: id, app: "MediaServer", remoteHost: host, remotePort: "8443", proto: "tcp4", firstSeen: t, lastSeen: t)
            p.received = r; p.open = open; return p
        }
        let s = TrafficHistory.servers([peer("a", "139.162.175.123", 2_000, open: false), peer("b", "139.162.175.123", 500, open: true),
                                        peer("c", "10.0.0.21", 10, open: true)])
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].connections, 2); XCTAssertEqual(s[0].received, 2_500); XCTAssertTrue(s[0].open)
    }
}
