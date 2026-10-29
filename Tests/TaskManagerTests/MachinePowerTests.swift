import XCTest
@testable import TaskManager

final class MachinePowerTests: XCTestCase {
    func testWakeOnLANPacket() throws {
        let p = try XCTUnwrap(WakeOnLAN.packet("52:54:00:AB:cd:01"))
        XCTAssertEqual(p.count, 102)
        XCTAssertEqual(Array(p.prefix(6)), [UInt8](repeating: 0xFF, count: 6))
        XCTAssertEqual(Array(p[6..<12]), [0x52, 0x54, 0x00, 0xAB, 0xCD, 0x01])
        XCTAssertEqual(Array(p[96..<102]), [0x52, 0x54, 0x00, 0xAB, 0xCD, 0x01], "16 times")
        XCTAssertNotNil(WakeOnLAN.bytes("52-54-00-ab-cd-01"))
        XCTAssertNil(WakeOnLAN.packet("52:54:00:ab:cd"))
        XCTAssertNil(WakeOnLAN.packet("zz:54:00:ab:cd:01"))
    }

    func testPicksARealCard() {
        let net: [ServerSnapshot.Net] = [
            .init(name: "lo", inPerSec: 0, outPerSec: 0, mac: "00:00:00:00:00:00"),
            .init(name: "docker0", inPerSec: 0, outPerSec: 0, mac: nil),
            .init(name: "eth0", inPerSec: 0, outPerSec: 0, mac: "52:54:00:AB:CD:01")]
        XCTAssertEqual(MachinePower.pickMAC(net), "52:54:00:ab:cd:01")
        XCTAssertNil(MachinePower.pickMAC([]))
    }

    func testCommands() {
        let c = ServerConfig(name: "web", host: "203.0.113.9", container: "web")
        XCTAssertEqual(MachinePower.kind(c), .serverContainer)
        XCTAssertEqual(MachinePower.kind(ServerConfig(name: "s", host: "203.0.113.9")), .server)
        XCTAssertEqual(MachinePower.kind(ServerConfig(name: "l", host: "", container: "l")), .localContainer)
        XCTAssertEqual(MachinePower.containerCommand(c, resume: true, paused: false), "docker start 'web'")
        XCTAssertEqual(MachinePower.containerCommand(c, resume: true, paused: true), "docker unpause 'web'")
        XCTAssertEqual(MachinePower.containerCommand(c, resume: false, paused: false), "docker stop 'web'")
        // Server Edition understands the same commands.
        XCTAssertEqual(ServerEdition.Action.parse(MachinePower.shutDownCommand), .init(kind: "power", verb: "off", target: "", force: false))
        XCTAssertEqual(ServerEdition.Action.parse("docker unpause 'web'"), .init(kind: "container", verb: "unpause", target: "web", force: false))
    }

    /// APEX_DOCKER_TESTS=1: a throwaway container on this Mac, stopped and
    /// resumed the way the buttons do it, then removed.
    @MainActor func testLocalContainerStopAndResume() async throws {
        guard ProcessInfo.processInfo.environment["APEX_DOCKER_TESTS"] != nil, let docker = LocalDocker.path else { throw XCTSkip("set APEX_DOCKER_TESTS=1") }
        let name = "apex-power-test"
        _ = Shell.run(docker, ["rm", "-f", name])
        XCTAssertEqual(Shell.run(docker, ["run", "-d", "--name", name, "alpine:3.20", "sleep", "600"]).status, 0)
        defer { _ = Shell.run(docker, ["rm", "-f", name]) }
        let store = ServerStore.shared
        await store.refreshLocal()
        let s = try XCTUnwrap(store.localConfigs.first { $0.name == name })
        XCTAssertNil(MachinePower.run(s, resume: false))
        await store.refreshLocal()
        XCTAssertEqual(store.localContainer(s)?.running, false, "stopped")
        XCTAssertNotNil(store.config(s.id), "a stopped container stays in the menu")
        XCTAssertNil(MachinePower.run(s, resume: true))
        await store.refreshLocal()
        XCTAssertEqual(store.localContainer(s)?.running, true, "running again")
        _ = Shell.run(docker, ["pause", name]); await store.refreshLocal()
        XCTAssertNil(MachinePower.run(s, resume: true, paused: store.localContainer(s)?.state == "paused"))
        await store.refreshLocal()
        XCTAssertEqual(store.localContainer(s)?.running, true, "unpaused")
    }
}

final class ServerReachTests: XCTestCase {
    func testWhyNotAnswering() throws {
        let home = (try XCTUnwrap(ServerReach.ipv4("192.168.1.20")), try XCTUnwrap(ServerReach.ipv4("255.255.255.0")))
        XCTAssertEqual(ServerReach.reason(host: "10.20.30.40", name: "Lab", nets: [], vpn: false), "This Mac isn’t connected to a network.")
        XCTAssertTrue(ServerReach.reason(host: "10.20.30.40", name: "Lab", nets: [home], vpn: false).hasPrefix("Not on Lab’s network"),
                      "a local address on another network")
        XCTAssertTrue(ServerReach.reason(host: "10.20.30.40", name: "Lab", nets: [home], vpn: true).contains("isn’t answering"), "a VPN may reach it")
        XCTAssertTrue(ServerReach.reason(host: "192.168.1.50", name: "NAS", nets: [home], vpn: false).contains("isn’t answering"), "same network: it's off")
        XCTAssertTrue(ServerReach.reason(host: "203.0.113.9", name: "Cloud", nets: [home], vpn: false).contains("isn’t answering"), "a public address")
        XCTAssertTrue(ServerReach.reason(host: "web.example.com", name: "Web", nets: [home], vpn: false).contains("isn’t answering"))
        XCTAssertTrue(ServerReach.isPrivate(try XCTUnwrap(ServerReach.ipv4("172.20.1.1"))))
        XCTAssertFalse(ServerReach.isPrivate(try XCTUnwrap(ServerReach.ipv4("172.168.1.1"))), "172.168 isn't private")
        XCTAssertNil(ServerReach.ipv4("300.1.1.1"))
    }
}
