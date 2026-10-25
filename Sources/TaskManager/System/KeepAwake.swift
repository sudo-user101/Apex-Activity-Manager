import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac (and optionally the display) awake for a while, with the
/// same power assertions macOS's own `caffeinate` uses. Released when the time
/// is up, when switched off, or when Apex quits (macOS drops them with the
/// process). Lid-closed staying awake needs the helper (request #112).
@MainActor @Observable
final class KeepAwake {
    static let shared = KeepAwake()

    /// nil = off; .distantFuture = until switched off.
    private(set) var until: Date?
    private(set) var displayOn = false
    @ObservationIgnored private var system: IOPMAssertionID = 0
    @ObservationIgnored private var display: IOPMAssertionID = 0
    @ObservationIgnored private var timer: Timer?

    static let choices: [(String, TimeInterval?)] = [
        ("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200), ("5 hours", 18000),
        ("Until I turn it off", nil),
    ]

    var isOn: Bool { until != nil }

    func start(for duration: TimeInterval?, keepDisplayOn: Bool) {
        stop()
        let reason = "Apex Activity Manager: Keep Awake" as CFString
        IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &system)
        if keepDisplayOn {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &display)
        }
        displayOn = keepDisplayOn
        until = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
        if let duration {
            timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
                MainActor.assumeIsolated { KeepAwake.shared.stop() }
            }
        }
    }

    func setDisplayOn(_ on: Bool) {
        guard let until else { displayOn = on; return }
        let left = until == .distantFuture ? nil : until.timeIntervalSinceNow
        start(for: left.map { max(1, $0) }, keepDisplayOn: on)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if system != 0 { IOPMAssertionRelease(system); system = 0 }
        if display != 0 { IOPMAssertionRelease(display); display = 0 }
        until = nil
    }

    /// "1h 20m left", "On until you turn it off", or "".
    func remainingText(now: Date = Date()) -> String {
        guard let until else { return "" }
        if until == .distantFuture { return "On until you turn it off" }
        let s = max(0, Int(until.timeIntervalSince(now)))
        return s >= 3600 ? "\(s / 3600)h \((s % 3600) / 60)m left" : "\(max(1, s / 60))m left"
    }
}

/// macOS's energy mode: Low Power, Automatic, or High Power (some Macs).
enum PowerMode: Equatable {
    case low, automatic, high
    var title: String { self == .low ? "Low Power" : self == .high ? "High Power" : "Automatic" }

    nonisolated(unsafe) private static var cache: (PowerMode, Date)?
    nonisolated(unsafe) private static var refreshing = false
    private static let lock = NSLock()

    /// `pmset -g` "powermode" (0 automatic, 1 low, 2 high), else Low Power Mode
    /// from ProcessInfo. Views ask on every refresh, so this never blocks:
    /// it answers from the last reading and re-reads `pmset` in the background
    /// when that is over 10 s old.
    static func current(now: Date = Date()) -> PowerMode {
        lock.lock(); defer { lock.unlock() }
        let fallback: PowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled ? .low : .automatic
        if cache == nil || now.timeIntervalSince(cache!.1) >= 10, !refreshing {
            refreshing = true
            DispatchQueue.global(qos: .utility).async {
                let mode = parse(Shell.capture("/usr/bin/pmset", ["-g"]) ?? "")
                    ?? (ProcessInfo.processInfo.isLowPowerModeEnabled ? .low : .automatic)
                lock.lock(); cache = (mode, Date()); refreshing = false; lock.unlock()
            }
        }
        return cache?.0 ?? fallback
    }

    static func parse(_ out: String) -> PowerMode? {
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2, f[0] == "powermode" || f[0] == "lowpowermode" else { continue }
            switch (f[0], f[1]) {
            case ("powermode", "1"), ("lowpowermode", "1"): return .low
            case ("powermode", "2"): return .high
            case ("powermode", "0"): return .automatic
            default: continue
            }
        }
        return nil
    }
}
