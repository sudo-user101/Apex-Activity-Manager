import XCTest
@testable import TaskManager

final class ServerWebTrafficTests: XCTestCase {
    /// What the agent printed for the sample log (scripts/agent-web-log.py) on Linux.
    let json = """
    {"requests": 474, "window": 478, "perMinute": 59.5, "statuses": {"2xx": 415, "3xx": 0, "4xx": 29, "5xx": 30},
     "bytes": 4254728, "bots": 44,
     "topPaths": [{"path": "/shop", "count": 184}], "topClients": [{"ip": "203.0.113.7", "count": 46}],
     "errors": [{"what": "502 /checkout", "count": 30}],
     "scanners": [{"ip": "198.51.100.66", "requests": 29, "notFound": 29, "probes": 4}],
     "log": "/var/log/nginx/access.log", "readable": true}
    """

    func traffic(_ s: String) throws -> ServerSnapshot.WebTraffic {
        try JSONDecoder().decode(ServerSnapshot.WebTraffic.self, from: Data(s.utf8))
    }

    func testDecodesTheAgentsSummary() throws {
        let w = try traffic(json)
        XCTAssertEqual(w.requests, 474)
        XCTAssertEqual(w.serverErrors, 30)
        XCTAssertEqual(w.errorShare, 30.0 / 474, accuracy: 0.0001)
        XCTAssertEqual(w.topPaths?.first?.path, "/shop")
        XCTAssertEqual(w.topClients?.first?.ip, "203.0.113.7")
        XCTAssertEqual(w.scanners?.first?.probes, 4)
    }

    func testFailingPagesAndScannersBecomeInsights() throws {
        let list = ServerInsights.webInsights(try traffic(json))
        let failing = list.first { $0.title.contains("web requests are failing") }
        XCTAssertEqual(failing?.title, "6% of web requests are failing")
        XCTAssertEqual(failing?.level, .warning)
        XCTAssertTrue(failing!.detail.contains("502 /checkout"))
        XCTAssertEqual(list.first { $0.title.contains("probing") }?.title, "1 address is probing the site")
    }

    func testThresholds() throws {
        let quiet = try traffic(#"{"requests": 20, "window": 600, "statuses": {"5xx": 10}}"#)
        XCTAssertTrue(ServerInsights.webInsights(quiet).isEmpty, "too few requests to judge")
        let bad = try traffic(#"{"requests": 100, "window": 600, "statuses": {"5xx": 25}}"#)
        XCTAssertEqual(ServerInsights.webInsights(bad).first?.level, .critical)
        let fine = try traffic(#"{"requests": 100, "window": 600, "statuses": {"2xx": 98, "5xx": 2}}"#)
        XCTAssertTrue(ServerInsights.webInsights(fine).isEmpty)
    }

    func testUnreadableLogSaysHowToFixIt() throws {
        let w = try traffic(#"{"log": "/var/log/nginx/access.log", "readable": false, "requests": 0, "window": 600}"#)
        let i = ServerInsights.webInsights(w)
        XCTAssertEqual(i.map(\.title), ["Can’t read the web server’s log"])
        XCTAssertTrue(i[0].detail.contains("usermod -aG adm"))
        XCTAssertTrue(ServerInsights.webInsights(nil).isEmpty)
    }

    func testOlderAgentsWithoutWebTrafficStillDecode() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            if let s = try? JSONDecoder().decode(ServerSnapshot.self, from: Data(contentsOf: f)) { XCTAssertNil(s.webTraffic, f.lastPathComponent) }
        }
    }
}
