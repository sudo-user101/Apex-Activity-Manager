import Darwin

/// One particular process: its PID plus the moment it started, to the
/// microsecond. A PID alone isn't enough to act on: once a process exits,
/// macOS can hand its PID to a new, unrelated process. The start time tells
/// the two apart, and the kernel's own check (the audit token's PID version,
/// used by `ProcessSignal`) makes the final step safe.
///
/// Shared by the app and by `apex-signal`, the tool the administrator prompt
/// runs, which checks every target itself instead of trusting the app.
public struct ProcessIdentity: Hashable, Sendable, Codable, CustomStringConvertible {
    public let pid: Int32
    /// Start time in microseconds since 1970 (the kernel's `p_starttime`). 0: unknown.
    public let startMicros: Int64

    public init(pid: Int32, startMicros: Int64) {
        self.pid = pid
        self.startMicros = startMicros
    }

    /// The process running with `pid` right now, or nil if there's none (or it can't be read).
    public static func current(_ pid: Int32) -> ProcessIdentity? {
        guard case .found(let start) = readStart(pid) else { return nil }
        return ProcessIdentity(pid: pid, startMicros: start)
    }

    public enum Check: Equatable, Sendable {
        /// The same process is still running.
        case same
        /// Nothing runs with this PID any more.
        case exited
        /// The PID now belongs to a different process.
        case reused
        /// It couldn't be checked (unknown start time, or the kernel didn't answer).
        case unverifiable
    }

    /// Is this process still the one that's running with its PID?
    public func check() -> Check {
        guard startMicros > 0 else { return .unverifiable }
        switch Self.readStart(pid) {
        case .found(let start): return start == startMicros ? .same : .reused
        case .gone: return .exited
        case .unreadable: return .unverifiable
        }
    }

    /// For the command line: "pid@startMicros".
    public var argument: String { "\(pid)@\(startMicros)" }

    public init?(argument: String) {
        let parts = argument.split(separator: "@")
        guard parts.count == 2, let pid = Int32(parts[0]), let start = Int64(parts[1]), pid > 0, start > 0 else { return nil }
        self.init(pid: pid, startMicros: start)
    }

    public var description: String { argument }

    enum Start: Equatable { case found(Int64), gone, unreadable }

    /// The kernel's start time for `pid` (readable for every user's processes).
    static func readStart(_ pid: Int32) -> Start {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return errno == ESRCH ? .gone : .unreadable }
        // An empty answer means no such process.
        guard size > 0, info.kp_proc.p_pid == pid else { return .gone }
        let t = info.kp_proc.p_starttime
        return .found(Int64(t.tv_sec) * 1_000_000 + Int64(t.tv_usec))
    }
}

/// What happened when a signal was to be sent to one process.
public enum SignalResult: Equatable, Sendable {
    /// Delivered to the intended process.
    case sent
    /// It had already exited: nothing to do.
    case exited
    /// Refused: the PID now belongs to a different process.
    case reused
    /// The intended process is running, but this user can't signal it (needs an administrator).
    case notPermitted
    /// Refused: its identity couldn't be verified, so nothing was sent.
    case unverifiable
    /// Refused by Apex's own rules (the kernel, launchd, Apex itself).
    case protected
    /// The kernel returned another error.
    case failed(Int32)

    /// For `apex-signal`'s output.
    public var word: String {
        switch self {
        case .sent: "sent"
        case .exited: "exited"
        case .reused: "reused"
        case .notPermitted: "not-permitted"
        case .unverifiable: "unverifiable"
        case .protected: "protected"
        case .failed(let e): "failed-\(e)"
        }
    }

    public init?(word: String) {
        switch word {
        case "sent": self = .sent
        case "exited": self = .exited
        case "reused": self = .reused
        case "not-permitted": self = .notPermitted
        case "unverifiable": self = .unverifiable
        case "protected": self = .protected
        default:
            guard word.hasPrefix("failed-"), let e = Int32(word.dropFirst(7)) else { return nil }
            self = .failed(e)
        }
    }

    /// Ended (or already gone): the process the user meant isn't running any more.
    public var isDone: Bool { self == .sent || self == .exited }
}

/// Signals a process only if it's still the one that was meant.
public enum ProcessSignal {
    /// Sends `signal` to `target`, never to whatever else has its PID now.
    ///
    /// 1. The target's audit token is read from the kernel (it names one
    ///    process: PID plus the PID's version).
    /// 2. The start time is checked again *after* reading the token: if it
    ///    still matches, the token belongs to the intended process (a process
    ///    can't exit and come back).
    /// 3. The signal goes through `proc_signal_with_audittoken`, which the
    ///    kernel refuses (ESRCH) if the token's PID version is no longer
    ///    current, so there's no gap between the check and the signal.
    ///
    /// Without a token (another user's process, as a normal user) nothing is
    /// sent: `.notPermitted`. There's no fallback to a PID-only `kill`.
    public static func send(_ signal: Int32, to target: ProcessIdentity) -> SignalResult {
        guard target.pid > 1, target.pid != getpid() else { return .protected }
        switch target.check() {
        case .same: break
        case .exited: return .exited
        case .reused: return .reused
        case .unverifiable: return .unverifiable
        }
        guard var token = auditToken(target.pid) else {
            // Gone meanwhile, or not ours to read (another user's process).
            switch target.check() {
            case .same: return .notPermitted
            case .exited: return .exited
            case .reused: return .reused
            case .unverifiable: return .unverifiable
            }
        }
        // The token was read while the intended process held the PID?
        switch target.check() {
        case .same: break
        case .exited: return .exited
        case .reused: return .reused
        case .unverifiable: return .unverifiable
        }
        guard Int32(bitPattern: token.val.5) == target.pid else { return .unverifiable }
        let r = proc_signal_with_audittoken(&token, signal)
        switch r {
        case 0: return .sent
        case ESRCH: return target.check() == .reused ? .reused : .exited
        case EPERM: return .notPermitted
        default: return .failed(r)
        }
    }

    /// The kernel's audit token for `pid`: its PID and the PID's version
    /// (`val.5`, `val.7`). Readable for your own processes, or for any as root.
    static func auditToken(_ pid: Int32) -> audit_token_t? {
        var port: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &port) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? token : nil
    }
}
