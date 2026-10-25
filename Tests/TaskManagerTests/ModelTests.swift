import SwiftUI
import XCTest
@testable import TaskManager

private func proc(_ pid: pid_t, _ name: String, kind: ProcessKind, bundle: String = "", app: Bool = false,
                  cpu: Double = 0, mem: UInt64 = 0, uid: uid_t = 501, state: ProcessState = .running) -> ProcessInfoSample {
    ProcessInfoSample(pid: pid, ppid: 1, uid: uid, user: "u", name: name, path: bundle.isEmpty ? "/usr/bin/\(name)" : bundle + "/Contents/MacOS/x",
                      bundlePath: bundle, kind: kind, state: state, nice: 0, started: nil, threads: 1, cpu: cpu,
                      cpuUser: cpu, cpuSystem: 0, memory: mem, diskReadPerSec: 0, diskWritePerSec: 0, netPerSec: 0, gpu: 0,
                      restricted: false, isRegularApp: app, appName: app ? name : nil, background: false)
}

final class ProcessTreeTests: XCTestCase {
    let procs = [
        proc(100, "Safari", kind: .app, bundle: "/Applications/Safari.app", app: true, cpu: 5, mem: 100),
        proc(101, "Safari Web Content", kind: .background, bundle: "/Applications/Safari.app", cpu: 20, mem: 300),
        proc(200, "node", kind: .background, cpu: 1),
        proc(201, "node", kind: .background, cpu: 2),
        proc(300, "kernel_task", kind: .system, cpu: 9, uid: 0),
        proc(400, "sleep", kind: .background, uid: 501, state: .stopped),
    ]

    func testAppAbsorbsHelpers() throws {
        let rows = ProcessTree.build(procs, search: "", cpuScale: 1, sortKey: "cpu", ascending: false)
        let apps = try XCTUnwrap(rows.first { $0.id == "s:0" })
        let safari = try XCTUnwrap(apps.children?.first)
        XCTAssertEqual(safari.name, "Safari")
        XCTAssertEqual(safari.cpu, 25, accuracy: 1e-9, "app row sums the app and its helpers")
        XCTAssertEqual(safari.memory, 400)
        XCTAssertEqual(safari.children?.map(\.pid), [101])
        let background = try XCTUnwrap(rows.first { $0.id == "s:1" })
        XCTAssertFalse(background.children!.contains { $0.name == "Safari Web Content" }, "helpers aren't listed twice")
    }

    func testSameNameGroupAndSort() throws {
        let rows = ProcessTree.build(procs, search: "", cpuScale: 1, sortKey: "cpu", ascending: false)
        let background = try XCTUnwrap(rows.first { $0.id == "s:1" })
        let node = try XCTUnwrap(background.children?.first { $0.name == "node" })
        XCTAssertEqual(node.count, 2)
        XCTAssertEqual(node.children?.map(\.pid), [201, 200], "children sorted by CPU, highest first")
        XCTAssertEqual(Set(ProcessTree.pids(for: [node.id], in: procs)), [200, 201])
    }

    func testSearchAndFilter() {
        let found = ProcessTree.build(procs, search: "web", cpuScale: 1, sortKey: "cpu", ascending: false)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].children?.first?.children?.map(\.pid), [101])

        let paused = ProcessTree.build(procs, search: "", cpuScale: 1, sortKey: "cpu", ascending: false, filter: .paused)
        XCTAssertEqual(paused.flatMap { $0.children ?? [] }.map(\.pid), [400])
        XCTAssertTrue(ProcessFilter.otherUsers.includes(procs[4], me: 501))
        XCTAssertFalse(ProcessFilter.mine.includes(procs[4], me: 501))
    }

    func testCPUScale() throws {
        let rows = ProcessTree.build(procs, search: "", cpuScale: 0.125, sortKey: "cpu", ascending: false)
        let sys = try XCTUnwrap(rows.first { $0.id == "s:2" })
        XCTAssertEqual(sys.cpu, 9 * 0.125, accuracy: 1e-9)
    }

    func testAppKey() {
        XCTAssertEqual(procs[1].appKey, "/Applications/Safari.app")
        XCTAssertEqual(procs[2].appKey, "n:node")
    }
}

final class HistoryTests: XCTestCase {
    func testKeepsOnlyTenMinutesAndStaysAligned() {
        var h = History()
        var s = SystemSnapshot()
        s.cpu.perCore = [10, 20]
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<900 {                       // 15 minutes at 1 s
            s.cpu.total = Double(i)
            h.push(s, at: start.addingTimeInterval(Double(i)))
        }
        let span = h.times.last!.timeIntervalSince(h.times.first!)
        XCTAssertLessThanOrEqual(span, History.window + 1)
        XCTAssertGreaterThanOrEqual(span, History.window - 1)
        XCTAssertEqual(h.cpu.count, h.times.count)
        XCTAssertEqual(h.pressureLevels.count, h.times.count)
        XCTAssertEqual(h.perCore[1].count, h.times.count)
        XCTAssertEqual(h.cpu.last, 899)
    }

    func testGraphXsUsesTime() {
        let end = Date()
        let t = GraphTimeline(times: [end.addingTimeInterval(-60), end.addingTimeInterval(-30), end], window: 60, end: end)
        let xs = graphXs(3, width: 100, timeline: t)
        XCTAssertEqual(xs[0], 0, accuracy: 0.001)
        XCTAssertEqual(xs[1], 50, accuracy: 0.001)
        XCTAssertEqual(xs[2], 100, accuracy: 0.001)
        XCTAssertEqual(visibleValues([1, 2, 3], GraphTimeline(times: t.times, window: 31, end: end)), [2, 3])
    }
}

final class LevelTests: XCTestCase {
    func testPressureLevel() {
        XCTAssertEqual(PressureLevel(rawValue: 1), .normal)
        XCTAssertEqual(PressureLevel(rawValue: 2), .warning)
        XCTAssertEqual(PressureLevel(rawValue: 4), .critical)
        XCTAssertEqual(ProcessState(bsdStatus: 4), .stopped)
    }

    func testPowerLevel() {
        let l = PowerLevel.limits(laptop: true)
        XCTAssertEqual(PowerLevel.label(5, l), "Normal")
        XCTAssertEqual(PowerLevel.label(12, l), "Moderate")
        XCTAssertEqual(PowerLevel.label(25, l), "High")
    }

    func testFormatting() {
        XCTAssertEqual(Fmt.rate(0), "0 KB/s")
        XCTAssertEqual(Fmt.rate(1500), "1.5 KB/s")
        XCTAssertEqual(Fmt.diskBytes(0), "0 KB")
        XCTAssertEqual(Fmt.duration(3725), "1h 2m")
        XCTAssertEqual(Fmt.duration(7200), "2h")
        XCTAssertEqual(Fmt.duration(45), "45s")
        XCTAssertEqual(Fmt.duration(125), "2m 5s")
        XCTAssertEqual(Fmt.duration(2700), "45m")
        XCTAssertEqual(Fmt.duration(3 * 86400 + 4 * 3600 + 10), "3d 4h")
        XCTAssertEqual(Fmt.minutes(125), "2h 5m")
    }
}

final class PowerTelemetryTests: XCTestCase {
    func testParsesSignedBatteryFlow() {
        // Real values from this Mac on battery: BatteryPower is −5.498 W stored unsigned.
        let t: [String: Any] = ["SystemLoad": NSNumber(value: 5498), "SystemPowerIn": NSNumber(value: 0),
                                "BatteryPower": NSNumber(value: UInt64(18446744073709546118))]
        let p = PowerTelemetry.parse(t)
        XCTAssertEqual(p.load ?? 0, 5.498, accuracy: 0.001)
        XCTAssertEqual(p.charger ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(p.battery ?? 0, -5.498, accuracy: 0.001, "draining")
        XCTAssertNil(PowerTelemetry.parse([:]).load)
    }
}

final class AssistantTests: XCTestCase {
    func testParsesModelList() {
        let json = #"{"data":[{"id":"qwen2.5-7b-instruct"},{"id":"text-embedding-nomic"},{"id":"llama-3.2-3b"}]}"#
        XCTAssertEqual(Assistant.parseModels(Data(json.utf8)), ["llama-3.2-3b", "qwen2.5-7b-instruct"], "embedding models left out")
    }

    func testParsesStreamedPieces() {
        XCTAssertEqual(Assistant.parseStreamLine(#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#), "Hel")
        XCTAssertNil(Assistant.parseStreamLine("data: [DONE]"))
        XCTAssertNil(Assistant.parseStreamLine(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
        XCTAssertNil(Assistant.parseStreamLine(": keep-alive"))
    }

    func testContextHasTheLiveReadings() {
        var s = Snapshot()
        s.system.memory.total = 8 << 30; s.system.memory.used = 6 << 30
        s.system.disk.capacity = 250_000_000_000; s.system.disk.available = 20_000_000_000
        let text = AssistantContext.build(s, events: [], battery: nil)
        XCTAssertTrue(text.contains("Memory: 6"), text)
        XCTAssertTrue(text.contains("Startup disk: 20"), text)
        XCTAssertFalse(text.contains("Battery"), "desktop: no battery line")
    }
}
