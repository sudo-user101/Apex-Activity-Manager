import AppKit
import SwiftUI

/// Header icon on each drive page: blue while files are being copied onto the
/// drive; click for each file, where it's going, progress and what can be done.
struct TransfersButton: View {
    let volumes: [String]          // the drive's volume paths ("/" = startup drive)
    @State private var show = false
    private var monitor: TransferMonitor { TransferMonitor.shared }

    var body: some View {
        let list = monitor.transfers(on: volumes)
        let active = list.filter(\.active)
        Button { show.toggle() } label: {
            Image(systemName: "arrow.up.arrow.down.circle" + (active.isEmpty ? "" : ".fill"))
                .foregroundStyle(active.isEmpty ? Color.secondary : Color.blue)
                .symbolEffect(.pulse, isActive: !active.isEmpty)
        }
        .buttonStyle(.bordered)
        .help(active.isEmpty ? "File transfers to this drive" : "\(active.count) file transfer\(active.count == 1 ? "" : "s") in progress")
        .popover(isPresented: $show, arrowEdge: .bottom) { TransfersPopover(volumes: volumes).frame(width: 420) }
    }
}

private struct TransfersPopover: View {
    let volumes: [String]
    @State private var error: String?
    private var monitor: TransferMonitor { TransferMonitor.shared }

    var body: some View {
        let list = monitor.transfers(on: volumes)
        VStack(alignment: .leading, spacing: 10) {
            Text("Transfers").font(.headline)
            if list.isEmpty {
                Text("Nothing is being copied to this drive. Copies made in Finder show up here while they run, and for 15 minutes after.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 8) { ForEach(list) { row($0) } }
            }
            .frame(maxHeight: 360)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if list.contains(where: { $0.active && !$0.pausable }) {
                Text("Finder doesn’t let other apps pause its copies; you can cancel and copy again later.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    private func row(_ t: TransferMonitor.Transfer) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFileType: t.file.pathExtension)).resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name).lineLimit(1).truncationMode(.middle)
                    Text(status(t)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if t.active {
                    if t.pausable {
                        Button { monitor.setPaused(t.id, !t.paused) } label: { Image(systemName: t.paused ? "play.fill" : "pause.fill") }
                            .buttonStyle(.borderless).help(t.paused ? "Resume" : "Pause")
                    }
                    if t.cancellable {
                        Button { monitor.cancel(t.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel this copy")
                    }
                } else if !t.cancelled && t.movedTo == nil {
                    Menu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([t.file]) }
                        Button("Move to Another Folder…") { error = monitor.move(t.id) }
                        Divider()
                        Button("Wrong File: Move to Trash") { error = monitor.trash(t.id) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Wrong file or wrong place?")
                }
            }
            if t.active { ProgressView(value: t.fraction).progressViewStyle(.linear) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func status(_ t: TransferMonitor.Transfer) -> String {
        if t.active { return "\(t.operation) to \(t.folder) · \(Int((t.fraction * 100).rounded()))%" + (t.paused ? " · paused" : "") }
        if t.cancelled { return "Cancelled" }
        if let m = t.movedTo {
            return m.path.contains("/.Trash") ? "Moved to the Trash" : "Moved to \((m.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)"
        }
        return "Copied to \(t.folder) · \(t.finished.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")"
    }
}
