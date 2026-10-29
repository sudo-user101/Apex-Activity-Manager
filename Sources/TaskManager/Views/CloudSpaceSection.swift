import AppKit
import SwiftUI

/// On a service's page: what fills its online storage, and suggestions to
/// free some, each with a confirmation before anything moves.
struct CloudSpaceSection: View {
    let service: CloudService
    let overview: CloudSpace
    @State private var confirm: CloudSpace.Suggestion?
    @State private var open = Set<String>()
    @State private var result: String?
    @State private var working = false
    private let store = CloudStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            fills
            if !overview.suggestions.isEmpty { suggestions }
            else if let result { Text(result).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .confirmationDialog(confirm.map { "Move \($0.items.count) file\($0.items.count == 1 ? "" : "s") (\(Fmt.diskBytes($0.bytes))) to the Trash?" } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { sug in
            Button("Move to Trash", role: .destructive) { trash(sug) }
        } message: { _ in
            Text("They’re removed from \(service.name) online too, which frees that space. Most services keep deleted files in their own bin for a while, and until you empty the Trash you can put them back. Online-only files aren’t downloaded first; if \(service.name) won’t move one to the Trash, Apex leaves it and says so.")
        }
    }

    // MARK: What fills it

    @ViewBuilder private var fills: some View {
        let total = Double(max(overview.totalBytes, 1))
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT FILLS IT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("Online-only files count: they’re what your online storage holds. Shared items not synced to this Mac aren’t included.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            ForEach(overview.folders.prefix(8)) { f in
                HStack(spacing: 8) {
                    Image(systemName: f.path == service.path ? "doc.on.doc" : "folder").foregroundStyle(.secondary).frame(width: 16)
                    Text(f.name).lineLimit(1).truncationMode(.middle).frame(width: 200, alignment: .leading)
                    StackedBar(parts: [.init(value: Double(f.bytes), color: .teal)], total: total)
                    Text(Fmt.diskBytes(f.bytes)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                }
                .font(.callout)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { reveal(f.path) }
            }
            if !overview.largest.isEmpty {
                Text("Largest files").font(.callout.weight(.medium)).padding(.top, 6)
                ForEach(overview.largest.prefix(6)) { row($0) }
            }
        }
    }

    // MARK: Suggestions

    @ViewBuilder private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FREE UP ONLINE SPACE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.diskBytes(overview.suggestions.reduce(0) { $0 + $1.bytes })) could go").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(overview.suggestions) { sug in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { if open.contains(sug.id) { open.remove(sug.id) } else { open.insert(sug.id) } }
                        } label: {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(open.contains(sug.id) ? 90 : 0)).frame(width: 12)
                        }.buttonStyle(.borderless)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.title(sug)).font(.callout.weight(.medium))
                            Text(Self.why(sug.kind)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Fmt.diskBytes(sug.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        Button("Move to Trash…") { confirm = sug }.disabled(working)
                    }
                    if open.contains(sug.id) {
                        VStack(spacing: 2) { ForEach(sug.items.prefix(20)) { row($0) } }.padding(.leading, 20)
                        if sug.items.count > 20 { Text("and \(sug.items.count - 20) more").font(.caption).foregroundStyle(.secondary).padding(.leading, 20) }
                    }
                }
            }
            if let result { Text(result).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    static func title(_ s: CloudSpace.Suggestion) -> String {
        let n = s.items.count
        switch s.kind {
        case .duplicates: return "\(n) extra cop\(n == 1 ? "y" : "ies") of files you already have"
        case .installers: return "\(n) old installer\(n == 1 ? "" : "s")"
        case .unused: return "\(n) large file\(n == 1 ? "" : "s") not opened in over a year"
        }
    }

    static func why(_ k: CloudSpace.Kind) -> String {
        switch k {
        case .duplicates: return "Same contents (or, for online-only files, the same name and size). The first copy is kept."
        case .installers: return "Disk images and installer packages not used in 30 days; apps can be downloaded again."
        case .unused: return "100 MB or more, not opened or changed for a year. Check before removing."
        }
    }

    private func row(_ f: CloudEntry) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 16, height: 16)
            Text(f.name).lineLimit(1).truncationMode(.middle)
            if f.onlineOnly { Image(systemName: "icloud").font(.caption).foregroundStyle(.secondary).help("Online only: not stored on this Mac") }
            Spacer()
            if let d = f.lastUsed { Text(d.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.tertiary) }
            Text(Fmt.diskBytes(f.bytes)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            Button { reveal(f.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder")
            Button { delete(f) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(working)
                .help("Move to the Trash. It’s removed from \(service.name) online too once it syncs; you can put it back from the Trash.")
        }
        .font(.callout)
    }

    private func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    /// One file's trash button: straight to the Trash (it can be put back from there).
    private func delete(_ f: CloudEntry) {
        working = true; result = nil
        Task {
            result = await store.trash(service, [f])
            working = false
        }
    }

    private func trash(_ sug: CloudSpace.Suggestion) {
        working = true; result = nil
        Task {
            result = await store.trash(service, sug.items)
            working = false
        }
    }
}
