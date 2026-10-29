import SwiftUI

/// Drive Doctor › Manual: the checks advanced users run by hand, one card
/// each: what it does, whether it changes anything, whether it needs the
/// password, how long it takes, and its result.
struct DriveManualView: View {
    let record: DriveRecord?
    let volumes: [(name: String, path: String)]
    @State private var results: [DriveManual.Check: DriveManual.Result] = [:]
    @State private var running: Set<DriveManual.Check> = []
    @State private var confirmWrite = false
    @State private var confirmDelete = false
    @State private var scan = SurfaceScan()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Run the checks you want, one at a time. Everything here only reads the drive unless it says otherwise, and asks first if it does.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(DriveManual.Check.allCases) { c in card(c) }
            }
        }
        .confirmationDialog("Write a 1 GB test file to this drive?", isPresented: $confirmWrite) {
            Button("Write, Measure and Delete It") { start(.writeSpeed) }
        } message: {
            Text("It needs 1 GB free, is deleted right after, and adds a little wear to an SSD (about as much as copying one 1 GB file).")
        }
        .confirmationDialog("Delete this volume’s local snapshots?", isPresented: $confirmDelete) {
            Button("Delete Snapshots", role: .destructive) { deleteSnapshots() }
        } message: {
            Text("Time Machine can’t restore from them afterwards; your backups on the backup drive aren’t affected. macOS asks for your password.")
        }
    }

    private func card(_ c: DriveManual.Check) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: c.symbol).font(.title3).foregroundStyle(.tint).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.title).font(.headline)
                    Text(c.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        tag(c.writes ? "Writes to the drive" : "Read-only", c.writes ? .orange : .green)
                        if c.needsAdmin { tag("Needs your password", .secondary) }
                        tag(c.duration, .secondary)
                    }
                }
                Spacer()
                action(c)
            }
            if c == .surfaceScan { scanStatus } else if let r = results[c] { resultView(r, c) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func action(_ c: DriveManual.Check) -> some View {
        if c == .surfaceScan {
            if scan.running { Button("Stop") { scan.stop() } } else { Button("Start") { scan.start(volume: volumes.first?.path ?? "/") } }
        } else if running.contains(c) {
            ProgressView().controlSize(.small)
        } else {
            Button(results[c] == nil ? "Run" : "Run Again") { c.writes ? (confirmWrite = true) : start(c) }
                .disabled(volumes.isEmpty)
        }
    }

    private func resultView(_ r: DriveManual.Result, _ c: DriveManual.Check) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(r.summary, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(r.ok ? .green : .orange).font(.callout.weight(.medium))
            ForEach(r.lines, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            if c == .snapshots, !r.lines.isEmpty {
                Button("Delete Local Snapshots…", role: .destructive) { confirmDelete = true }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(.leading, 36)
    }

    private var scanStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if scan.totalMB > 0 {
                ProgressView(value: Double(scan.doneMB), total: Double(scan.totalMB))
                Text("\(Fmt.diskBytes(UInt64(scan.doneMB) << 20)) of \(Fmt.diskBytes(UInt64(scan.totalMB) << 20)) read"
                     + (scan.badMB.isEmpty ? " · no unreadable areas" : " · \(scan.badMB.count) unreadable area\(scan.badMB.count == 1 ? "" : "s")"))
                    .font(.caption).foregroundStyle(scan.badMB.isEmpty ? Color.secondary : .orange)
            }
            if let m = scan.message { Text(m).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(.leading, 36)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func start(_ c: DriveManual.Check) {
        running.insert(c)
        let v = volumes, rec = record
        Task {
            results[c] = await Task.detached(priority: .userInitiated) { await DriveManual.run(c, volumes: v, record: rec) }.value
            running.remove(c)
        }
    }

    private func deleteSnapshots() {
        let names = results[.snapshots]?.lines ?? []
        let dates = names.compactMap(DriveManual.snapshotDate)
        guard !dates.isEmpty else { return }
        let script = dates.map { "/usr/bin/tmutil deletelocalsnapshots \(Shell.quote($0))" }.joined(separator: "; ")
        Task {
            let r = await Task.detached { Shell.runAsAdmin(script, prompt: "Deleting local snapshots needs your password.") }.value
            if !Shell.isUserCancelled(r) { start(.snapshots) }
        }
    }
}

/// The surface scan: one administrator prompt, then the drive is read in
/// 64 MB pieces by a root script that notes progress in a file Apex reads
/// (and stops when Apex leaves a stop file). Read-only.
@MainActor @Observable
final class SurfaceScan {
    var running = false
    var doneMB = 0
    var totalMB = 0
    var badMB: [Int] = []
    var message: String?
    @ObservationIgnored private var progress = ""
    @ObservationIgnored private var stopFile = ""
    @ObservationIgnored private var timer: Timer?

    func start(volume: String) {
        guard !running else { return }
        message = "Asking for your password…"
        Task {
            guard let d = await Task.detached(operation: { DriveManual.disks(of: volume) }).value else { message = "Couldn’t tell which disk this is."; return }
            let size = await Task.detached { () -> Int in
                let r = Shell.run("/usr/sbin/diskutil", ["info", "-plist", d.physical])
                let plist = try? PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as? [String: Any]
                return ((plist?["TotalSize"] as? Int) ?? 0) >> 20
            }.value
            guard size > 0 else { message = "Couldn’t read the drive’s size."; return }
            let base = NSTemporaryDirectory() + "apex-scan-\(UUID().uuidString)"
            progress = base + ".progress"; stopFile = base + ".stop"
            totalMB = size; doneMB = 0; badMB = []; running = true
            message = "Reading every block of \(d.physical)…"
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { self.poll() }
            }
            let script = DriveManual.scanScript(disk: d.physical, totalMB: size, progress: progress, stop: stopFile)
            let r = await Task.detached { Shell.runAsAdmin(script, prompt: "A surface scan reads the whole drive directly, which needs your password. Nothing is written.") }.value
            timer?.invalidate(); poll()
            running = false
            try? FileManager.default.removeItem(atPath: stopFile)
            message = Shell.isUserCancelled(r) ? "Cancelled." : doneMB >= totalMB
                ? (badMB.isEmpty ? "Finished: every block could be read." : "Finished: \(badMB.count) area\(badMB.count == 1 ? "" : "s") couldn’t be read. Back up this drive and replace it.")
                : "Stopped after \(Fmt.diskBytes(UInt64(doneMB) << 20))."
        }
    }

    func stop() { FileManager.default.createFile(atPath: stopFile, contents: Data()) }

    private func poll() {
        guard let text = try? String(contentsOfFile: progress, encoding: .utf8) else { return }
        let p = DriveManual.parseScanProgress(text)
        doneMB = min(totalMB, p.doneMB); badMB = p.badMB
    }
}
