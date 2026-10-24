import AppKit
import Darwin

/// Process control. Every call reports failure instead of failing silently,
/// and permission failures can
/// be retried with an administrator prompt.
enum ProcessActions {
    enum Outcome: Equatable {
        case ok
        case needsAdmin          // EPERM: process belongs to another user / root
        case failed(String)
    }

    /// Quits regular apps politely (like Dock > Quit); signals everything else.
    static func end(pids: [pid_t], force: Bool) -> Outcome {
        var needsAdmin = false
        var lastError: String?
        for pid in pids {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                let ok = force ? app.forceTerminate() : app.terminate()
                if ok { continue }
            }
            if Darwin.kill(pid, force ? SIGKILL : SIGTERM) != 0 {
                if errno == EPERM { needsAdmin = true }
                else if errno != ESRCH { lastError = String(cString: strerror(errno)) }
            }
        }
        if needsAdmin { return .needsAdmin }
        if let lastError { return .failed(lastError) }
        return .ok
    }

    /// Freezes (SIGSTOP) or resumes (SIGCONT) processes. A paused app keeps
    /// its windows and data but uses no CPU; macOS can compress its memory.
    static func pause(pids: [pid_t], _ on: Bool) -> Outcome {
        var needsAdmin = false
        for pid in pids where Darwin.kill(pid, on ? SIGSTOP : SIGCONT) != 0 {
            if errno == EPERM { needsAdmin = true }
        }
        return needsAdmin ? .needsAdmin : .ok
    }

    static func pauseAsAdmin(pids: [pid_t], _ on: Bool) -> Outcome {
        let r = Shell.runAsAdmin("/bin/kill -\(on ? "STOP" : "CONT") " + pids.map(String.init).joined(separator: " "))
        if r.status == 0 || Shell.isUserCancelled(r) { return .ok }
        return .failed(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
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

    static func endAsAdmin(pids: [pid_t], force: Bool) -> Outcome {
        let list = pids.map(String.init).joined(separator: " ")
        let r = Shell.runAsAdmin("/bin/kill -\(force ? "KILL" : "TERM") \(list)")
        if r.status == 0 { return .ok }
        return Shell.isUserCancelled(r) ? .ok : .failed(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
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
