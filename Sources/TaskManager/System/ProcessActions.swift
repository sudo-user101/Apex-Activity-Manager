import AppKit
import Darwin
import ProcessIdentityCore
import Security

/// Process control. Every call reports failure instead of failing silently,
/// and permission failures can
/// be retried with an administrator prompt.
enum ProcessActions {
    enum Outcome: Equatable {
        case ok
        case needsAdmin          // EPERM: process belongs to another user / root
        case failed(String)
    }

    /// What happened to each process an action was meant for.
    struct Report: Equatable {
        /// Ended / paused / resumed, or already gone.
        var done: [ProcessIdentity] = []
        /// Still running, but only an administrator can act on them.
        var needsAdmin: [ProcessIdentity] = []
        /// Not touched, for safety: the PID belongs to another process now,
        /// the identity couldn't be checked, or Apex never acts on it.
        var refused: [Refusal] = []
        var failures: [String] = []
        /// The administrator prompt was cancelled.
        var cancelled = false

        struct Refusal: Equatable { let target: ProcessIdentity; let result: SignalResult }

        mutating func add(_ target: ProcessIdentity, _ result: SignalResult) {
            switch result {
            case .sent, .exited: done.append(target)
            case .notPermitted: needsAdmin.append(target)
            case .reused, .unverifiable, .protected: refused.append(Refusal(target: target, result: result))
            case .failed(let e): failures.append(String(cString: strerror(e)))
            }
        }
    }

    /// Quits regular apps politely (like Dock > Quit); signals everything
    /// else. Every target is checked against its identity right before it's
    /// acted on; one that has exited, or whose PID now belongs to another
    /// process, is left alone (never a PID-only kill).
    static func end(_ targets: [ProcessIdentity], force: Bool) -> Report {
        var report = Report()
        for t in targets {
            if t.pid <= 1 || t.pid == getpid() { report.add(t, .protected); continue }
            if !force, let app = NSRunningApplication(processIdentifier: t.pid), app.activationPolicy == .regular {
                // The instance belongs to whichever process had the PID when it
                // was made; checking the identity after making it ties it to
                // the intended one (a process can't exit and come back).
                switch t.check() {
                case .same: if app.terminate() { report.done.append(t); continue }
                case .exited: report.done.append(t); continue
                case .reused: report.add(t, .reused); continue
                case .unverifiable: report.add(t, .unverifiable); continue
                }
            }
            report.add(t, ProcessSignal.send(force ? SIGKILL : SIGTERM, to: t))
        }
        return report
    }

    /// Freezes (SIGSTOP) or resumes (SIGCONT) processes, each checked against
    /// its identity. A paused app keeps its windows and data but uses no CPU;
    /// macOS can compress its memory.
    static func pause(_ targets: [ProcessIdentity], _ on: Bool) -> Report {
        var report = Report()
        for t in targets { report.add(t, ProcessSignal.send(on ? SIGSTOP : SIGCONT, to: t)) }
        return report
    }

    /// The same as administrator: `apex-signal` runs as root through the
    /// password prompt and checks every identity itself (it doesn't trust
    /// this app). `signal`: TERM, KILL, STOP or CONT.
    static func signalAsAdmin(_ targets: [ProcessIdentity], _ signal: String) -> Report {
        var report = Report()
        guard !targets.isEmpty else { return report }
        guard let tool = SignalTool.path() else {
            report.failures.append(SignalTool.unavailable)
            return report
        }
        let r = Shell.runAsAdmin(Shell.quote(tool) + " " + signal + " " + targets.map(\.argument).joined(separator: " "))
        if Shell.isUserCancelled(r) { report.cancelled = true; return report }
        let results = SignalTool.parse(r.stdout)
        for t in targets {
            switch results[t] {
            // Root can't signal it either: macOS protects it.
            case .notPermitted?: report.failures.append("macOS doesn’t allow it, even for an administrator.")
            case let result?: report.add(t, result)
            case nil: report.add(t, .unverifiable)    // no answer for it: nothing is assumed
            }
        }
        if results.isEmpty, r.status != 0 {
            report.failures.append(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return report
    }

    /// `pids` plus every process they started, recursively.
    static func withDescendants(_ pids: [pid_t], in procs: [ProcessInfoSample]) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for p in procs { children[p.ppid, default: []].append(p.pid) }
        var out = Set<pid_t>(), stack = pids
        while let p = stack.popLast() {
            guard out.insert(p).inserted else { continue }
            stack += (children[p] ?? []).filter { $0 > 1 }
        }
        return Array(out)
    }


    static func setNice(pids: [pid_t], _ value: Int32) -> Outcome {
        var needsAdmin = false
        for pid in pids where setpriority(PRIO_PROCESS, id_t(pid), value) != 0 {
            if errno == EPERM || errno == EACCES { needsAdmin = true }
        }
        return needsAdmin ? .needsAdmin : .ok
    }

    static func setNiceAsAdmin(pids: [pid_t], _ value: Int32) -> Outcome {
        let list = pids.map { "-p \($0)" }.joined(separator: " ")
        let r = Shell.runAsAdmin("/usr/bin/renice \(value) \(list)")
        if r.status == 0 || Shell.isUserCancelled(r) { return .ok }
        return .failed(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "Optimize": puts the process in Darwin background mode — the policy
    /// macOS itself uses for Time Machine and Spotlight indexing. It keeps
    /// running, but is scheduled on efficiency cores at the lowest priority
    /// with throttled disk I/O, and its memory becomes the first candidate
    /// for compression / swap under pressure. Regular apps are also hidden so
    /// App Nap and the app's own "not visible" savings kick in (browsers stop
    /// rendering hidden tabs and release GPU / graphics memory).
    /// Fully reversible; no admin rights needed for your own processes.
    static func optimize(pids: [pid_t], _ on: Bool) -> Outcome {
        var needsAdmin = false
        for pid in pids {
            if setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0) != 0,
               errno == EPERM || errno == EACCES {
                needsAdmin = true
            }
        }
        if on {
            var hidden = hiddenByOptimize
            for pid in pids {
                if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular, !app.isHidden {
                    app.hide()
                    hidden.insert(pid)
                }
            }
            hiddenByOptimize = hidden
        } else {
            // Bring back exactly the apps Optimize hid, windows where they were.
            var hidden = hiddenByOptimize
            for pid in pids where hidden.contains(pid) {
                NSRunningApplication(processIdentifier: pid)?.unhide()
                hidden.remove(pid)
            }
            hiddenByOptimize = hidden
        }
        return needsAdmin ? .needsAdmin : .ok
    }

    /// Apps Optimize hid (apps the user had hidden already aren't included), kept across relaunches.
    static var hiddenByOptimize: Set<pid_t> {
        get {
            let saved = (UserDefaults.standard.array(forKey: "hiddenByOptimize") as? [Int]) ?? []
            return Set(saved.map { pid_t($0) }.filter { NSRunningApplication(processIdentifier: $0) != nil })
        }
        set { UserDefaults.standard.set(newValue.map { Int($0) }, forKey: "hiddenByOptimize") }
    }

    static func optimizeAsAdmin(pids: [pid_t], _ on: Bool) -> Outcome {
        let cmds = pids.map { "/usr/sbin/taskpolicy \(on ? "-b" : "-B") -p \($0)" }.joined(separator: "; ")
        let r = Shell.runAsAdmin(cmds)
        if r.status == 0 { return .ok }
        return Shell.isUserCancelled(r) ? .failed("Cancelled") : .failed(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func reveal(path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// "Run new task": opens apps by name/path natively, otherwise runs the
    /// command through a login shell (so PATH matches Terminal).
    static func run(_ command: String, asAdmin: Bool) -> Outcome {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return .failed("Enter a command or app name.") }

        if !asAdmin, let url = appURL(for: cmd) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return .ok
        }
        if asAdmin {
            let r = Shell.runAsAdmin(cmd + " > /dev/null 2>&1 &")
            if r.status == 0 || Shell.isUserCancelled(r) { return .ok }
            return .failed(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); return .ok } catch { return .failed(error.localizedDescription) }
    }

    private static func appURL(for text: String) -> URL? {
        if text.hasSuffix(".app"), FileManager.default.fileExists(atPath: text) {
            return URL(fileURLWithPath: text)
        }
        guard !text.contains("/") else { return nil }   // paths / commands go to the shell
        let name = text.hasSuffix(".app") ? String(text.dropLast(4)) : text
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
            let path = "\(dir)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Full argument vector via KERN_PROCARGS2 (only for processes we own).
    static func commandLine(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }          // exec path
        while i < size && buf[i] == 0 { i += 1 }          // padding
        var args: [String] = []
        while args.count < Int(argc) && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args.isEmpty ? nil : args.joined(separator: " ")
    }
}

/// `apex-signal`, the tool the administrator prompt runs to end, pause or
/// resume processes by identity.
enum SignalTool {
    static let unavailable = "Apex couldn’t check its administrator tool (apex-signal), so nothing was done. Reinstall Apex."

    /// Inside the app; in a development build, next to the other products.
    /// Nil when it's missing, or when the app's signature (which covers the
    /// tool) doesn't check out: it's about to run as root.
    static func path() -> String? {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let tool = bundle.appendingPathComponent("Contents/MacOS/apex-signal").path
            return FileManager.default.isExecutableFile(atPath: tool) && bundleIsIntact(bundle) ? tool : nil
        }
        let tool = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ApexSignal").path
        return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
    }
    private final class Marker {}

    /// The app on disk is the one running, unmodified, nested code (the tool)
    /// included. The requirement comes from the *running* code (its own
    /// designated requirement plus its code hash, as the kernel has it), so a
    /// bundle replaced on disk, even one signed again, doesn't pass.
    static func bundleIsIntact(_ bundle: URL) -> Bool {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return false }
        let running = unsafeBitCast(me, to: SecStaticCode.self)      // a SecCode is a SecStaticCode
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(running, SecCSFlags(rawValue: kSecCSDynamicInformation), &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return false }
        var designated: SecRequirement?, designatedText: CFString?
        guard SecCodeCopyDesignatedRequirement(running, [], &designated) == errSecSuccess, let designated,
              SecRequirementCopyString(designated, [], &designatedText) == errSecSuccess, let designatedText else { return false }
        let text = "(\(designatedText)) and cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return false }
        // The running slice only: each architecture of a universal app has its own code hash.
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// "pid@start result" lines → results. Unknown lines are ignored. Pure: tested.
    static func parse(_ output: String) -> [ProcessIdentity: SignalResult] {
        var out: [ProcessIdentity: SignalResult] = [:]
        for line in output.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count == 2, let id = ProcessIdentity(argument: String(f[0])), let r = SignalResult(word: String(f[1])) else { continue }
            out[id] = r
        }
        return out
    }
}
