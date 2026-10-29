import Foundation

/// Drive Doctor's Manual mode: the checks advanced users run by hand on a
/// Mac, one at a time, each explained, read-only unless it says otherwise
/// (and then it asks first). The pure parts (parsers, sums) are tested; the
/// rest calls macOS's own tools (`diskutil`, `tmutil`, `log`, `dd`).
enum DriveManual {
    enum Check: String, CaseIterable, Identifiable, Sendable {
        case health, firstAid, partitionMap, snapshots, errorLog, readSpeed, writeSpeed, surfaceScan
        var id: String { rawValue }

        var title: String {
            switch self {
            case .health: "Health log details"
            case .firstAid: "First Aid (check only)"
            case .partitionMap: "Partition map"
            case .snapshots: "Local snapshots"
            case .errorLog: "Disk errors in the system log"
            case .readSpeed: "Read speed"
            case .writeSpeed: "Write and read speed"
            case .surfaceScan: "Surface scan"
            }
        }
        var detail: String {
            switch self {
            case .health: "Everything the drive’s own health log reports: wear, spare blocks, media errors, temperature, power-on hours and unsafe shutdowns."
            case .firstAid: "macOS’s First Aid in check-only mode on each volume: it reports file system damage without repairing anything."
            case .partitionMap: "Checks the drive’s partition table, the map that says where each volume starts and ends."
            case .snapshots: "Time Machine’s local snapshots on this volume. They hold space that macOS frees when it needs it; deleting them is a separate step."
            case .errorLog: "Searches the last day of the system log for read and write errors macOS recorded for this drive. Slow: about two minutes."
            case .readSpeed: "Reads 1 GB straight from the drive (not from the cache) and times it. Nothing is written."
            case .writeSpeed: "Writes a 1 GB test file, reads it back, then deletes it. Useful to compare with the drive’s rated speed."
            case .surfaceScan: "Reads every block of the drive and lists any that can’t be read. Nothing is written. Takes as long as reading the whole drive."
            }
        }
        var symbol: String {
            switch self {
            case .health: "heart.text.square"
            case .firstAid: "cross.case"
            case .partitionMap: "square.split.2x1"
            case .snapshots: "clock.arrow.circlepath"
            case .errorLog: "exclamationmark.bubble"
            case .readSpeed: "speedometer"
            case .writeSpeed: "arrow.up.arrow.down.circle"
            case .surfaceScan: "square.grid.3x3"
            }
        }
        var writes: Bool { self == .writeSpeed }
        var needsAdmin: Bool { self == .readSpeed || self == .surfaceScan }
        var duration: String {
            switch self {
            case .health, .partitionMap, .snapshots: "about a second"
            case .firstAid: "about 10 s per volume"
            case .errorLog: "about 2 minutes"
            case .readSpeed: "about 10 s"
            case .writeSpeed: "about 20 s"
            case .surfaceScan: "minutes to hours, by size"
            }
        }
    }

    struct Result: Sendable, Equatable {
        var ok: Bool
        var summary: String
        var lines: [String] = []
    }

    // MARK: Which disk

    /// The disks behind a volume: its own device, the whole disk it's on, and
    /// (for APFS) the physical disk under the container.
    struct Disks: Sendable, Equatable { var device: String; var whole: String; var physical: String }

    static func disks(of volume: String) -> Disks? {
        let r = Shell.run("/usr/sbin/diskutil", ["info", "-plist", volume])
        guard let d = try? PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as? [String: Any],
              let device = d["DeviceIdentifier"] as? String, let whole = d["ParentWholeDisk"] as? String else { return nil }
        var physical = whole
        if let stores = d["APFSPhysicalStores"] as? [[String: Any]], let store = stores.first?["APFSPhysicalStore"] as? String {
            let s = Shell.run("/usr/sbin/diskutil", ["info", "-plist", store])
            if let sd = try? PropertyListSerialization.propertyList(from: Data(s.stdout.utf8), format: nil) as? [String: Any],
               let p = sd["ParentWholeDisk"] as? String { physical = p }
        }
        return Disks(device: device, whole: whole, physical: physical)
    }

    // MARK: Parsers (pure, tested)

    /// `diskutil verifyDisk` / `verifyVolume` output → result.
    static func parseVerify(_ text: String, status: Int32) -> Result {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let ok = status == 0 && lines.contains { $0.contains("appears to be OK") }
        let key = lines.last { $0.contains("appears to be") || $0.localizedCaseInsensitiveContains("error") } ?? lines.last ?? ""
        return Result(ok: ok, summary: ok ? "No problems found." : (key.isEmpty ? "The check reported a problem (exit \(status))." : key),
                      lines: Array(lines.suffix(12)))
    }

    /// `tmutil listlocalsnapshots /` → snapshot names (dates).
    static func parseSnapshots(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("com.apple.") }
    }

    /// The date part of a snapshot name ("2026-09-27-135829"), for `tmutil deletelocalsnapshots`.
    static func snapshotDate(_ name: String) -> String? {
        let parts = name.split(separator: ".")
        return parts.first { $0.count == 17 && $0.filter { $0 == "-" }.count == 3 }.map(String.init)
    }

    /// Kernel log lines → the ones about this disk that are real I/O errors.
    /// Page-in "error 22" lines from Spotlight are harmless and left out.
    static func relevantErrors(_ lines: [String], disks: [String]) -> [String] {
        lines.filter { l in
            let low = l.lowercased()
            guard disks.contains(where: { low.contains($0.lowercased()) }) || low.contains("i/o error") else { return false }
            if low.contains("apfs_pagein") && low.contains("error 22") { return false }
            return low.contains("i/o error") || low.contains("error 5") || low.contains("read error") || low.contains("write error")
                || low.contains("media error") || low.contains("checksum")
        }
    }

    /// Bytes over seconds → "1.2 GB/s".
    static func speed(_ bytes: Double, _ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let bps = bytes / seconds
        return bps >= 1e9 ? String(format: "%.2f GB/s", bps / 1e9) : String(format: "%.0f MB/s", bps / 1e6)
    }

    /// The surface scan's progress file: "done <MB>" lines and "bad <MB>" lines.
    static func parseScanProgress(_ text: String) -> (doneMB: Int, badMB: [Int]) {
        var done = 0, bad: [Int] = []
        for l in text.split(separator: "\n") {
            let f = l.split(separator: " ")
            guard f.count == 2, let n = Int(f[1]) else { continue }
            if f[0] == "done" { done = max(done, n) } else if f[0] == "bad" { bad.append(n) }
        }
        return (done, bad)
    }

    /// The root script for the surface scan: reads the raw disk in 64 MB
    /// chunks, noting progress and unreadable chunks in `progress`, and stops
    /// when `stop` exists. Read-only (`dd of=/dev/null`). Pure: tested.
    static func scanScript(disk: String, totalMB: Int, progress: String, stop: String) -> String {
        """
        i=0; : > \(Shell.quote(progress)); while [ $i -lt \(totalMB) ]; do [ -e \(Shell.quote(stop)) ] && break; \
        /bin/dd if=/dev/r\(disk) of=/dev/null bs=1m skip=$i count=64 2>/dev/null || echo "bad $i" >> \(Shell.quote(progress)); \
        i=$((i+64)); echo "done $i" >> \(Shell.quote(progress)); done
        """
    }

    // MARK: Running

    static func run(_ c: Check, volumes: [(name: String, path: String)], record: DriveRecord?) async -> Result {
        let first = volumes.first?.path ?? "/"
        switch c {
        case .health:
            guard let s = record?.smart else {
                return Result(ok: true, summary: "This drive doesn’t share a health log with macOS (common for USB drives and SD cards).")
            }
            let lines = [
                "Wear: \(s.percentageUsed)% of its rated life used",
                "Spare blocks: \(s.availableSpare)% (warning at \(s.spareThreshold)%)",
                "Media errors: \(s.mediaErrors) · error log entries: \(s.errorLogEntries)",
                "Temperature: \(s.temperatureC) °C · critical warning flags: \(s.criticalWarning)",
                "Power-on: \(s.powerOnHours) hours · power cycles: \(s.powerCycles) · unsafe shutdowns: \(s.unsafeShutdowns)",
                "Read in its lifetime: \(Fmt.diskBytes(s.dataReadBytes)) · written: \(Fmt.diskBytes(s.dataWrittenBytes))",
            ]
            let ok = s.criticalWarning == 0 && s.mediaErrors == 0 && s.availableSpare > s.spareThreshold
            return Result(ok: ok, summary: ok ? "The health log looks fine." : "The health log shows a problem; see the details.", lines: lines)

        case .firstAid:
            let results = DriveCheck.verify(volumes)
            return Result(ok: results.allSatisfy(\.ok), summary: results.allSatisfy(\.ok) ? "No problems found on \(results.count) volume\(results.count == 1 ? "" : "s")." : "First Aid found a problem.",
                          lines: results.map { "\($0.volume): \($0.summary)" })

        case .partitionMap:
            guard let d = disks(of: first) else { return Result(ok: false, summary: "Couldn’t tell which disk this is.") }
            let r = Shell.run("/usr/sbin/diskutil", ["verifyDisk", d.physical])
            return parseVerify(r.stdout + r.stderr, status: r.status)

        case .snapshots:
            let r = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", first])
            let snaps = parseSnapshots(r.stdout)
            return Result(ok: true, summary: snaps.isEmpty ? "No local snapshots on this volume." : "\(snaps.count) local snapshot\(snaps.count == 1 ? "" : "s"). macOS removes them by itself when space runs low.",
                          lines: snaps)

        case .errorLog:
            guard let d = disks(of: first) else { return Result(ok: false, summary: "Couldn’t tell which disk this is.") }
            let r = Shell.run("/usr/bin/log", ["show", "--last", "1d", "--style", "compact", "--predicate",
                                              "process == \"kernel\" AND (eventMessage CONTAINS[c] \"error\")"])
            let found = relevantErrors(r.stdout.split(separator: "\n").map(String.init), disks: [d.device, d.whole, d.physical])
            return Result(ok: found.isEmpty, summary: found.isEmpty ? "No read or write errors for this drive in the last day." : "\(found.count) error line\(found.count == 1 ? "" : "s") in the last day.",
                          lines: Array(found.suffix(15)))

        case .readSpeed:
            guard let d = disks(of: first) else { return Result(ok: false, summary: "Couldn’t tell which disk this is.") }
            let start = Date()
            let r = Shell.runAsAdmin("/bin/dd if=/dev/r\(d.physical) of=/dev/null bs=4m count=256",
                                     prompt: "Reading the drive directly needs your password. Nothing is written.")
            if Shell.isUserCancelled(r) { return Result(ok: false, summary: "Cancelled.") }
            let secs = Date().timeIntervalSince(start)
            // dd's own figure ("… bytes transferred in N secs") is more exact than our clock.
            let ddSecs = r.stderr.range(of: #"in ([0-9.]+) secs"#, options: .regularExpression).flatMap { Double(r.stderr[$0].split(separator: " ")[1]) }
            return Result(ok: r.status == 0, summary: r.status == 0 ? "Read \(speed(1_073_741_824, ddSecs ?? secs))." : "The read failed: " + r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))

        case .writeSpeed:
            return await Task.detached { writeTest(volume: first) }.value

        case .surfaceScan:
            return Result(ok: false, summary: "Run it from its own Start button.")
        }
    }

    /// 1 GB written (uncached), read back (uncached), deleted. In the volume's
    /// own temporary area so it never lands on another drive.
    static func writeTest(volume: String, size: Int = 1 << 30) -> Result {
        let dir = volume == "/" ? NSTemporaryDirectory() : volume
        let file = (dir as NSString).appendingPathComponent(".apex-speed-test-\(UUID().uuidString)")
        defer { unlink(file) }
        let chunk = [UInt8](repeating: 0xA5, count: 8 << 20)        // 8 MB, not all zeros
        let total = size
        let fd = open(file, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard fd >= 0 else { return Result(ok: false, summary: "Couldn’t write a test file here (read-only or full).") }
        _ = fcntl(fd, F_NOCACHE, 1)
        var start = Date()
        var written = 0
        while written < total { let n = chunk.withUnsafeBytes { write(fd, $0.baseAddress, chunk.count) }; if n <= 0 { break }; written += n }
        fsync(fd); close(fd)
        let writeSecs = Date().timeIntervalSince(start)
        guard written >= total else { return Result(ok: false, summary: "The drive stopped accepting data (full?) after \(Fmt.diskBytes(UInt64(written))).") }
        let rfd = open(file, O_RDONLY)
        guard rfd >= 0 else { return Result(ok: false, summary: "Couldn’t read the test file back.") }
        _ = fcntl(rfd, F_NOCACHE, 1)
        var buf = [UInt8](repeating: 0, count: 8 << 20)
        start = Date()
        var read = 0
        while true { let n = buf.withUnsafeMutableBytes { Darwin.read(rfd, $0.baseAddress, $0.count) }; if n <= 0 { break }; read += n }
        close(rfd)
        let readSecs = Date().timeIntervalSince(start)
        return Result(ok: true, summary: "Write \(speed(Double(written), writeSecs)) · read \(speed(Double(read), readSecs)).",
                      lines: ["\(Fmt.diskBytes(UInt64(size))) test file written without the cache, read back, then deleted."])
    }
}
