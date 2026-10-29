import AppKit
import ProcessIdentityCore
import SwiftUI

/// Removing an app: the app itself (always) and, only if ticked, each group
/// of what else belongs to it: its data and settings, system files and
/// helpers, saved sign-ins, and files made with it. Each item can be
/// reviewed and unticked. The app is deleted for good, after you confirm
/// (and quit first, helpers included, so nothing is left running or in the
/// menu bar); its other files go to the Trash, so they can be put back.
struct AppRemovalSheet: View {
    let path: String
    var onDone: (String?) -> Void            // message for the caller

    @Environment(\.dismiss) private var dismiss
    @State private var info: AppRemover.AppInfo?
    @State private var appSize: UInt64?
    @State private var found: [AppRemover.Group: [AppRemover.Leftover]] = [:]
    @State private var chosen = Set<AppRemover.Group>()
    @State private var open: AppRemover.Group?
    @State private var keep = Set<String>()
    @State private var working = false
    @State private var running: [pid_t] = []
    @State private var confirming = false
    /// Without Full Disk Access, Spotlight hides Documents and Desktop from Apex.
    @State private var canSeeFolders = true

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
                if !running.isEmpty {
                    HStack {
                        Label(running.count == 1 ? "It’s open right now." : "It’s open right now (\(running.count) processes, helpers included).",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button("Quit It") { quitApp() }.controlSize(.small)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // What a normal uninstall removes. Always included.
                        row(checked: true, locked: true, symbol: "app.badge.checkmark", title: "The app",
                            detail: "What a normal uninstall removes: the app itself.", size: appSize)
                        ForEach(AppRemover.Group.allCases, id: \.self) { g in groupRow(g) }
                        if !canSeeFolders, found[.documents]?.isEmpty == true {
                            Button("Open Full Disk Access Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                            }
                            .buttonStyle(.link).font(.caption).padding(.leading, 52)
                        }
                    }
                }
                .frame(maxHeight: 430)
                Text("Normally an app’s data stays on the Mac, so if you install it again it picks up where you left off. Tick the rows above only if you want everything about the app gone and the most space back. Click a ticked row’s arrow to review each item.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Frees \(Fmt.diskBytes((appSize ?? 0) + chosenTotal))").font(.callout.weight(.semibold)).monospacedDigit()
                    Text("The app is deleted for good. " + (chosen.isEmpty ? "" : chosen.contains(.signIns)
                         ? "Its files go to the Trash; removed sign-ins can’t be put back." : "Its files go to the Trash, so you can put them back."))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Delete App…" : "Delete Selected…") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || info == nil || info?.isApple == true)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await load() }
        .confirmationDialog("Delete “\(info?.name ?? (path as NSString).lastPathComponent)” permanently?", isPresented: $confirming) {
            Button("Delete App", role: .destructive) { remove() }
        } message: {
            Text((running.isEmpty ? "" : "It’s open: Apex quits it first, with its helpers, so nothing stays in the menu bar. ")
                 + "The app can’t be put back from the Trash; you can download or install it again."
                 + (chosen.isEmpty ? "" : " The other things you ticked go to the Trash."))
        }
    }

    private func items(_ g: AppRemover.Group) -> [AppRemover.Leftover] { (found[g] ?? []).filter { !keep.contains($0.path) } }
    private var chosenTotal: UInt64 { chosen.reduce(0) { t, g in t + items(g).reduce(0) { $0 + $1.size } } }

    private static let texts: [AppRemover.Group: (title: String, symbol: String, none: String)] = [
        .data: ("Its data and settings", "folder.badge.minus", "Nothing found in your Library."),
        .system: ("System files and helpers", "gearshape.2", "No background services, helpers or installer records."),
        .signIns: ("Saved sign-ins", "key", "No sign-ins saved for it."),
        .documents: ("Files you made with it", "doc.on.doc", "No files of its own kind in your folders."),
    ]

    private func detail(_ g: AppRemover.Group) -> String {
        guard let list = found[g] else { return "Looking…" }
        if list.isEmpty, g == .documents, !canSeeFolders {
            return "Apex can’t see inside Documents and Desktop yet, so it can’t find them. Give Apex Full Disk Access, then open this again."
        }
        if list.isEmpty { return Self.texts[g]!.none }
        let n = list.count, s = n == 1 ? "" : "s"
        switch g {
        case .data:
            let kinds = Array(Set(list.map(\.kind))).sorted().prefix(4).joined(separator: ", ").lowercased()
            return "\(n) item\(s) in your Library: \(kinds)."
        case .system:
            return "\(n) item\(s): background services, helper tools or installer records. Asks for your password."
        case .signIns:
            return "\(n) password\(s) it saved in your keychain (only names are shown). You’d need to sign in again."
        case .documents:
            return "\(n) file\(s) of its own kind in your folders. These are your own work: tick only if you don’t need them."
        }
    }

    @ViewBuilder private func groupRow(_ g: AppRemover.Group) -> some View {
        let list = found[g]
        let on = chosen.contains(g)
        row(checked: on, locked: false, symbol: Self.texts[g]!.symbol, title: Self.texts[g]!.title, detail: detail(g),
            size: list.map { _ in items(g).reduce(0) { $0 + $1.size } },
            expanded: on && !(list ?? []).isEmpty ? open == g : nil,
            expand: { withAnimation(.easeInOut(duration: 0.2)) { open = open == g ? nil : g } }) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if on { chosen.remove(g); if open == g { open = nil } } else { chosen.insert(g); if g != .documents { open = g } }
            }
        }
        .disabled(list?.isEmpty != false)
        .opacity(list?.isEmpty == true ? 0.55 : 1)
        if on, open == g, let list, !list.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(list) { l in
                    Toggle(isOn: Binding(get: { !keep.contains(l.path) },
                                         set: { if $0 { keep.remove(l.path) } else { keep.insert(l.path) } })) {
                        HStack {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(l.name).lineLimit(1).truncationMode(.middle)
                                Text(l.isFile ? l.kind + " · " + (l.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~") : l.kind)
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if l.needsAdmin { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("Asks for your password") }
                            if l.isFile {
                                Text(Fmt.diskBytes(l.size)).monospacedDigit().foregroundStyle(.secondary)
                                Button { ProcessActions.reveal(path: l.path) } label: { Image(systemName: "magnifyingglass") }
                                    .buttonStyle(.borderless).help("Show in Finder")
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.leading, 40).padding(.trailing, 6)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// One thing that will (or can) be removed, with its size.
    private func row(checked: Bool, locked: Bool, symbol: String, title: String, detail: String, size: UInt64?,
                     expanded: Bool? = nil, expand: @escaping () -> Void = {}, toggle: @escaping () -> Void = {}) -> some View {
        Button(action: toggle) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17)).foregroundStyle(checked ? (locked ? Color.secondary : Color.accentColor) : .secondary)
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(size.map(Fmt.diskBytes) ?? "…").font(.callout.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(checked ? Color.primary : Color.secondary)
                if let expanded {
                    Button(action: expand) {
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(expanded ? "Hide the items" : "Review each item")
                }
            }
            .padding(12)
            .background(checked && !locked ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!locked)
        .help(locked ? "Always removed" : checked ? "Click to keep these" : "Click to remove these too")
    }

    private func load() async {
        let p = path
        let i = await Task.detached(priority: .userInitiated) { AppRemover.info(p) }.value
        info = i
        running = runningPIDs()
        appSize = await Task.detached(priority: .userInitiated) { FastSize.allocated(p).bytes }.value
        guard let i else { AppRemover.Group.allCases.forEach { found[$0] = [] }; return }
        async let data = Task.detached(priority: .userInitiated) { AppRemover.leftovers(for: i) }.value
        async let system = Task.detached(priority: .userInitiated) { AppRemover.systemItems(for: i) + AppRemover.receipts(for: i) }.value
        async let signIns = Task.detached(priority: .userInitiated) { AppRemover.signIns(for: i) }.value
        async let docs = Task.detached(priority: .utility) { AppRemover.documents(for: i) }.value
        found[.data] = await data
        found[.system] = await system
        found[.signIns] = await signIns
        canSeeFolders = await Task.detached { PermissionCenter.hasFullDiskAccess() }.value
        found[.documents] = await docs
    }

    /// The app and every process of it (by path, bundle ID, or helpers macOS
    /// counts as the app's).
    private func runningPIDs() -> [pid_t] { SafeTrash.runningApps([path]).map(\.id.pid) }

    private func quitApp() {
        Task {
            _ = await SafeTrash.quitApps([path])
            running = runningPIDs()
        }
    }

    private func remove() {
        working = true
        let picked = chosen.flatMap { items($0) }
        let p = path, name = info?.name ?? "the app"
        Task {
            // The app first: quit with all its helpers (no menu bar icon left behind),
            // then deleted for good, with the administrator password if macOS asks for it.
            let app = await SafeTrash.deleteApps([p])
            guard app.failed.isEmpty else {
                working = false
                onDone(app.message)
                dismiss()
                return
            }
            let failed = await Task.detached { AppRemover.remove(appPath: nil, leftovers: picked) }.value
            working = false
            onDone(failed.isEmpty
                   ? (picked.isEmpty ? "Deleted \(name)." : "Deleted \(name); \(picked.count) things that belonged to it are in the Trash.")
                   : "Removed \(name). Couldn’t remove: " + failed.joined(separator: ", "))
            dismiss()
        }
    }
}
