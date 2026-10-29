import AppKit
import SwiftUI

/// Cloud Disks › Overview: all services together. What's backed up and what
/// isn't, why uploads are stuck, what takes the space on this Mac, and
/// what to free, each suggestion with its one-click action.
struct CloudOverviewView: View {
    /// Shows one service's own tab.
    var onOpen: (String) -> Void
    private let store = CloudStore.shared
    @State private var folders: [(name: String, inCloud: String?)] = []
    @State private var hasTimeMachine = true
    @State private var confirm: CloudService?

    private static let kindColors: [String: Color] = [
        "Videos": .purple, "Photos": .blue, "Music and audio": .pink, "Documents": .orange,
        "Archives and installers": .brown, "Other": .gray,
    ]

    var body: some View {
        let services = store.services
        let usage = services.compactMap { store.usage[$0.id] }
        let totals = CloudOverview.totals(usage)
        let kinds = CloudOverview.kinds(usage)
        let suggestions = CloudOverview.suggestions(services: services, usage: store.usage, quota: store.quota,
                                                    appProblem: store.appProblem, serverDown: store.serverDown,
                                                    folders: folders, hasTimeMachine: hasTimeMachine)
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Overview", subtitle: "\(services.count) cloud disk\(services.count == 1 ? "" : "s") · nothing is downloaded to check",
                       accessory: AnyView(
                           Button { services.forEach { store.refresh($0, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                               .buttonStyle(.bordered).help("Check every cloud disk again")
                               .disabled(!store.scanning.isEmpty)),
                       showsRange: false)
            if !store.scanning.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Measuring what’s on this Mac… nothing is downloaded.").foregroundStyle(.secondary) }
            }

            statsGrid([
                ("On this Mac", Fmt.diskBytes(totals.onMac)),
                ("Online only", "\(totals.onlineOnlyFiles) files"),
                ("Not uploaded yet", totals.notUploaded == 0 ? (services.allSatisfy { $0.path.isEmpty || store.usage[$0.id] != nil } ? "None" : "None so far") : "\(totals.notUploaded) files · \(Fmt.diskBytes(totals.notUploadedBytes))"),
                ("Not opened in 3 months", Fmt.diskBytes(totals.untouchedBytes)),
            ])

            // What to do, most important first.
            VStack(alignment: .leading, spacing: 8) {
                Text("WHAT TO DO").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(suggestions) { card($0) }
            }

            // Each service in one line: backed up? on this Mac? online storage?
            VStack(alignment: .leading, spacing: 6) {
                Text("EACH CLOUD DISK").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(services) { s in row(s) }
            }

            if !kinds.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WHAT TAKES THE SPACE ON THIS MAC").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    StackedBar(parts: kinds.map { .init(value: Double($0.bytes), color: Self.kindColors[$0.kind] ?? .gray) },
                               total: Double(max(totals.onMac, 1)))
                    HStack(spacing: 14) {
                        ForEach(kinds, id: \.kind) { k in
                            HStack(spacing: 5) {
                                Circle().fill(Self.kindColors[k.kind] ?? .gray).frame(width: 8, height: 8)
                                Text("\(k.kind) \(Fmt.diskBytes(k.bytes))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .task {
            let clouds = store.services
            let (f, tm) = await Task.detached(priority: .utility) { () -> ([(name: String, inCloud: String?)], Bool) in
                let tm = Shell.capture("/usr/bin/tmutil", ["destinationinfo"], allowFailure: true)?.contains("Name") ?? false
                return (Cloud.personalFolders(clouds: clouds), tm)
            }.value
            folders = f; hasTimeMachine = tm
        }
        .confirmationDialog("Make files you haven’t opened in 3 months online-only?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { s in
            Button("Make Online-Only") { store.offloadAll(s, files: store.usage[s.id]?.untouched ?? []); onOpen(s.id) }
        } message: { s in
            Text("They stay in \(s.name) and download again when you open them. Only files already in the cloud are included.")
        }
    }

    private func card(_ g: CloudOverview.Suggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(g.level)).foregroundStyle(color(g.level)).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(g.title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text(g.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let a = g.action { Button(g.actionTitle) { run(a) } }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ s: CloudService) -> some View {
        let u = store.usage[s.id], q = store.quota[s.id]
        let backup: (String, Color) = {
            guard let u else { return (s.path.isEmpty ? "Online storage only" : "Checking…", .secondary) }
            if s.kind == .folder { return ("A folder on this Mac (not synced by macOS)", .secondary) }
            if u.notUploaded == 0 { return ("Changes from the last \(Cloud.uploadCheckDays) days all uploaded", .green) }
            return ("\(u.notUploaded) not uploaded yet", u.uploadIssues.isEmpty && store.appProblem[s.id] == nil ? .orange : .red)
        }()
        return Button { onOpen(s.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: s.symbol).foregroundStyle(.tint).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).fontWeight(.medium)
                    Text(backup.0).font(.caption).foregroundStyle(backup.1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if let u { Text("\(Fmt.diskBytes(u.onMacBytes)) on this Mac").font(.caption).monospacedDigit() }
                    if let q, let total = q.total {
                        Text("\(Fmt.diskBytes(q.used)) of \(Fmt.diskBytes(total)) online").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else if let q {
                        Text("\(Fmt.diskBytes(q.used)) online").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(10).contentShape(Rectangle())
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func run(_ a: CloudOverview.Action) {
        switch a {
        case .makeOnlineOnly(let id): confirm = store.services.first { $0.id == id }
        case .checkUploads(let id):
            if let s = store.services.first(where: { $0.id == id }) { store.checkUploads(s) }
            onOpen(id)
        case .openService(let id): onOpen(id)
        case .openICloudSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!)
        }
    }

    private func symbol(_ l: CloudOverview.Level) -> String {
        switch l { case .ok: return "checkmark.circle.fill"; case .info: return "info.circle.fill"; case .notice: return "exclamationmark.circle.fill"; case .warning: return "exclamationmark.triangle.fill" }
    }

    private func color(_ l: CloudOverview.Level) -> Color {
        switch l { case .ok: return .green; case .info: return .blue; case .notice: return .orange; case .warning: return .red }
    }
}
