import AppKit
import SwiftUI

/// Every kept shelf with a preview of what's on it: categories, shelves put
/// to the side, and recent shelves. Click one to open it; drop files on a
/// category or side shelf to add them straight in. Shown from the edge handle
/// and the shelf's Shelves button.
struct ShelfLibrary: View {
    /// Opens a kept shelf (the floating shelf opens it by the handle; the menu bar shows it in place).
    var onOpen: (ShelfTarget) -> Void
    var onRestoreRecent: (ShelfSet) -> Void
    private let store = ShelfStore.shared
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var styling: UUID?
    @State private var creating = false

    var body: some View {
        let recent = Array(store.shelves.dropFirst()).filter { !$0.items.isEmpty }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.categories.isEmpty && store.side.isEmpty && recent.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up").font(.title2).foregroundStyle(.secondary)
                        Text("No kept shelves yet").font(.callout.weight(.medium))
                        Text("Minimize a shelf to put it to the side or into a category.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                }
                section("Categories", trailing: {
                    Button { newName = ""; creating = true } label: { Label("New", systemImage: "plus") }
                        .buttonStyle(.borderless).font(.caption)
                        .help("A category of its own (e.g. Work), which can keep its own icon in the menu bar")
                        .popover(isPresented: $creating) {
                            NameField(title: "New category", name: $newName, action: "Create") {
                                let id = store.addCategory(named: newName); creating = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { styling = id }
                            }
                        }
                }) {
                    if store.categories.isEmpty {
                        Text("Group files you keep coming back to, like Work or Receipts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.categories) { c in
                        row(c, title: c.displayName, symbol: c.symbol, tint: ShelfLook.color(c.color), pinned: c.pinned == true) { onOpen(.category(c.id)) }
                            .dropDestination(for: URL.self) { urls, _ in store.add(urls, to: .category(c.id)); return true }
                            .contextMenu {
                                Button("Rename…") { newName = c.name ?? ""; renaming = c.id }
                                Button("Icon and Colour…") { styling = c.id }
                                Button(c.pinned == true ? "Remove from Menu Bar" : store.canPinMore ? "Keep in Menu Bar" : "Keep in Menu Bar (up to \(ShelfStore.maxPinned))") { store.setPinned(c.id, c.pinned != true) }
                                    .disabled(c.pinned != true && !store.canPinMore)
                                Divider()
                                Button("Delete Category", role: .destructive) { store.deleteCategory(c.id) }
                            }
                            .popover(isPresented: Binding(get: { renaming == c.id }, set: { if !$0 { renaming = nil } })) {
                                NameField(title: "Rename category", name: $newName, action: "Rename") {
                                    store.renameCategory(c.id, to: newName); renaming = nil
                                }
                            }
                            .popover(isPresented: Binding(get: { styling == c.id }, set: { if !$0 { styling = nil } })) {
                                ShelfLookPicker(id: c.id)
                            }
                    }
                }
                if !store.menuBarShelves.isEmpty {
                    section("In the menu bar") {
                        ForEach(store.menuBarShelves) { s in
                            row(s, title: s.displayName, symbol: "menubar.rectangle") { onOpen(.side(s.id)) }
                                .dropDestination(for: URL.self) { urls, _ in store.add(urls, to: .side(s.id)); return true }
                                .contextMenu {
                                    Button("Rename…") { newName = s.name ?? ""; renaming = s.id }
                                    Button("Remove", role: .destructive) { store.removeSide(s.id) }
                                }
                                .popover(isPresented: Binding(get: { renaming == s.id }, set: { if !$0 { renaming = nil } })) {
                                    NameField(title: "Name this shelf", name: $newName, action: "Rename") {
                                        store.renameCategory(s.id, to: newName); renaming = nil
                                    }
                                }
                        }
                    }
                }
                if !store.edgeShelves.isEmpty {
                    section("To the side") {
                        ForEach(store.edgeShelves) { s in
                            row(s, title: s.displayName, symbol: "sidebar.right") { onOpen(.side(s.id)) }
                                .dropDestination(for: URL.self) { urls, _ in store.add(urls, to: .side(s.id)); return true }
                                .contextMenu {
                                    Button("Rename…") { newName = s.name ?? ""; renaming = s.id }
                                    Button("Remove", role: .destructive) { store.removeSide(s.id) }
                                }
                                .popover(isPresented: Binding(get: { renaming == s.id }, set: { if !$0 { renaming = nil } })) {
                                    NameField(title: "Name this shelf", name: $newName, action: "Rename") {
                                        store.renameCategory(s.id, to: newName); renaming = nil
                                    }
                                }
                        }
                    }
                }
                if !recent.isEmpty {
                    section("Recent") {
                        LazyVStack(spacing: 6) {
                            ForEach(recent) { s in
                                row(s, title: s.displayName, symbol: "clock",
                                    subtitle: s.created.formatted(.relative(presentation: .named)) + " · " + s.count) { onRestoreRecent(s) }
                                    .contextMenu { Button("Remove", role: .destructive) { store.removeRecent(s.id) } }
                            }
                        }
                        Button("Clear Recent Shelves") { store.clearRecent() }
                            .buttonStyle(.link).font(.caption)
                            .help("Takes them off this list. The files themselves stay where they are.")
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 340)
        .frame(maxHeight: 460)
        .animation(.easeInOut(duration: 0.2), value: store.categories.map(\.id) + store.side.map(\.id))
    }

    private func section(_ title: String, @ViewBuilder trailing: () -> some View = { EmptyView() }, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            content()
        }
    }

    /// A row: up to four thumbnails of what's on it, its name and how many.
    private func row(_ s: ShelfSet, title: String, symbol: String, tint: Color? = nil, pinned: Bool = false,
                     subtitle: String? = nil, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ShelfPreview(items: s.items).frame(width: 52, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: symbol).foregroundStyle(tint ?? .secondary).frame(width: 16)
                        Text(title).lineLimit(1)
                        if pinned { Image(systemName: "menubar.arrow.up.rectangle").font(.caption2).foregroundStyle(.secondary).help("In the menu bar") }
                    }
                    .font(.callout.weight(.medium))
                    Text(subtitle ?? s.items.prefix(3).map(\.name).joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Text("\(s.items.count)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open: " + s.items.prefix(6).map(\.name).joined(separator: ", "))
    }
}

/// Up to three thumbnails piled behind each other, like the shelf's own
/// stack (not side by side), sized to the space it's given.
struct ShelfPreview: View {
    let items: [ShelfItem]

    var body: some View {
        GeometryReader { g in
            let side = max(12, min(g.size.height, g.size.width) - 6)
            let radius = max(4, side * 0.18)
            ZStack {
                if items.isEmpty {
                    RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: side, height: side)
                }
                ForEach(Array(items.prefix(3).enumerated().reversed()), id: \.element.id) { i, item in
                    ShelfThumbnail(url: item.url)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                        .rotationEffect(.degrees(ShelfStackView.angle(i, count: min(3, items.count))))
                        .offset(x: CGFloat(i) * side * 0.06, y: CGFloat(i) * -side * 0.03)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// A one-line name field with an action button (new category, rename).
struct NameField: View {
    let title: String
    @Binding var name: String
    let action: String
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            TextField("Name, e.g. Project screenshots", text: $name)
                .textFieldStyle(.roundedBorder).frame(width: 220)
                .focused($focused)
                .onSubmit(done)
            HStack {
                Spacer()
                Button(action, action: done).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .onAppear { focused = true }
    }
}

/// The slim handle at the screen's right edge: click it (or drag a file onto
/// it) to see side shelves and categories.
struct ShelfSideHandle: View {
    let state: ShelfHandleState
    private let store = ShelfStore.shared
    @State private var showing = false
    @State private var targeted = false
    @State private var bump = false

    var body: some View {
        let count = store.edgeShelves.count + store.categories.count
        VStack(spacing: 5) {
            Image(systemName: "chevron.compact.left").font(.system(size: 15, weight: .semibold))
            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 11))
            Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(targeted || showing ? Color.accentColor : .secondary)
        .frame(width: 22, height: 96)
        .background(.ultraThinMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 11, bottomLeadingRadius: 11, style: .continuous))
        .background(Color.black.opacity(0.35), in: UnevenRoundedRectangle(topLeadingRadius: 11, bottomLeadingRadius: 11, style: .continuous))
        .scaleEffect(bump ? 1.12 : 1, anchor: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { showing.toggle() }
        .onDrop(of: ShelfDrop.types, isTargeted: $targeted) { _ in false }
        .onChange(of: targeted) { _, on in if on { showing = true } }
        .onChange(of: state.pulse) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { bump = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(.easeOut(duration: 0.2)) { bump = false } }
        }
        .popover(isPresented: $showing, arrowEdge: .leading) {
            ShelfLibrary(onOpen: { t in showing = false; FloatingShelf.shared.openShelf(t) },
                         onRestoreRecent: { s in showing = false; store.restore(s); FloatingShelf.shared.openShelf(.current) })
        }
        .help("Shelves to the side and categories")
        .task {
            // Test switch: APEX_OPEN=shelflibrary opens this list at launch.
            if ProcessInfo.processInfo.environment["APEX_OPEN"] == "shelflibrary" {
                try? await Task.sleep(for: .seconds(1)); showing = true
            }
        }
    }
}

/// The shelf header's Minimize button: a small panel with Side, the
/// categories (with what's in them), and a field for a new category.
struct ShelfMinimizeButton: View {
    var onMinimize: (@escaping @MainActor () -> Void) -> Void
    private let store = ShelfStore.shared
    @State private var showing = false
    @State private var name = ""

    var body: some View {
        Button { name = ""; showing.toggle() } label: {
            Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 20, height: 20).background(Color.white.opacity(0.14), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Minimize: put this shelf to the side, or into a category")
        .popover(isPresented: $showing, arrowEdge: .bottom) { options }
        .task {
            // Test switch: APEX_OPEN=shelfminimize opens these options at launch.
            if ProcessInfo.processInfo.environment["APEX_OPEN"] == "shelfminimize" {
                try? await Task.sleep(for: .seconds(1.5)); showing = true
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Minimize to").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            option("Side", detail: "Kept at the screen edge", symbol: "sidebar.right") { store.minimizeToSide() }
            option("Menu Bar", detail: "Kept in the menu bar’s Shelf tab", symbol: "menubar.rectangle") { store.minimizeToSide(menuBar: true) }
            ForEach(store.categories.filter { ShelfTarget.category($0.id) != store.open }) { c in
                option(c.name ?? "Category", detail: "\(c.count) · adds to it", symbol: "folder.fill", preview: c.items) {
                    store.minimize(toCategory: c.id)
                }
            }
            Divider().padding(.vertical, 2)
            HStack(spacing: 6) {
                Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 18)
                TextField("New category", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                Button("Add", action: create).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 270)
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        showing = false
        onMinimize { store.newCategory(named: n) }
    }

    private func option(_ title: String, detail: String, symbol: String, preview: [ShelfItem] = [],
                        _ action: @escaping @MainActor () -> Void) -> some View {
        Button {
            showing = false
            onMinimize(action)
        } label: {
            HStack(spacing: 10) {
                if preview.isEmpty {
                    Image(systemName: symbol).frame(width: 18).foregroundStyle(Color.accentColor)
                } else {
                    ShelfPreview(items: preview).frame(width: 34, height: 30)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// The shelf header's + button: makes this shelf its own category.
struct ShelfNewCategoryButton: View {
    var onCreate: (String) -> Void
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Button { name = ""; naming = true } label: { Image(systemName: "plus") }
            .buttonStyle(.borderless)
            .help("Make this shelf its own category")
            .popover(isPresented: $naming) {
                NameField(title: "New category", name: $name, action: "Create") {
                    naming = false
                    onCreate(name)
                }
            }
    }
}
