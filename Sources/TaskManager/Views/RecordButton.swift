import AppKit
import SwiftUI

/// Record: in the toolbar it records everything; on a Performance page
/// (`scope`) only that resource. One click starts; while it runs only a red
/// dot and the time show; one click stops and offers the file.
struct RecordButton: View {
    var scope: RecordScope = .all
    /// Page buttons are icon-sized next to the page's other buttons.
    var compact = false
    private let rec = Recorder.shared
    @State private var showSaved = false

    var body: some View {
        let session = rec.sessions[scope]
        Button {
            let wasRecording = rec.isRecording(scope)
            withAnimation(.easeInOut(duration: 0.2)) { rec.toggle(scope) }
            if wasRecording { showSaved = true }
        } label: {
            if let start = session?.started {
                HStack(spacing: 5) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text((compact ? "" : "Recording ") + Self.clock(ctx.date.timeIntervalSince(start))).monospacedDigit()
                    }
                }
            } else if compact {
                Image(systemName: "record.circle")
            } else {
                Label("Record", systemImage: "record.circle")
            }
        }
        .modifier(PageButtonStyle(compact: compact))
        .help(session != nil ? "Stop recording and save the file"
              : scope == .all ? "Record everything (CPU, GPU, memory, disk, network and every process) to a file you can give to an AI to find out what’s going on"
              : "Record \(scope.folder) only (and each process’s \(scope.folder) figures) to a file in Apex Recordings › \(scope.folder)")
        .popover(isPresented: $showSaved, arrowEdge: .bottom) { saved }
        .alert("Couldn’t start recording", isPresented: Binding(get: { rec.error != nil }, set: { _ in })) {
            Button("OK", role: .cancel) {}
        } message: { Text(rec.error ?? "") }
    }

    private var saved: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recording saved", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            if let last = rec.lastFiles[scope] {
                let f = last.url
                Text(f.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                Text("\(last.samples) samples · \(Fmt.diskBytes(MediaCompressor.fileSize(f))) · in Apex Recordings › \(scope.folder). Give this file to an AI assistant and ask what was going on.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]); showSaved = false }
                    Button("Copy File") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([f as NSURL])
                        showSaved = false
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    /// 75 → "1:15", 3725 → "1:02:05". Pure.
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Page header buttons are bordered icons; the toolbar one stays plain.
private struct PageButtonStyle: ViewModifier {
    let compact: Bool
    func body(content: Content) -> some View {
        if compact { content.buttonStyle(.bordered) } else { content }
    }
}
