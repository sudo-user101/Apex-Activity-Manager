import XCTest
@testable import TaskManager

final class RecorderTests: XCTestCase {
    private func proc(_ pid: pid_t, _ name: String, cpu: Double = 0, memory: UInt64 = 1_000_000, net: Double = 0) -> ProcessInfoSample {
        ProcessInfoSample(pid: pid, ppid: 1, uid: 501, user: NSUserName(), name: name, path: "/x/\(name)", bundlePath: "",
                          kind: .background, state: .sleeping, nice: 0, started: nil, threads: 4, cpu: cpu, cpuUser: cpu,
                          cpuSystem: 0, memory: memory, diskReadPerSec: 0, diskWritePerSec: 0, netPerSec: net, gpu: 0,
                          restricted: false, isRegularApp: false, appName: nil, background: false)
    }

    private func snapshot() -> Snapshot {
        var s = Snapshot()
        s.system.cpu.total = 37.456; s.system.cpu.perCore = [50, 20]
        s.system.memory.used = 8_000_000_000; s.system.memory.pressureLevel = .warning
        s.system.network.inPerSec = 1234.5
        var ps = [proc(1, "busy", cpu: 80), proc(2, "chatty", net: 5_000)]
        for i in 0..<30 { ps.append(proc(pid_t(100 + i), "idle\(i)", memory: UInt64(i) * 10_000_000)) }
        s.processes = ps
        return s
    }

    func testSampleLineIsValidJSONWithTheRightProcesses() throws {
        let line = Recorder.sampleLine(snapshot(), allProcesses: false, battery: nil)
        let data = try JSONSerialization.data(withJSONObject: line)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(o["type"] as? String, "sample")
        let names = (o["processes"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains("busy") && names.contains("chatty"), "active processes are kept")
        XCTAssertTrue(names.contains("idle29"), "the biggest by memory are kept")
        XCTAssertFalse(names.contains("idle0"), "idle small processes are left out")
        XCTAssertEqual(names.count, 17)
        let sys = try XCTUnwrap(o["system"] as? [String: Any])
        XCTAssertEqual((sys["cpu"] as? [String: Any])?["total"] as? Double, 37.46)
        XCTAssertEqual((sys["memory"] as? [String: Any])?["pressure"] as? String, "Elevated")
        let all = Recorder.sampleLine(snapshot(), allProcesses: true, battery: nil)
        XCTAssertEqual((all["processes"] as? [[String: Any]])?.count, 32, "the once-a-minute line lists everything")
    }

    func testHeaderAndSummary() throws {
        let h = Recorder.header(snapshot(), started: Date())
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: h))
        XCTAssertNotNil((h["format"] as? [String: Any])?["cpu"], "the file explains its own fields")
        var sum = Recorder.Summary()
        sum.add(snapshot())
        var hot = snapshot(); hot.system.cpu.total = 90; hot.date = Date().addingTimeInterval(2)
        sum.add(hot)
        let line = sum.line(started: Date(), ended: Date().addingTimeInterval(4), samples: 2)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: line))
        XCTAssertEqual((line["cpu"] as? [String: Any])?["peak"] as? Double, 90)
        XCTAssertEqual((line["memory"] as? [String: Any])?["worstPressure"] as? String, "Elevated")
        XCTAssertEqual((line["busiestProcesses"] as? [[String: Any]])?.first?["name"] as? String, "busy")
    }

    func testClock() {
        XCTAssertEqual(RecordButton.clock(75), "1:15")
        XCTAssertEqual(RecordButton.clock(3725), "1:02:05")
    }
}

extension RecorderTests {
    func testScopedLinesKeepOnlyTheirResource() {
        var s = Snapshot()
        s.system.cpu.total = 40; s.system.memory.used = 5
        var busy = ProcessInfoSample(pid: 1, ppid: 1, uid: 501, user: NSUserName(), name: "busy", path: "", bundlePath: "", kind: .app,
                                     state: .running, nice: 0, started: nil, threads: 3, cpu: 50, cpuUser: 50, cpuSystem: 0,
                                     memory: 9_000, diskReadPerSec: 0, diskWritePerSec: 0, netPerSec: 1_000, gpu: 0,
                                     restricted: false, isRegularApp: true, appName: nil, background: false)
        let idle = { var p = busy; p.cpu = 0; p.netPerSec = 0; p.memory = 1; return p }()
        busy.power = 0.4
        s.processes = [busy, idle]
        let cpu = Recorder.sampleLine(s, allProcesses: false, battery: nil, scope: .cpu)
        XCTAssertEqual(Set((cpu["system"] as? [String: Any])?.keys ?? [:].keys), ["cpu", "thermal", "processCount", "threadCount"])
        let procs = cpu["processes"] as? [[String: Any]] ?? []
        XCTAssertEqual(procs.count, 1, "only processes using CPU")
        XCTAssertNil(procs[0]["memory"], "no memory figures in a CPU recording"); XCTAssertNil(procs[0]["netPerSec"])
        XCTAssertEqual(procs[0]["cpu"] as? Double, 50)
        let net = Recorder.sampleLine(s, allProcesses: false, battery: nil, scope: .network)
        XCTAssertEqual(Set((net["system"] as? [String: Any])?.keys ?? [:].keys), ["network"])
        XCTAssertEqual((net["processes"] as? [[String: Any]])?.first?["netPerSec"] as? Double, 1_000)
        XCTAssertEqual(RecordScope.page(.battery), .energy); XCTAssertNil(RecordScope.page(.display))
    }
}
