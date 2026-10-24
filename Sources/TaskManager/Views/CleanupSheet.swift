import SwiftUI

/// Clean: review-before-delete clean-up by category.
struct CleanView: View {
    @Environment(AppModel.self) private var model
    var onBack: () -> Void
    var onDone: () -> Void
    @State private var categories: [CleanCategory] = []
    @State private var scanning = true
    @State private var current: CleanCategory.Kind?
    @State private var deselected = Set<String>()          // item paths the user unticked
    @State private var enabled = Set<CleanCategory.Kind>()
    @State private var expanded = Set<CleanCategory.Kind>()
    @State private var working = false
    @State private var result: String?
    @State private var confirmEmptyTrash = false

    var body: some View {
        let chosen = categories.filter { enabled.contains($0.kind) && $0.kind != .trash }
            .flatMap { $0.items }.filter { !deselected.contains($0.path) }
        let chosenSize = chosen.reduce(0) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Button { onBack() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).help("Back")
                Text("Clean").font(.title2).bold()
                Spacer()
                Text("\(Fmt.diskBytes(model.snapshot.system.disk.available)) available")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Text("Review what’s found, untick anything you want to keep, then move it to the Trash. Nothing is deleted until you empty the Trash.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let result { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(categories) { cat in categoryRow(cat) }
                    if scanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Scanning \(current.map { CleanCategory(kind: $0, items: []).title.lowercased() } ?? "")…")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(minHeight: 360, maxHeight: 460)

            HStack {
                Button("Rescan") { Task { await scan() } }.disabled(scanning || working)
                Spacer()
                Button("Done") { onDone() }
                Button("Move \(chosen.count) Item\(chosen.count == 1 ? "" : "s") to Trash · \(Fmt.diskBytes(chosenSize))") {
                    clean(chosen)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty || scanning || working)
            }
        }
        .task { await scan() }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmEmptyTrash) {
            Button("Empty Trash", role: .destructive) { emptyTrash() }
        } message: { Text("Items in the Trash will be permanently deleted. This can’t be undone.") }
    }

    @ViewBuilder
    private func categoryRow(_ cat: CleanCategory) -> some View {
        let on = enabled.contains(cat.kind)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if cat.kind != .trash {
                    Toggle("", isOn: Binding(get: { on }, set: { if $0 { enabled.insert(cat.kind) } else { enabled.remove(cat.kind) } }))
                        .toggleStyle(.checkbox).labelsHidden().disabled(cat.items.isEmpty)
                }
                Image(systemName: cat.symbol).frame(width: 20).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cat.title).fontWeight(.medium)
                    Text(cat.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(cat.items.isEmpty ? "Nothing found" : Fmt.diskBytes(cat.size))
                    .monospacedDigit().foregroundStyle(cat.items.isEmpty ? .secondary : .primary)
                if cat.kind == .trash && !cat.items.isEmpty {
                    Button("Empty…") { confirmEmptyTrash = true }.disabled(working)
                }
                if !cat.items.isEmpty {
                    Button { if expanded.contains(cat.kind) { expanded.remove(cat.kind) } else { expanded.insert(cat.kind) } } label: {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded.contains(cat.kind) ? 90 : 0))
                    }
                    .buttonStyle(.borderless)
                }
            }
            if expanded.contains(cat.kind) {
                VStack(spacing: 0) {
                    ForEach(Array(cat.items.prefix(200).enumerated()), id: \.element.id) { i, item in
                        HStack(spacing: 8) {
                            if cat.kind != .trash {
                                Toggle("", isOn: Binding(get: { !deselected.contains(item.path) },
                                                         set: { if $0 { deselected.remove(item.path) } else { deselected.insert(item.path) } }))
                                    .toggleStyle(.checkbox).labelsHidden().disabled(!on)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(Fmt.diskBytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                            Button { ProcessActions.reveal(path: item.path) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless).help("Show in Finder")
                        }
                        .padding(.horizontal, 8).frame(minHeight: 30)
                        .background(i % 2 == 1 ? Color.primary.opacity(0.035) : .clear)
                    }
                    if cat.items.count > 200 {
                        Text("+ \(cat.items.count - 200) more").font(.caption).foregroundStyle(.secondary).padding(6)
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func scan() async {
        scanning = true
        categories = []
        result = nil
        let cats = await Task.detached(priority: .userInitiated) {
            DiskCleaner.scan { kind in Task { @MainActor in current = kind } }
        }.value
        categories = cats
        enabled = Set(cats.filter { $0.selectedByDefault && !$0.items.isEmpty }.map(\.kind))
        scanning = false
    }

    private func clean(_ items: [CleanItem]) {
        working = true
        Task {
            let (freed, failed) = await Task.detached(priority: .userInitiated) { DiskCleaner.trash(items) }.value
            result = "Moved \(Fmt.diskBytes(freed)) to the Trash." + (failed.isEmpty ? "" : " \(failed.count) item\(failed.count == 1 ? "" : "s") couldn’t be moved (in use or protected).")
            working = false
            await scan()
            if let r = result { result = r }
        }
    }

    private func emptyTrash() {
        guard let trash = categories.first(where: { $0.kind == .trash }) else { return }
        working = true
        Task {
            let (freed, _) = await Task.detached(priority: .userInitiated) { DiskCleaner.emptyTrash(trash.items) }.value
            working = false
            await scan()
            result = "Emptied the Trash and freed \(Fmt.diskBytes(freed))."
        }
    }
}
