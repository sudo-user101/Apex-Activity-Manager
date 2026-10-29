import XCTest
@testable import TaskManager

final class FleetTotalsTests: XCTestCase {
    private func fixture() throws -> ServerSnapshot {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/agent-ubuntu.json")
        return try JSONDecoder().decode(ServerSnapshot.self, from: Data(contentsOf: url))
    }

    func testCPUIsWeightedByCores() throws {
        var small = try fixture(), big = try fixture()
        small.cpu.cores = 2; small.cpu.total = 100
        big.cpu.cores = 30; big.cpu.total = 0
        let t = FleetTotals.make([small, big], offline: 1)
        XCTAssertEqual(t.cores, 32)
        XCTAssertEqual(t.cpu, 6.25, accuracy: 0.001, "a busy 2-core box beside an idle 30-core one")
        XCTAssertEqual(t.online, 2)
        XCTAssertEqual(t.offline, 1)
    }

    func testMemoryNetworkAndDisksAddUpOncePerDevice() throws {
        var a = try fixture()
        a.memory = .init(total: 1000, available: 250)
        a.network = [.init(name: "eth0", inPerSec: 100, outPerSec: 10), .init(name: "eth1", inPerSec: 50, outPerSec: 5)]
        a.disks = [.init(device: "/dev/sda1", mount: "/", total: 100, used: 40, free: 60),
                   .init(device: "/dev/sda1", mount: "/var/lib/docker", total: 100, used: 40, free: 60),
                   .init(device: "/dev/sdb1", mount: "/data", total: 300, used: 60, free: 240)]
        let t = FleetTotals.make([a, a], offline: 0)
        XCTAssertEqual(t.memoryUsed, 1500)
        XCTAssertEqual(t.memoryPercent, 75, accuracy: 0.001)
        XCTAssertEqual(t.netIn, 300)
        XCTAssertEqual(t.netOut, 30)
        XCTAssertEqual(t.diskTotal, 800, "the bind mount isn't counted twice")
        XCTAssertEqual(t.diskPercent, 25, accuracy: 0.001)
    }

    func testNoServers() {
        let t = FleetTotals.make([], offline: 2)
        XCTAssertEqual(t.cpu, 0)
        XCTAssertEqual(t.memoryPercent, 0)
        XCTAssertEqual(t.offline, 2)
    }
}
