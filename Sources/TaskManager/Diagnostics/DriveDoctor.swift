import Foundation

/// Drive Doctor: turns a drive's health record (what `DriveHealthStore` has
/// learned, plus the SSD's own health log where there is one) into findings
/// with evidence and steps. Pure and unit-tested; it reads, never acts.
enum DriveDoctor {
    struct Input: Sendable {
        var record: DriveRecord?
        var usb: USBLink?
        var capacity: UInt64 = 0
        var available: UInt64 = 0
        var firstAid: [DriveCheck.Result] = []
        var now = Date()
    }

    /// A lifespan estimate, only when the data supports one.
    enum Lifespan: Equatable, Sendable {
        /// Remaining years of *rated* life at the wear rate seen so far.
        /// `maxYears` nil = "or longer" (wear too slow to bound).
        case estimate(minYears: Double, maxYears: Double?, basis: String)
        case qualitative(String)
        case unknown(String)
    }

    static let minDaysForEstimate = 30.0

    static func diagnose(_ i: Input) -> DiagnosisReport {
        guard let r = i.record else {
            return DiagnosisReport(subject: "", findings: [], missing: ["Apex hasn’t seen this drive long enough to keep a record yet."])
        }
        var f: [Finding] = []
        var missing: [String] = []
        let backUp = DiagnosticStep(title: "Back up anything important on this drive now",
                                    expected: "Your files are safe whatever happens to the drive.",
                                    risk: "Copy to a different drive, not another folder on this one.")

        // The drive's own health log (internal NVMe SSDs).
        if let s = r.smart {
            let ev = smartEvidence(s)
            if s.criticalWarning != 0 {
                f.append(Finding(id: "smart.critical", title: "The drive reports a critical warning",
                                 why: "The SSD’s controller has flagged a condition it considers dangerous (such as running out of spare blocks, overheating or becoming read-only).",
                                 severity: .critical, confidence: .confirmed,
                                 evidence: [Evidence(label: "Critical warning flags", value: String(format: "0x%02X", s.criticalWarning), source: .device)] + ev,
                                 steps: [backUp, DiagnosticStep(title: "Make an appointment with Apple or an authorised service provider",
                                                                expected: "Internal SSDs on Apple silicon Macs can’t be swapped by the user.")],
                                 actions: [.openTimeMachine],
                                 escalate: "Now: a critical warning from the drive itself is the strongest failure sign there is."))
            }
            if s.availableSpare < s.spareThreshold {
                f.append(Finding(id: "smart.spare", title: "Spare blocks are below the safe limit",
                                 why: "SSDs swap worn-out blocks for spares. When spares run low, the drive may soon stop accepting writes.",
                                 severity: .critical, confidence: .confirmed,
                                 evidence: [Evidence(label: "Spare blocks left", value: "\(s.availableSpare)% (limit \(s.spareThreshold)%)", source: .device)],
                                 steps: [backUp], actions: [.openTimeMachine],
                                 escalate: "Plan a replacement or repair soon."))
            }
            if s.percentageUsed >= 70 {
                f.append(Finding(id: "smart.wear", title: "\(s.percentageUsed)% of its rated lifespan is used",
                                 why: "Flash memory wears with every write. The rating is conservative; many drives keep working well past 100%, but errors become more likely.",
                                 severity: s.percentageUsed >= 90 ? .warning : .notice, confidence: .confirmed,
                                 evidence: [Evidence(label: "Rated life used", value: "\(s.percentageUsed)%", source: .device),
                                            Evidence(label: "Written in its lifetime", value: Fmt.diskBytes(s.dataWrittenBytes), source: .device)],
                                 causes: ["Heavy writing over the years: swap from low memory, video editing, virtual machines or big downloads."],
                                 steps: [backUp,
                                         DiagnosticStep(title: "Reduce swap by closing memory-hungry apps",
                                                        expected: "Fewer writes from macOS paging memory to disk; check the Memory page’s swap figure.")],
                                 actions: [.openTimeMachine],
                                 followUp: "Watch this percentage here; a steady climb of a few points a year is normal.",
                                 escalate: s.percentageUsed >= 100 ? "It’s past its rating: keep backups current and consider a repair when errors appear." : ""))
            }
            if s.mediaErrors > 0 {
                f.append(Finding(id: "smart.media", title: "The drive has recorded data errors",
                                 why: "Media errors are reads the drive couldn’t complete correctly. A few old ones can be harmless; a growing count is a failure sign.",
                                 severity: .warning, confidence: .confirmed,
                                 evidence: [Evidence(label: "Media and data errors", value: "\(s.mediaErrors)", source: .device)],
                                 steps: [backUp, DiagnosticStep(title: "Check the file system for damage",
                                                                expected: "First Aid reports “appears to be OK”.")],
                                 actions: [.checkForErrors, .openDiskUtility],
                                 followUp: "Come back in a few days. If the number goes up, the drive is getting worse.",
                                 escalate: "If the count keeps rising, get the drive checked or replaced."))
            }
            if s.temperatureC >= 70 {
                f.append(Finding(id: "smart.heat", title: "The drive is running hot (\(s.temperatureC) °C)",
                                 why: "Hot SSDs slow themselves down to protect the flash, and sustained heat shortens their life.",
                                 severity: .notice, confidence: .confirmed,
                                 evidence: [Evidence(label: "Drive temperature", value: "\(s.temperatureC) °C", source: .device)],
                                 causes: ["Long, heavy writes", "A warm room or a blocked vent", "The Mac working hard for a long time"],
                                 steps: [DiagnosticStep(title: "Let the Mac cool and keep its vents clear", expected: "The temperature drops below 60 °C at rest.")],
                                 followUp: "Check the temperature again after a few minutes idle."))
            }
            if let first = r.smartFirst, s.unsafeShutdowns > first.unsafeShutdowns + 5 {
                f.append(Finding(id: "smart.shutdowns", title: "The Mac has been switched off without shutting down",
                                 why: "Losing power mid-write can damage files. It isn’t a drive fault, but repeated unsafe shutdowns add risk.",
                                 severity: .info, confidence: .confirmed,
                                 evidence: [Evidence(label: "Unsafe shutdowns since Apex started watching",
                                                     value: "\(s.unsafeShutdowns - first.unsafeShutdowns)", source: .device)],
                                 causes: ["Holding the power button to force off", "The battery running completely flat", "Crashes or kernel panics"],
                                 steps: [DiagnosticStep(title: "Use Shut Down from the Apple menu where possible")]))
            }
        } else if !r.isStartup {
            missing.append("USB and Thunderbolt drives don’t pass their own health log through macOS, so wear and spare blocks can’t be read. Apex judges these drives by errors, response time and speed instead.")
        }

        // Errors and retries macOS counted while Apex was watching.
        if r.reportsErrors, r.errors > 0 {
            f.append(Finding(id: "io.errors", title: "Read or write errors happened while Apex was watching",
                             why: "macOS had operations on this drive fail. That can be the drive, but on external drives the cable, port or enclosure is a common cause.",
                             severity: .warning, confidence: .confirmed,
                             evidence: [Evidence(label: "I/O errors", value: "\(Int(r.errors))", source: .macOS),
                                        Evidence(label: "Retries", value: "\(Int(r.retries))", source: .macOS)],
                             causes: r.isStartup ? ["The drive itself"] : connectionCauses(i.usb),
                             steps: (r.isStartup ? [] : connectionSteps) + [backUp,
                                     DiagnosticStep(title: "Check the file system", expected: "First Aid reports no problems.")],
                             actions: [.checkForErrors, .openDiskUtility],
                             followUp: "If errors stop after changing the cable or port, that was the cause. If they follow the drive to another cable and port, the drive or its enclosure is at fault.",
                             escalate: "Errors that follow the drive everywhere mean it should be replaced."))
        } else if r.reportsErrors, r.retries > 10 {
            f.append(Finding(id: "io.retries", title: "macOS had to retry operations on this drive",
                             why: "Retries succeed in the end but point to an unreliable link or a struggling drive.",
                             severity: .notice, confidence: .likely,
                             evidence: [Evidence(label: "Retries", value: "\(Int(r.retries))", source: .macOS)],
                             causes: r.isStartup ? ["The drive itself"] : connectionCauses(i.usb),
                             steps: r.isStartup ? [backUp] : connectionSteps,
                             followUp: "Watch whether the retry count keeps growing."))
        }

        // Response time.
        if let lat = r.latencyMs, let base = r.latencyBaselineMs, base > 0, r.activeSeconds > 600, lat > base * 3, lat > 2 {
            f.append(Finding(id: "latency", title: "The drive is responding slower than usual",
                             why: "A drive that suddenly takes much longer per operation may be retrying internally, overheating or nearly full.",
                             severity: .notice, confidence: .likely,
                             evidence: [Evidence(label: "Recent response time", value: String(format: "%.1f ms", lat), source: .measured),
                                        Evidence(label: "Its usual response time", value: String(format: "%.1f ms", base), source: .measured)],
                             causes: ["The drive is nearly full", "Heavy work from another app at the same time", "Heat", "Wear or a failing drive"],
                             steps: [DiagnosticStep(title: "Free some space if the drive is over 90% full", expected: "Response time returns to normal."),
                                     DiagnosticStep(title: "Check the file system", expected: "First Aid reports no problems.")],
                             actions: [.checkForErrors, .freeUpSpace],
                             followUp: "Response time is re-measured continuously; check back after some normal use."))
        }

        // Transfers slowing down.
        let recent = r.transfers.suffix(DriveHealthRules.slowRecentCount)
        if recent.count == DriveHealthRules.slowRecentCount, r.transfers.count > DriveHealthRules.slowRecentCount {
            let speed = { (t: TransferEpisode) in max(t.readMBps, t.writeMBps) }
            let best = r.transfers.dropLast(DriveHealthRules.slowRecentCount).map(speed).max() ?? 0
            if best > 0, recent.allSatisfy({ speed($0) < best * DriveHealthRules.slowRatio }) {
                let last = recent.map(speed).reduce(0, +) / Double(recent.count)
                f.append(Finding(id: "transfers.slow", title: "Large transfers have become much slower",
                                 why: "Drives slow down when they’re very full, hot, connected through a slower port, or wearing out.",
                                 severity: .notice, confidence: .possible,
                                 evidence: [Evidence(label: "Best transfer speed", value: String(format: "%.0f MB/s", best), source: .measured),
                                            Evidence(label: "Recent transfers", value: String(format: "%.0f MB/s on average", last), source: .measured)],
                                 causes: ["The drive is nearly full", "A slower port, hub or cable than before", "Heat during long copies", "Wear"],
                                 steps: (r.isStartup ? [] : connectionSteps) + [DiagnosticStep(title: "Free some space", expected: "Speeds recover on the next large copy.")],
                                 actions: [.freeUpSpace],
                                 followUp: "Copy a large file again and compare the speed here."))
            }
        }

        // Plugged into a slower port than it supports.
        if let u = i.usb, u.slowerThanItCould {
            f.append(Finding(id: "usb.slow", title: "Connected at \(u.short), slower than it supports",
                             why: "This drive supports \(u.supports) but is running at \(u.short), so copies take several times longer.",
                             severity: .notice, confidence: .confirmed,
                             evidence: [Evidence(label: "Connected at", value: u.connectedAs, source: .macOS),
                                        Evidence(label: "Drive supports", value: u.supports, source: .device)],
                             causes: ["A USB 2 cable or hub", "A USB 2 port or adapter"],
                             steps: [DiagnosticStep(title: "Plug it straight into the Mac with a USB 3 (or USB-C) cable",
                                                    expected: "The Connection line shows USB 3.2 or faster.")],
                             followUp: "The connection speed updates as soon as it’s plugged back in."))
        }

        // Nearly full.
        if i.capacity > 0 {
            let free = Double(i.available) / Double(i.capacity)
            if free < 0.1 {
                f.append(Finding(id: "space.low", title: "The drive is almost full",
                                 why: "SSDs need free space to stay fast and spread wear; a startup drive also needs room for updates and swap.",
                                 severity: free < 0.03 ? .warning : .notice, confidence: .confirmed,
                                 evidence: [Evidence(label: "Free", value: "\(Fmt.diskBytes(i.available)) of \(Fmt.diskBytes(i.capacity)) (\(Int(free * 100))%)", source: .macOS)],
                                 steps: [DiagnosticStep(title: "Review large and unneeded files", expected: "At least 10–15% free.",
                                                        risk: "Apex shows everything for review first and never deletes on its own.")],
                                 actions: r.isStartup ? [.freeUpSpace, .openStorageSettings] : [.freeUpSpace]))
            }
        }

        // First Aid results, when the user has run the check.
        for res in i.firstAid where !res.ok {
            f.append(Finding(id: "firstaid.\(res.volume)", title: "First Aid found a problem on “\(res.volume)”",
                             why: "The file system (how files are organised on the drive) has damage. That can lose files even on a healthy drive.",
                             severity: .warning, confidence: .confirmed,
                             evidence: [Evidence(label: "First Aid (read-only)", value: res.summary, source: .macOS)],
                             steps: [backUp, DiagnosticStep(title: "Run First Aid in Disk Utility to repair it",
                                                            expected: "Disk Utility reports the volume is OK.",
                                                            risk: r.isStartup ? "Repairing the startup volume may need Recovery mode." : "Close any files open from the drive first.")],
                             actions: [.openDiskUtility],
                             followUp: "Run Check for Errors again afterwards.",
                             escalate: "If repairs keep failing, copy your files off and erase or replace the drive."))
        }

        let assess = DriveHealthRules.assess(r)
        if assess.status == .learning { missing.append(assess.reasons.first ?? "") }
        if f.isEmpty, assess.status == .good {
            f.append(Finding(id: "healthy", title: "No problems found",
                             why: "Nothing Apex can measure points to a problem with this drive.",
                             severity: .ok, confidence: .confirmed,
                             evidence: assess.reasons.map { Evidence(label: "Checked", value: $0, source: r.smart != nil ? .device : .measured) },
                             followUp: "Apex keeps watching and adds it to Events if anything changes."))
        }
        return DiagnosisReport(subject: r.name, findings: f, missing: missing.filter { !$0.isEmpty })
    }

    /// Remaining rated life from the wear rate Apex has *observed* (first
    /// health-log reading vs now). The rating is integer percent, so a
    /// ±1 point uncertainty becomes the range. No reading pair, no number.
    static func lifespan(_ r: DriveRecord?, now: Date = Date()) -> Lifespan {
        guard let r else { return .unknown("No record for this drive yet.") }
        guard let s = r.smart else {
            return .unknown("This drive doesn’t report wear to macOS, so its remaining life can’t be estimated. Errors, retries and slowdowns are the warning signs to watch, and Apex tracks those.")
        }
        if s.percentageUsed >= 100 {
            return .qualitative("It has used its full rated lifespan. Many drives keep going well beyond that, but keep backups current.")
        }
        let days = now.timeIntervalSince(r.firstSeen) / 86400
        if let first = r.smartFirst, days >= minDaysForEstimate {
            let delta = Double(s.percentageUsed - first.percentageUsed)
            let left = Double(100 - s.percentageUsed)
            let basis = "\(s.percentageUsed - first.percentageUsed) point(s) of wear in \(Int(days)) days"
            if delta >= 1 {
                let fast = (delta + 1) / days, slow = (delta - 1) / days
                return .estimate(minYears: left / fast / 365, maxYears: slow > 0 ? left / slow / 365 : nil, basis: basis)
            }
            return .qualitative("No measurable wear in \(Int(days)) days of watching: at this pace it has many years of rated life left (\(100 - s.percentageUsed)% remaining).")
        }
        let wait = max(0, Int((minDaysForEstimate - days).rounded(.up)))
        return .qualitative("\(100 - s.percentageUsed)% of its rated life remains. Apex needs about \(wait) more day(s) of wear readings to estimate how long that lasts at your pace.")
    }

    static func describe(_ l: Lifespan) -> String {
        switch l {
        case .estimate(let lo, let hi, let basis):
            let a = years(lo)
            let range = hi.map { "\(a)–\(years($0))" } ?? "\(a) or more"
            return "About \(range) of rated life at your current pace (\(basis)). This is an estimate from the drive’s wear rating, not a failure date."
        case .qualitative(let s), .unknown(let s):
            return s
        }
    }

    private static func years(_ y: Double) -> String {
        if y < 1 { return "\(max(1, Int((y * 12).rounded()))) months" }
        if y >= 20 { return "20+ years" }
        return "\(Int(y.rounded())) years"
    }

    private static func smartEvidence(_ s: SMARTHealth) -> [Evidence] {
        [Evidence(label: "Rated life used", value: "\(s.percentageUsed)%", source: .device),
         Evidence(label: "Spare blocks", value: "\(s.availableSpare)%", source: .device),
         Evidence(label: "Temperature", value: "\(s.temperatureC) °C", source: .device)]
    }

    private static func connectionCauses(_ u: USBLink?) -> [String] {
        ["The cable (the most common cause; try another one)",
         "The port, hub or adapter it’s plugged into",
         "Not enough power from a hub or a bus-powered enclosure",
         "The drive’s enclosure or USB bridge",
         "The drive itself"]
    }

    private static let connectionSteps: [DiagnosticStep] = [
        DiagnosticStep(title: "Try a different cable", expected: "Errors stop; that cable was faulty."),
        DiagnosticStep(title: "Plug it straight into the Mac, not through a hub or adapter",
                       expected: "Errors stop; the hub or its power supply was the problem."),
        DiagnosticStep(title: "Eject it properly before unplugging", risk: "Unplugging without ejecting can damage files."),
    ]
}
