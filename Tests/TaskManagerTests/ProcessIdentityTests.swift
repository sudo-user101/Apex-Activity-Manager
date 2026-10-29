import XCTest
import ProcessIdentityCore
@testable import TaskManager

/// Process actions act on one particular process (PID + start time), never on
/// whatever has its PID later. Every test uses `sleep` processes it starts
/// itself; nothing else on the Mac is signalled.
final class ProcessIdentityTests: XCTestCase {
    private var started: [Process] = []

    override func tearDown() {
        for p in started where p.isRunning { p.terminate() }   // Foundation's own handle: only our children
        started = []
    }

    private func sleeper() throws -> (Process, ProcessIdentity) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()
        started.append(p)
        let id = try XCTUnwrap(ProcessIdentity.current(p.processIdentifier))
        return (p, id)
    }

    /// The same PID, a different start time: what a reused PID looks like.
    private func other(_ id: ProcessIdentity) -> ProcessIdentity {
        ProcessIdentity(pid: id.pid, startMicros: id.startMicros + 1)
    }

    private func waitForExit(_ p: Process) {
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(10_000) }
    }

    // MARK: Identity

    func testValidIdentity() throws {
        let (_, id) = try sleeper()
        XCTAssertEqual(id.check(), .same)
        XCTAssertGreaterThan(id.startMicros, 1_000_000_000_000_000)
        XCTAssertEqual(ProcessIdentity(argument: id.argument), id, "round trip for apex-signal")
    }

    func testExitedBeforeTheAction() throws {
        let (p, id) = try sleeper()
        p.terminate(); waitForExit(p)
        XCTAssertEqual(id.check(), .exited)
        XCTAssertEqual(ProcessSignal.send(SIGTERM, to: id), .exited, "nothing to do, nothing else touched")
    }

    func testPIDWithADifferentIdentityIsRefused() throws {
        let (p, id) = try sleeper()
        XCTAssertEqual(other(id).check(), .reused)
        XCTAssertEqual(ProcessSignal.send(SIGKILL, to: other(id)), .reused)
        usleep(100_000)
        XCTAssertTrue(p.isRunning, "the process now holding the PID wasn't signalled")
    }

    func testIncompleteIdentityIsRefused() throws {
        let (p, id) = try sleeper()
        let unknown = ProcessIdentity(pid: id.pid, startMicros: 0)
        XCTAssertEqual(unknown.check(), .unverifiable)
        XCTAssertEqual(ProcessSignal.send(SIGTERM, to: unknown), .unverifiable)
        XCTAssertTrue(p.isRunning)
        XCTAssertNil(ProcessIdentity(argument: "123"), "a bare PID isn't an identity")
        XCTAssertNil(ProcessIdentity(argument: "123@0"))
        XCTAssertNil(ProcessIdentity(argument: "0@5"))
    }

    func testNeverLaunchdOrApexItself() {
        let me = ProcessIdentity.current(getpid())!
        XCTAssertEqual(ProcessSignal.send(SIGTERM, to: me), .protected)
        XCTAssertEqual(ProcessSignal.send(SIGTERM, to: ProcessIdentity.current(1)!), .protected)
    }

    func testOtherUsersProcessNeedsAnAdministrator() throws {
        // launchd's children run as root; as a normal user the token can't be read.
        guard getuid() != 0 else { throw XCTSkip("running as root") }
        let root = try XCTUnwrap(ProcessSampler().sample(regularApps: [:], refreshRestricted: true, netRates: [:], gpuPercent: [:]).first { $0.uid == 0 && $0.pid > 1 && $0.startedMicros > 0 })
        XCTAssertEqual(ProcessSignal.send(0, to: root.identity), .notPermitted, "signal 0: nothing is delivered either way")
    }

    // MARK: Normal and force termination, several at once

    func testNormalAndForceTermination() throws {
        let (a, ia) = try sleeper(), (b, ib) = try sleeper()
        XCTAssertEqual(ProcessActions.end([ia], force: false).done, [ia])
        XCTAssertEqual(ProcessActions.end([ib], force: true).done, [ib])
        waitForExit(a); waitForExit(b)
        XCTAssertFalse(a.isRunning)
        XCTAssertEqual(b.terminationReason, .uncaughtSignal)
        XCTAssertEqual(b.terminationStatus, SIGKILL)
    }

    func testMixedValidAndStaleTargets() throws {
        let (a, ia) = try sleeper(), (b, ib) = try sleeper(), (c, ic) = try sleeper()
        c.terminate(); waitForExit(c)
        let r = ProcessActions.end([ia, other(ib), ic], force: false)
        XCTAssertEqual(r.done, [ia, ic], "a ended; c had already exited")
        XCTAssertEqual(r.refused, [.init(target: other(ib), result: .reused)])
        XCTAssertTrue(r.needsAdmin.isEmpty)
        waitForExit(a)
        XCTAssertFalse(a.isRunning)
        XCTAssertTrue(b.isRunning, "each target is checked on its own")
    }

    func testPauseAndResumeByIdentity() throws {
        let (p, id) = try sleeper()
        XCTAssertEqual(ProcessActions.pause([id], true).done, [id])
        XCTAssertEqual(ProcessActions.pause([other(id)], false).refused.first?.result, .reused)
        XCTAssertEqual(ProcessActions.pause([id], false).done, [id])
        XCTAssertTrue(p.isRunning)
    }

    // MARK: The administrator tool checks for itself

    func testAdministratorToolRejectsInvalidIdentities() throws {
        let tool = try XCTUnwrap(SignalTool.path(), "ApexSignal is built next to the tests")
        let (a, ia) = try sleeper(), (b, ib) = try sleeper()
        let run = Process(), out = Pipe()
        run.executableURL = URL(fileURLWithPath: tool)
        run.arguments = ["TERM", ia.argument, other(ib).argument, "\(ib.pid)", "1@\(ProcessIdentity.current(1)!.startMicros)"]
        run.standardOutput = out
        try run.run(); run.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let results = SignalTool.parse(text)
        XCTAssertEqual(results[ia], .sent)
        XCTAssertEqual(results[other(ib)], .reused)
        XCTAssertTrue(text.contains("\(ib.pid) invalid"), "a bare PID is never accepted")
        XCTAssertEqual(results[ProcessIdentity.current(1)!], .protected)
        XCTAssertEqual(run.terminationStatus, 1, "not everything was done")
        waitForExit(a)
        XCTAssertFalse(a.isRunning)
        XCTAssertTrue(b.isRunning)
    }

    func testParsingTheToolsAnswer() {
        let a = ProcessIdentity(pid: 10, startMicros: 5), b = ProcessIdentity(pid: 11, startMicros: 6)
        let r = SignalTool.parse("10@5 sent\n11@6 reused\n12 invalid\nnoise\n13@7 failed-35\n")
        XCTAssertEqual(r[a], .sent)
        XCTAssertEqual(r[b], .reused)
        XCTAssertEqual(r[ProcessIdentity(pid: 13, startMicros: 7)], .failed(35))
        XCTAssertEqual(r.count, 3)
    }

    // MARK: Samples carry the identity the kernel reports

    func testSampleIdentityMatchesTheKernel() throws {
        let (p, id) = try sleeper()
        let sample = try XCTUnwrap(ProcessSampler().sample(regularApps: [:], refreshRestricted: true, netRates: [:], gpuPercent: [:]).first { $0.pid == p.processIdentifier })
        XCTAssertEqual(sample.identity, id)
    }

    // MARK: What the user is told

    func testRefusalsAreExplained() {
        let a = ProcessIdentity(pid: 10, startMicros: 5), b = ProcessIdentity(pid: 11, startMicros: 6)
        var r = ProcessActions.Report()
        r.add(a, .reused); r.add(b, .unverifiable)
        let m = AppModel.message(for: r, names: [a: "Safari", b: "node"], verb: "end") ?? ""
        XCTAssertTrue(m.contains("“Safari” had already quit"), m)
        XCTAssertTrue(m.contains("couldn’t confirm “node”"), m)
        var ok = ProcessActions.Report(); ok.add(a, .sent); ok.add(b, .exited)
        XCTAssertNil(AppModel.message(for: ok, names: [:], verb: "end"))
    }

    // MARK: Notifications and Apex Agent refuse stale targets

    @MainActor func testAlertQuitRefusesStaleOrMissingTargets() throws {
        let model = AppModel.shared
        model.errorMessage = nil
        model.confirmEndFromAlert([], name: "Safari", alert: "High app CPU", raised: nil)
        XCTAssertTrue(model.errorMessage?.contains("earlier version") == true, "an old alert without identities ends nothing")

        let (p, id) = try sleeper()
        model.errorMessage = nil
        model.confirmEndFromAlert([other(id)], name: "sleep", alert: "High app CPU", raised: Date())
        XCTAssertTrue(model.errorMessage?.contains("already quit") == true)
        usleep(100_000)
        XCTAssertTrue(p.isRunning, "the process now holding the PID was left alone, without asking")
        model.errorMessage = nil
    }

    func testAgentActionsRefuseStaleTargets() throws {
        let (a, ia) = try sleeper(), (b, ib) = try sleeper()
        var r = ApexAgent.Readings()
        r.processes = [.init(pid: ia.pid, name: "sleep", cpu: 50, startMicros: ia.startMicros),
                       .init(pid: ib.pid, name: "sleep", cpu: 40, startMicros: ib.startMicros + 1)]   // stale
        guard case .stopProcesses(let targets, _)? = ApexAgent.answer("stop process sleep", r).actions.first else {
            return XCTFail("no stop action")
        }
        let report = ProcessActions.end(targets, force: false)
        XCTAssertEqual(report.done, [ia])
        XCTAssertEqual(report.refused.map(\.result), [.reused])
        waitForExit(a)
        XCTAssertFalse(a.isRunning)
        XCTAssertTrue(b.isRunning)
    }
}

/// Removing an app leaves nothing running: a test app's program is stopped
/// before the bundle goes to the Trash. Only a bundle made here is used.
final class SafeTrashTests: XCTestCase {
    func testProtectedAndScript() {
        XCTAssertTrue(SafeTrash.isProtected("/System/Applications/Calculator.app"))
        XCTAssertTrue(SafeTrash.isProtected("/usr/bin/true"))
        XCTAssertFalse(SafeTrash.isProtected(NSTemporaryDirectory() + "x.app"))
        let s = SafeTrash.adminScript(["/Applications/Some App.app"], trash: "/Users/u/.Trash", user: "u", stamp: "1")
        XCTAssertEqual(s, "/bin/mv -f '/Applications/Some App.app' '/Users/u/.Trash/Some App.app 1' && /usr/sbin/chown -R 'u' '/Users/u/.Trash/Some App.app 1'")
    }

    @MainActor func testARunningAppIsStoppedBeforeItGoesToTheTrash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apex-trash-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Apex Test Helper.app")
        let exe = bundle.appendingPathComponent("Contents/MacOS/helper")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Its own tiny program (a copy of a system tool misbehaves when moved around).
        let source = root.appendingPathComponent("helper.c")
        try "#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let cc = Process(); cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc"); cc.arguments = [source.path, "-o", exe.path]
        try cc.run(); cc.waitUntilExit()
        guard cc.terminationStatus == 0 else { throw XCTSkip("no C compiler here") }
        defer { try? FileManager.default.removeItem(at: root) }
        let p = Process(); p.executableURL = exe; p.arguments = ["60"]
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        XCTAssertEqual(SafeTrash.running(under: [bundle.path]).count, 1, "the helper runs from inside the app")

        let r = await SafeTrash.move([bundle.path])
        defer { for u in r.trashed { try? FileManager.default.removeItem(at: u) } }      // tidy the Trash
        for _ in 0..<50 where p.isRunning { try await Task.sleep(for: .milliseconds(100)) }     // never waits forever
        XCTAssertFalse(p.isRunning, "nothing of the app is left running")
        XCTAssertTrue(r.failed.isEmpty, r.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertEqual(r.trashed.count, 1)
        XCTAssertTrue(SafeTrash.running(under: [bundle.path]).isEmpty)
    }

    /// Like an app that won't quit when asked (the menu bar icon stayed): it's
    /// ended, forced if it must be, then the app is deleted for good.
    @MainActor func testAStubbornAppIsForcedToQuitAndDeletedForGood() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apex-delete-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Apex Stubborn.app")
        let exe = bundle.appendingPathComponent("Contents/MacOS/stubborn")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("stubborn.c")
        try "#include <signal.h>\n#include <unistd.h>\nint main(void) { signal(SIGTERM, SIG_IGN); sleep(60); return 0; }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let cc = Process(); cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc"); cc.arguments = [source.path, "-o", exe.path]
        try cc.run(); cc.waitUntilExit()
        guard cc.terminationStatus == 0 else { throw XCTSkip("no C compiler here") }
        defer { try? FileManager.default.removeItem(at: root) }
        let p = Process(); p.executableURL = exe
        try p.run()
        defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(SafeTrash.runningApps([bundle.path]).count, 1)

        let trashBefore = (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash")) ?? []
        let r = await SafeTrash.deleteApps([bundle.path])
        for _ in 0..<30 where p.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(p.isRunning, "a program that ignores SIGTERM is still stopped")
        XCTAssertTrue(r.failed.isEmpty, r.message)
        XCTAssertEqual(r.message, "Deleted “Apex Stubborn.app”.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        let trashAfter = (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash")) ?? []
        XCTAssertFalse(trashAfter.contains { $0.hasPrefix("Apex Stubborn") } && !trashBefore.contains { $0.hasPrefix("Apex Stubborn") },
                       "deleted, not moved to the Trash")
    }

    @MainActor func testOnlyAppsAreDeletedForGood() async {
        let r = await SafeTrash.deleteApps([NSHomeDirectory() + "/Documents"])
        XCTAssertEqual(r.failed.first?.why, "isn’t an app.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Documents"))
    }
}
