import AppKit
import Observation

/// File copies into each drive, as published by Finder (and other apps that
/// publish file progress). Event-driven: one `Progress` subscription per
/// mounted volume, plus the home folder for the startup drive.
///
/// What macOS allows (tested with Finder copies to a USB drive): the copy's
/// destination file, operation and percentage are visible and it can be
/// **cancelled**; Finder copies can't be paused (`isPausable` is false), so
/// pause is shown only when the publisher supports it. A finished copy can be
/// moved elsewhere or to the Trash (wrong file or wrong place).
@MainActor
@Observable
final class TransferMonitor {
    static let shared = TransferMonitor()

    struct Transfer: Identifiable {
        var id = UUID()
        var file: URL
        var origin: String = ""        // where it was copied to (stays with that drive after a move)
        var operation: String          // "Copying", "Moving", "Downloading"…
        var fraction: Double = 0
        var started = Date()
        var finished: Date?
        var cancelled = false
        var cancellable = false
        var pausable = false
        var paused = false
        var movedTo: URL?              // after "Move to…" / Trash
        // Strong: the subscriber's proxy must stay alive for Cancel to reach the copying app.
        @ObservationIgnored var progress: Progress?
        var active: Bool { finished == nil }
        var name: String { file.lastPathComponent }
        var folder: String { (file.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
    }

    private(set) var transfers: [Transfer] = []
    @ObservationIgnored private var subscriptions: [String: Any] = [:]
    @ObservationIgnored private var observers: [UUID: [NSKeyValueObservation]] = [:]
    static let keepFinished: TimeInterval = 15 * 60

    /// Watch exactly these roots (volume paths and the home folder).
    func watch(_ roots: Set<String>) {
        for (path, token) in subscriptions where !roots.contains(path) {
            Progress.removeSubscriber(token); subscriptions[path] = nil
        }
        for path in roots where subscriptions[path] == nil {
            // Never block the publishing thread on the main thread (it could be
            // waiting on us in removeSubscriber): hop over asynchronously, in order.
            subscriptions[path] = Progress.addSubscriber(forFileURL: URL(fileURLWithPath: path)) { p in
                let box = ProgressBox(p), id = UUID()
                DispatchQueue.main.async { MainActor.assumeIsolated { TransferMonitor.shared.add(box.value, id: id) } }
                return { DispatchQueue.main.async { MainActor.assumeIsolated { TransferMonitor.shared.finish(id) } } }
            }
        }
    }

    /// Transfers whose destination is on one of these volumes (startup drive: pass "/").
    func transfers(on volumes: [String]) -> [Transfer] {
        prune()
        return transfers.filter { t in Self.belongs(t.origin, to: volumes) }
    }

    nonisolated static func belongs(_ path: String, to volumes: [String]) -> Bool {
        volumes.contains { v in
            v == "/" ? !path.hasPrefix("/Volumes/") : (path == v || path.hasPrefix(v + "/"))
        }
    }

    private func add(_ p: Progress, id: UUID) {
        let url = p.fileURL ?? (p.userInfo[.fileURLKey] as? URL) ?? URL(fileURLWithPath: "/")
        let op: String
        switch p.fileOperationKind {
        case .some(.copying): op = "Copying"
        case .some(.downloading): op = "Downloading"
        case .some(.decompressingAfterDownloading): op = "Unpacking"
        case .some(.receiving): op = "Receiving"
        default: op = (p.userInfo[.fileOperationKindKey] as? String).map { $0.replacingOccurrences(of: "NSProgressFileOperationKind", with: "") } ?? "Transferring"
        }
        var t = Transfer(id: id, file: url, origin: url.path, operation: op, fraction: max(0, p.fractionCompleted),
                         cancellable: p.isCancellable, pausable: p.isPausable)
        t.progress = p
        transfers.insert(t, at: 0)
        observers[id] = [
            p.observe(\.fractionCompleted) { pp, _ in
                let f = pp.fractionCompleted
                Task { @MainActor in TransferMonitor.shared.update(id) { $0.fraction = f } }
            },
            p.observe(\.isPaused) { pp, _ in
                let paused = pp.isPaused
                Task { @MainActor in TransferMonitor.shared.update(id) { $0.paused = paused } }
            },
        ]
    }

    private func update(_ id: UUID, _ change: (inout Transfer) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[i])
    }

    private func finish(_ id: UUID) {
        observers[id] = nil
        update(id) { t in
            t.finished = Date()
            t.cancelled = t.cancelled || (t.progress?.isCancelled ?? false) || (t.fraction < 0.999 && !FileManager.default.fileExists(atPath: t.file.path))
            if !t.cancelled { t.fraction = 1 }
            t.progress = nil
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.keepFinished)
        if transfers.contains(where: { ($0.finished ?? .distantFuture) < cutoff }) {
            transfers.removeAll { ($0.finished ?? .distantFuture) < cutoff }
        }
    }

    // MARK: Actions (each only when the publisher or the file allows it)

    func cancel(_ id: UUID) {
        update(id) { $0.cancelled = true }
        transfers.first { $0.id == id }?.progress?.cancel()
    }

    func setPaused(_ id: UUID, _ on: Bool) {
        guard let p = transfers.first(where: { $0.id == id })?.progress, p.isPausable else { return }
        if on { p.pause() } else { p.resume() }
    }

    /// Wrong file: move the finished copy to the Trash (undo from the Trash).
    func trash(_ id: UUID) -> String? {
        guard let t = transfers.first(where: { $0.id == id }) else { return nil }
        do {
            var out: NSURL?
            try FileManager.default.trashItem(at: t.file, resultingItemURL: &out)
            update(id) { $0.movedTo = out as URL? }
            return nil
        } catch { return error.localizedDescription }
    }

    /// Wrong place: move the finished copy to a folder the user picks.
    func move(_ id: UUID) -> String? {
        guard let t = transfers.first(where: { $0.id == id }) else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Move Here"; panel.message = "Choose where “\(t.name)” should go"
        panel.directoryURL = t.file.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dir = panel.url else { return nil }
        let dest = dir.appendingPathComponent(t.name)
        do {
            try FileManager.default.moveItem(at: t.file, to: dest)
            update(id) { $0.movedTo = dest; $0.file = dest }
            return nil
        } catch { return error.localizedDescription }
    }

    private final class ProgressBox: @unchecked Sendable { let value: Progress; init(_ p: Progress) { value = p } }
}
