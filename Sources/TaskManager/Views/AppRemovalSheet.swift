import AppKit
import SwiftUI

/// Removing an app: "App only" (its settings and data stay, so reinstalling
/// picks up where you left off) or "App and everything it left" (reviewed
/// first, each item can be unticked). Everything goes to the Trash.
struct AppRemovalSheet: View {
    let path: String
    var onDone: (String?) -> Void            // message for the caller

    @Environment(\.dismiss) private var dismiss
    @State private var info: AppRemover.AppInfo?
    @State private var appSize: UInt64?
    @State private var leftovers: [AppRemover.Leftover]?
    @State private var keep = Set<String>()
    @State private var everything = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove “\(info?.name ?? (path as NSString).lastPathComponent)”?").font(.title3.weight(.semibold))
                    Text(appSize.map { "The app takes \(Fmt.diskBytes($0))." } ?? "Measuring…").foregroundStyle(.secondary)
                }
            }
            if let info, info.isApple {
                Label("This app is part of macOS, which protects it.", systemImage: "lock.fill").foregroundStyle(.orange)
            } else {
                if info?.isRunning == true {
                    HStack {
                        Label("It’s open right now.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button("Quit It") { quitApp() }.controlSize(.small)
                    }
                }
                choice(on: !everything, title: "App only",
                       text: "Removes the app. Its settings and data stay, so reinstalling it picks up where you left off.") { everything = false }
                choice(on: everything, title: "App and everything it left",
                       text: leftovers.map { $0.isEmpty ? "Nothing else found in your Library." : "Also removes \($0.count) item\($0.count == 1 ? "" : "s") it keeps in your Library (\(Fmt.diskBytes(leftoverTotal))). Review them below." }
                           ?? "Looking for its files…") { everything = true }
                if everything, let list = leftovers, !list.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(list) { l in
                                Toggle(isOn: Binding(get: { !keep.contains(l.path) },
                                                     set: { if $0 { keep.remove(l.path) } else { keep.insert(l.path) } })) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(l.name).lineLimit(1).truncationMode(.middle)
                                            Text(l.kind).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(Fmt.diskBytes(l.size)).monospacedDigit().foregroundStyle(.secondary)
                                        Button { ProcessActions.reveal(path: l.path) } label: { Image(systemName: "magnifyingglass") }
                                            .buttonStyle(.borderless).help("Show in Finder")
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            HStack {
                Text("Everything goes to the Trash, so you can put it back until you empty it.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(everything ? "Remove All" : "Remove App") { remove() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || info == nil || info?.isApple == true || (everything && leftovers == nil))
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await load() }
    }

    private var leftoverTotal: UInt64 { (leftovers ?? []).filter { !keep.contains($0.path) }.reduce(0) { $0 + $1.size } }

    private func choice(on: Bool, title: String, text: String, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(on ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        let p = path
        let i = await Task.detached(priority: .userInitiated) { AppRemover.info(p) }.value
        info = i
        appSize = await Task.detached(priority: .userInitiated) { FastSize.allocated(p).bytes }.value
        guard let i else { leftovers = []; return }
        leftovers = await Task.detached(priority: .userInitiated) { AppRemover.leftovers(for: i) }.value
    }

    private func quitApp() {
        guard let id = info?.bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await load()
        }
    }

    private func remove() {
        working = true
        let chosen = everything ? (leftovers ?? []).filter { !keep.contains($0.path) } : []
        let p = path, name = info?.name ?? "the app"
        Task {
            let failed = await Task.detached { AppRemover.remove(appPath: p, leftovers: chosen) }.value
            working = false
            onDone(failed.isEmpty
                   ? (chosen.isEmpty ? "Moved \(name) to the Trash." : "Moved \(name) and \(chosen.count) of its files to the Trash.")
                   : "Couldn’t move: " + failed.joined(separator: ", "))
            dismiss()
        }
    }
}
