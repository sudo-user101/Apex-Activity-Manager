import SwiftUI
import XCTest
import ProcessIdentityCore
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
    func testRequestBody() throws {
        var q = Assistant.Message(role: .user, text: "Why slow?")
        q.content = Assistant.userContent("Why slow?", readings: "CPU: 90% busy")
        let b = Assistant.body(model: "claude-opus-5-5", history: [q])
        XCTAssertEqual(b["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(b["fallbacks"] as? String, "default")
        XCTAssertNil(b["temperature"], "the 2026-10-21 API rejects sampling settings")
        XCTAssertEqual((b["thinking"] as? [String: String])?["type"], "adaptive")
        let msgs = try XCTUnwrap(b["messages"] as? [[String: Any]])
        XCTAssertEqual((msgs[0]["content"] as? [[String: Any]])?.count, 2, "readings, then the question")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: b))
        XCTAssertNil(Assistant.body(model: "claude-haiku-5-5", history: [q])["fallbacks"])
        XCTAssertEqual(Assistant.userContent("Hi", readings: nil).count, 1)
        let req = try Assistant.request(base: "https://api.anthropic.com/v1", key: "k", model: "claude-opus-5-5", history: [q])
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertNil(try Assistant.request(base: "https://api.anthropic.com/v1", key: "k", model: "claude-haiku-5-5", history: [q]).value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testStreamBuildsTheReply() {
        var r = Assistant.Reply()
        let lines = [
            #"event: message_start"#,
            #"data: {"type":"message_start","message":{"id":"m"}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Checking memory"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Safari is "}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"using 4 GB."}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        for l in lines { _ = r.feed(l) }
        XCTAssertEqual(r.text, "Safari is using 4 GB.")
        XCTAssertEqual(r.thinking, "Checking memory")
        XCTAssertEqual(r.stop, "end_turn")
        XCTAssertEqual(r.sendable.first?["signature"] as? String, "sig", "thinking goes back unchanged")
        XCTAssertNil(Assistant.stopNote(r.stop))
        var e = Assistant.Reply()
        _ = e.feed(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        XCTAssertEqual(e.error, "Anthropic is busy right now. Ask again in a moment.")
        XCTAssertNotNil(Assistant.stopNote("refusal"))
    }

    func testErrorsInPlainWords() {
        let body = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        XCTAssertTrue(Assistant.problem(status: 401, body: body).contains("API key"))
        XCTAssertTrue(Assistant.problem(status: 429, body: Data()).contains("Wait a moment"))
        XCTAssertEqual(Assistant.problem(status: 500, body: Data()), "Anthropic answered 500.")
    }

    func testAnswersRenderAsBlocks() {
        let b = RichText.blocks("**Short answer:** quit Safari.\n\n## Steps\n1. Open Apex\n2. Click **Free Up Memory**\n- tip one\n```\nsudo purge\n```")
        XCTAssertEqual(b, [.paragraph("**Short answer:** quit Safari."), .heading("Steps"), .numbered("1", "Open Apex"),
                           .numbered("2", "Click **Free Up Memory**"), .bullet("tip one"), .code("sudo purge")])
        XCTAssertEqual(RichText.blocks("```\nhalf"), [.code("half")], "a code block still streaming shows")
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

final class ApexAgentTests: XCTestCase {
    func testCommonQuestionsFindTheirTopic() {
        let cases: [(String, String)] = [
            ("Why is my Mac slow?", "slow"), ("my macbook is so laggy", "slow"), ("spinning beachball all the time", "slow"),
            ("My disk is full", "storage"), ("how do I free up space", "storage"), ("what is System Data", "storage"),
            ("battery draining fast", "battery-drain"), ("Is my battery healthy?", "battery-health"), ("how many cycles does my battery have", "battery-health"),
            ("Why is my Mac hot?", "heat"), ("fans are so loud", "heat"),
            ("My Wi-Fi keeps disconnecting", "wifi"), ("internet is slow", "wifi"),
            ("app is not responding", "frozen"), ("how to force quit", "frozen"),
            ("What is kernel_task?", "kernel"), ("WindowServer using cpu", "windowserver"),
            ("What's using my memory?", "memory"), ("too much swap", "memory"),
            ("apps open at startup", "login"), ("mac won't sleep", "sleep"), ("can't eject my usb drive", "eject"),
            ("airpods keep disconnecting", "bluetooth"), ("do I have a virus", "malware"), ("mds_stores high cpu", "background"),
            ("how do I back up", "backup"), ("what can Apex do", "apex"),
        ]
        for (q, topic) in cases { XCTAssertEqual(ApexAgent.topic(q), topic, q) }
    }

    func testUnknownSuggestsLumen() {
        let a = ApexAgent.answer("write me a poem about penguins", .init())
        XCTAssertTrue(a.unknown)
        XCTAssertTrue(a.text.contains("Lumen AI"))
        XCTAssertFalse(ApexAgent.answer("hello", .init()).unknown)
    }

    func testAnswersUseTheReadings() {
        var r = ApexAgent.Readings()
        r.busiest = [("Chrome", 180)]; r.pressure = "Elevated"; r.swap = 2_000_000_000
        r.diskFree = 5_000_000_000; r.diskTotal = 250_000_000_000
        let slow = ApexAgent.answer("why is my mac slow", r)
        XCTAssertTrue(slow.text.contains("Chrome"), slow.text)
        XCTAssertTrue(slow.text.contains("Elevated"))
        XCTAssertTrue(slow.text.contains("nearly full"))
        XCTAssertTrue(slow.actions.contains(.freeMemory))
        r.battery = (55, 76, 900, false, 31)
        XCTAssertTrue(ApexAgent.answer("battery health", r).text.contains("76%"))
        XCTAssertTrue(ApexAgent.answer("battery health", .init()).text.contains("no battery"))
    }
}

final class ApexAgentCommandTests: XCTestCase {
    private var r: ApexAgent.Readings {
        var r = ApexAgent.Readings()
        r.apps = [.init(pid: 10, name: "Google Chrome", startMicros: 1010), .init(pid: 11, name: "Safari", startMicros: 1011),
                  .init(pid: 12, name: "Microsoft Word", startMicros: 1012), .init(pid: 13, name: "Spotify", startMicros: 1013)]
        r.processes = [.init(pid: 50, name: "node", cpu: 88, startMicros: 1050), .init(pid: 51, name: "python3", cpu: 12, startMicros: 1051),
                       .init(pid: 52, name: "idle", cpu: 0, startMicros: 1052)]
        return r
    }

    private func quit(_ q: String) -> (pids: [Int32], force: Bool)? {
        for a in ApexAgent.answer(q, r).actions { if case .quitApps(let t, _, let f) = a { return (t.map(\.pid), f) } }
        return nil
    }

    func testQuitEverything() {
        for q in ["close all my apps", "Quit all apps", "please close everything", "quit everything", "close all running apps",
                  "close all programs", "kill all apps", "exit all apps", "shut down all my apps", "close all windows",
                  "Can you close all my apps please", "end all tasks", "close apps", "quit apps"] {
            XCTAssertEqual(quit(q)?.pids, [10, 11, 12, 13], q)
        }
        XCTAssertEqual(quit("force quit all apps")?.force, true)
        XCTAssertEqual(quit("close all apps")?.force, false)
    }

    func testQuitOneOrAllButSome() {
        XCTAssertEqual(quit("quit chrome")?.pids, [10])
        XCTAssertEqual(quit("close Google Chrome")?.pids, [10])
        XCTAssertEqual(quit("kill spotify and word")?.pids, [12, 13])
        XCTAssertEqual(quit("force quit word")?.force, true)
        XCTAssertEqual(quit("close all apps except safari")?.pids, [10, 12, 13])
        XCTAssertEqual(quit("quit everything but Safari and Spotify")?.pids, [10, 12])
        XCTAssertTrue(ApexAgent.answer("close photoshop", r).text.contains("can’t find an open app"))
    }

    func testQuitButtonsCarryIdentities() {
        guard case .quitApps(let t, _, _)? = ApexAgent.answer("quit chrome", r).actions.first else { return XCTFail("no quit action") }
        XCTAssertEqual(t, [ProcessIdentity(pid: 10, startMicros: 1010)])
    }

    func testQuestionsAreNotCommands() {
        XCTAssertNil(quit("how do I force quit an app"))
        XCTAssertNil(quit("why won't my mac shut down"))
        XCTAssertEqual(ApexAgent.topic("how do I force quit an app"), "frozen")
    }

    func testStopProcesses() {
        let a = ApexAgent.answer("stop process node", r)
        XCTAssertEqual(a.actions.first, .stopProcesses(targets: [ProcessIdentity(pid: 50, startMicros: 1050)], names: ["node"]),
                       "the exact process the answer named (PID + start time)")
        let b = ApexAgent.answer("stop processes", r)
        XCTAssertEqual(b.actions.prefix(2), [.stopProcesses(targets: [ProcessIdentity(pid: 50, startMicros: 1050)], names: ["node"]),
                                             .stopProcesses(targets: [ProcessIdentity(pid: 51, startMicros: 1051)], names: ["python3"])],
                       "offers the busiest, one button each")
        XCTAssertTrue(b.text.contains("never macOS"))
    }
}

final class LocalChatTests: XCTestCase {
    func testParsesModelList() {
        let json = #"{"data":[{"id":"qwen2.5-7b-instruct"},{"id":"text-embedding-nomic"},{"id":"llama-3.2-3b"}]}"#
        XCTAssertEqual(LocalChat.parseModels(Data(json.utf8)), ["llama-3.2-3b", "qwen2.5-7b-instruct"], "embedding models left out")
    }

    func testParsesStreamedPieces() {
        XCTAssertEqual(LocalChat.parseStreamLine(#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#), "Hel")
        XCTAssertNil(LocalChat.parseStreamLine("data: [DONE]"))
        XCTAssertNil(LocalChat.parseStreamLine(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
        XCTAssertNil(LocalChat.parseStreamLine(": keep-alive"))
    }

    func testFourModesInOrder() {
        XCTAssertEqual(Assistant.Mode.allCases.map(\.title), ["Apex Agent", "Local AI", "Lumen AI", "Cloud API"])
    }
}

final class CensusTests: XCTestCase {
    func testHelpersCountTowardsTheirAppAndHeavyAppsAreMarked() {
        var helper = proc(101, "Safari Web Content", kind: .app, bundle: "/Applications/Safari.app", cpu: 30, mem: 500)
        helper.netPerSec = 2_000
        var mail = proc(200, "Mail", kind: .app, bundle: "/Applications/Mail.app", app: true, cpu: 10, mem: 900)
        mail.diskWritePerSec = 50_000
        let procs = [proc(100, "Safari", kind: .app, bundle: "/Applications/Safari.app", app: true, cpu: 5, mem: 100), helper, mail,
                     proc(300, "mds", kind: .system, cpu: 0)]
        let c = Census.now(procs)
        XCTAssertEqual(c[.cpu]?.first?.name, "Safari")
        XCTAssertEqual(c[.cpu]?.first?.value, 35, "the app and its helper")
        XCTAssertEqual(c[.cpu]?.first?.pids.sorted(), [100, 101])
        XCTAssertEqual(c[.cpu]?.first?.share ?? 0, 35.0 / 45, accuracy: 0.001)
        XCTAssertEqual(c[.memory]?.map(\.name), ["Mail", "Safari"])
        XCTAssertEqual(c[.network]?.map(\.name), ["Safari"])
        XCTAssertEqual(c[.gpu], [], "nothing using it")
        XCTAssertFalse(c[.cpu]!.contains { $0.name == "mds" }, "zero isn't listed")
        XCTAssertEqual(Census.heavy(c)["/Applications/Safari.app"], 3)
        XCTAssertEqual(Census.heavy(c)["/Applications/Mail.app"], 3)
        var idle = proc(400, "idle", kind: .app, cpu: 0.2); idle.power = 0.01
        XCTAssertTrue(Census.now([idle])[.energy]!.isEmpty, "0.0 W is noise")
        XCTAssertTrue(Census.now([idle])[.cpu]!.isEmpty)
    }

    func testToday() {
        var u = AppUsageDay(name: "Xcode", bundlePath: "/Applications/Xcode.app"); u.cpuSeconds = 600; u.energyJoules = 7200
        let c = Census.today([("/Applications/Xcode.app", u)])
        XCTAssertEqual(c[.cpu]?.first?.value, 600)
        XCTAssertEqual(c[.energy]?.first?.value, 7200)
        XCTAssertNil(c[.gpu], "History has no GPU")
    }
}

final class MemoryCompositionTests: XCTestCase {
    func testPartsDontOverlapAndFreeIsTheRest() {
        var m = MemoryStats()
        m.total = 8_000; m.app = 3_000; m.wired = 1_500; m.compressed = 500; m.cached = 2_000
        m.used = m.app + m.wired + m.compressed
        let parts = MemoryComposition.parts(m)
        XCTAssertEqual(parts.map(\.0), [.apps, .system, .compressed, .cache])
        XCTAssertEqual(parts.prefix(3).reduce(0) { $0 + $1.1 }, m.used, "used = apps + operating system + compressed")
        XCTAssertEqual(MemoryComposition.free(m), 1_000)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.1 } + MemoryComposition.free(m), m.total, "together they're the whole RAM")
        m.cached = 4_000
        XCTAssertEqual(MemoryComposition.free(m), 0, "never below zero")
    }

    func testColoursMeanOneThing() {
        XCTAssertEqual(MemSeries.used.color, MemoryColor.used)
        XCTAssertEqual(Set(MemSeries.allCases.map { "\($0.color)" }).count, MemSeries.allCases.count, "every figure its own colour")
        XCTAssertNotEqual(PressureLevel.normal.color, MemoryColor.elevated, "yellow only when pressure rises")
        XCTAssertEqual(PressureLevel.warning.color, MemoryColor.elevated)
        XCTAssertEqual(PressureLevel.critical.color, MemoryColor.critical)
    }
}
