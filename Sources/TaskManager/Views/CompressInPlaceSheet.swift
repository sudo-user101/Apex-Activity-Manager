import SwiftUI

/// Analyze › Compress in place: photos, videos and PDFs in a folder (or one file) made smaller
/// where they are. Asks first; writes every smaller copy before touching an
/// original; on Done the copies take their names and the originals go to the
/// Trash or are deleted for good (your choice). Close without Done: the
/// copies are removed, nothing changed. In a cloud folder: only what's on
/// this Mac, or the whole online folder (downloads first, with a warning).
struct CompressInPlaceSheet: View {
    let path: String
    var onDone: (String) -> Void
    /// Where it starts (render tests show the whole-online warning).
    var startScope: Scope = .onThisMac
    @Environment(\.dismiss) private var dismiss
    @State private var plan: InPlaceCompressor.Plan?
    @State private var keepDetails = true
    enum Scope: Hashable { case onThisMac, wholeOnline }
    @State private var scope = Scope.onThisMac
    @State private var permanently = false
    @State private var kinds = Set(InPlaceCompressor.Kind.allCases)
    /// "Don't show this again" for the explanation and for the download warning.
    @AppStorage("compressSkipExplain") private var skipExplain = false
    @AppStorage("compressSkipCloudWarning") private var skipCloudWarning = false
    @State private var showExplain = false
    @State private var stage = Stage.ready
    @State private var progress = (0, 0)
    @State private var copies: [InPlaceCompressor.Copy] = []
    @State private var skipped: [(String, String)] = []
    @State private var stop = StopFlag()
    enum Stage { case ready, listing, working, review, done }

    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Compress “\(name)” in place", systemImage: "arrow.down.right.and.arrow.up.left").font(.title3.bold())
            switch stage {
            case .ready: ready
            case .listing:
                HStack { ProgressView().controlSize(.small); Text("Listing the folders that are only online… this asks the server for each one.").foregroundStyle(.secondary) }
                HStack { Spacer(); Button("Stop") { stop.stopped = true; stage = .ready } }
            case .working:
                ProgressView(value: Double(progress.0), total: Double(max(1, progress.1)))
                Text("Making smaller copies… \(progress.0) of \(progress.1). Your files aren’t changed yet." + (kinds.contains(.video) ? " Videos take a while each." : "")).font(.callout).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Stop") { stop.stopped = true } }
            case .review: review
            case .done: EmptyView()
            }
        }
        .padding(22).frame(width: 520)
        .task { scope = startScope; plan = await Task.detached { InPlaceCompressor.plan([path]) }.value }
        .onDisappear { if stage == .review { InPlaceCompressor.discard(copies) } }
    }

    private static func label(_ k: InPlaceCompressor.Kind, _ n: Int) -> String {
        switch k {
        case .photo: "\(n) photo\(n == 1 ? "" : "s")"
        case .video: "\(n) video\(n == 1 ? "" : "s")"
        case .pdf: "\(n) PDF\(n == 1 ? "" : "s")"
        }
    }

    @ViewBuilder private var ready: some View {
        if let all = plan {
            if all.photos.isEmpty {
                Text("There’s nothing here to compress (photos, videos: MOV, MP4, M4V, or PDFs).").foregroundStyle(.secondary)
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            } else {
                let p = all.of(kinds)
                VStack(alignment: .leading, spacing: 8) {
                    // Which kinds (only those that are here).
                    let present = InPlaceCompressor.Kind.allCases.filter { all.count($0) > 0 }
                    if present.count > 1 {
                        HStack(spacing: 14) {
                            ForEach(present, id: \.self) { k in
                                Toggle("\(Self.label(k, all.count(k))) · \(Fmt.diskBytes(all.bytes(k)))",
                                       isOn: Binding(get: { kinds.contains(k) }, set: { if $0 { kinds.insert(k) } else { kinds.remove(k) } }))
                            }
                        }
                    }
                    if all.isCloud {
                        Picker("Compress", selection: $scope) {
                            Text("Only what’s on this Mac: \(p.local.count) file\(p.local.count == 1 ? "" : "s"), \(Fmt.diskBytes(p.localBytes)). Nothing downloads.")
                                .tag(Scope.onThisMac)
                            Text("The whole online folder: \(p.photos.count) files\(all.unlistedFolders > 0 ? " and what’s in \(all.unlistedFolders) folder\(all.unlistedFolders == 1 ? "" : "s") only online" : "").")
                                .tag(Scope.wholeOnline)
                        }
                        .pickerStyle(.radioGroup)
                        if scope == .wholeOnline {
                            if skipCloudWarning {
                                Label("Downloads \(Fmt.diskBytes(p.onlineBytes))\(all.unlistedFolders > 0 ? "+" : "") first.", systemImage: "arrow.down.circle")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("Every online-only file has to download first (\(Fmt.diskBytes(p.onlineBytes))\(all.unlistedFolders > 0 ? ", plus the folders not listed yet" : "")), then it’s compressed and the smaller copy uploads again. That takes a while, needs your connection the whole time, and uses that much space here until it’s done.",
                                          systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    Toggle("Don’t warn me about this again", isOn: $skipCloudWarning).font(.caption)
                                }
                            }
                        }
                    } else if present.count <= 1 {
                        Text(InPlaceCompressor.Kind.allCases.filter { p.count($0) > 0 }.map { Self.label($0, p.count($0)) }.joined(separator: ", ")
                             + " · \(Fmt.diskBytes(p.localBytes))").font(.headline)
                    }
                    Toggle("Keep details (camera, place, date)", isOn: $keepDetails)
                    Picker("The originals", selection: $permanently) {
                        Text("Put them in the Trash").tag(false)
                        Text("Delete them permanently").tag(true)
                    }
                    if skipExplain && !showExplain {
                        Button("What happens?") { showExplain = true }.buttonStyle(.link).font(.callout)
                    } else {
                        explanation(p)
                    }
                    let whole = scope == .wholeOnline
                    let need = (whole ? p.localBytes + p.onlineBytes : p.localBytes) / 2 + (whole ? p.onlineBytes : 0)
                    let free = InPlaceCompressor.freeSpace(at: URL(fileURLWithPath: path))
                    if free < need {
                        Label("Not enough room: about \(Fmt.diskBytes(need)) is needed for the copies, \(Fmt.diskBytes(free)) is free. Free some space first.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        Button("Compress") { start(p) }.keyboardShortcut(.defaultAction)
                            .disabled(free < need || p.photos.isEmpty || (scope == .onThisMac && p.local.isEmpty))
                    }
                }
            }
        } else {
            HStack { ProgressView().controlSize(.small); Text("Looking for photos, videos and PDFs…").foregroundStyle(.secondary) }
        }
    }

    /// What's going to happen, step by step, before anything does.
    private func explanation(_ p: InPlaceCompressor.Plan) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("What will happen").font(.callout.weight(.semibold))
            Group {
                Text("1. A smaller copy of each file is made next to it. Nothing of yours changes yet, and you can stop at any time.")
                if p.count(.photo) > 0 { Text("• Photos become HEIC (JPEG stays JPEG): about half the size, same resolution.") }
                if p.count(.video) > 0 { Text("• Videos are re-encoded as HEVC (.mov), very large ones at 1080p: often half the size or less. This takes a while for each video.") }
                if p.count(.pdf) > 0 { Text("• PDFs keep their text; only the pictures inside are made smaller. Text-only PDFs stay as they are.") }
                Text("2. You see how much is saved, then choose Done or Keep the Originals.")
                Text("3. Done puts each copy in place under the same name (the extension can change, e.g. .png → .heic, .mp4 → .mov), and the originals "
                     + (permanently ? "are deleted for good: this can’t be undone." : "go to the Trash, where you can still get them back."))
                Text("Anything that wouldn’t get smaller is left as it is.")
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Don’t show this again", isOn: $skipExplain).font(.caption)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var review: some View {
        let before = copies.reduce(UInt64(0)) { $0 + $1.before }, after = copies.reduce(UInt64(0)) { $0 + $1.after }
        VStack(alignment: .leading, spacing: 8) {
            if copies.isEmpty {
                Text("None of these files got smaller, so nothing will change.").foregroundStyle(.secondary)
            } else {
                Text("\(Fmt.diskBytes(before)) → \(Fmt.diskBytes(after))").font(.title2.bold())
                Text("\(copies.count) file\(copies.count == 1 ? "" : "s") \(Int((1 - Double(after) / Double(max(1, before))) * 100))% smaller. "
                     + (permanently ? "Done replaces the originals and deletes them for good; this can’t be undone."
                                    : "Done replaces the originals (they go to the Trash; empty it to get the space back)."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                let renamed = copies.filter { $0.finalURL != $0.original }.count
                if renamed > 0 { Text("\(renamed) will end in .\(copies.first { $0.finalURL != $0.original }?.finalURL.pathExtension ?? "heic") instead of their old extension.").font(.callout) }
            }
            if !skipped.isEmpty { Text("\(skipped.count) left as they are: " + skipped.prefix(3).map { "\($0.0) (\($0.1))" }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Keep the Originals") { InPlaceCompressor.discard(copies); copies = []; dismiss() }.keyboardShortcut(.cancelAction)
                Button(permanently ? "Done, Delete Originals" : "Done") { finish() }.keyboardShortcut(.defaultAction).disabled(copies.isEmpty)
            }
        }
    }

    private func start(_ p: InPlaceCompressor.Plan) {
        stop = StopFlag()
        let flag = stop
        let keep = keepDetails
        let whole = scope == .wholeOnline
        Task {
            var photos = whole ? p.photos : p.local
            // The whole online folder: list the folders that are only online too (asks the server).
            if whole, p.unlistedFolders > 0 {
                stage = .listing
                let full = await Task.detached { [path] in InPlaceCompressor.plan([path], wholeOnlineFolder: true) }.value
                if flag.stopped { return }
                photos = full.photos
            }
            stage = .working
            let r = await InPlaceCompressor.makeCopies(photos, keepDetails: keep,
                progress: { i, n in Task { @MainActor in progress = (i, n) } },
                cancelled: { flag.stopped })
            copies = r.copies; skipped = r.skipped
            stage = .review
        }
    }

    private func finish() {
        let before = copies.reduce(UInt64(0)) { $0 + $1.before }, after = copies.reduce(UInt64(0)) { $0 + $1.after }
        let failed = InPlaceCompressor.swapIn(copies, permanently: permanently)
        stage = .done
        onDone(failed.isEmpty
               ? "Compressed \(copies.count) file\(copies.count == 1 ? "" : "s"): \(Fmt.diskBytes(before)) → \(Fmt.diskBytes(after)). "
                 + (permanently ? "The originals were deleted." : "The originals are in the Trash.")
               : "Compressed \(copies.count - failed.count); \(failed.count) left as they were.")
        dismiss()
    }
}

/// Set on the main thread, read by the compressor on its own: a lock keeps it safe.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
