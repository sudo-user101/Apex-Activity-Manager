import AppKit
import SwiftUI

/// Categories kept in the menu bar: each gets its own icon there (the symbol
/// and colour chosen for it). Click it to see what's in it; drop files on it
/// to add them.
@MainActor
final class PinnedShelves: NSObject {
    static let shared = PinnedShelves()

    private var items: [UUID: NSStatusItem] = [:]
    private var drops: [UUID: DropTarget] = [:]
    private let popover = NSPopover()
    private var shownID: UUID?

    func start() {
        popover.behavior = .transient
        popover.animates = true
        sync()
        // Test switch: APEX_OPEN=pinned opens the first pinned category's panel at launch.
        if ProcessInfo.processInfo.environment["APEX_OPEN"] == "pinned", let first = ShelfStore.shared.pinnedCategories.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if let b = self?.items[first.id]?.button { self?.clicked(b) }
            }
        }
    }

    /// Adds, updates and removes menu bar icons to match the pinned categories.
    private func sync() {
        let store = ShelfStore.shared
        let pinned = withObservationTracking { store.pinnedCategories } onChange: {
            Task { @MainActor in self.sync() }
        }
        for (id, item) in items where !pinned.contains(where: { $0.id == id }) {
            NSStatusBar.system.removeStatusItem(item)
            items[id] = nil; drops[id] = nil
            if shownID == id { popover.performClose(nil) }
        }
        for c in pinned {
            let item = items[c.id] ?? make(c.id)
            if let b = item.button {
                b.image = Self.image(symbol: c.symbol, color: c.color)
                b.toolTip = "\(c.displayName) · \(c.count). Click to open; drop files here to add them."
                b.setAccessibilityLabel("Shelf category \(c.displayName)")
            }
        }
    }

    private func make(_ id: UUID) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        // Files dropped on the icon: the status item's window takes the drop.
        let drop = DropTarget(id: id)
        item.button?.window?.registerForDraggedTypes(ShelfDrop.pasteboardTypes)
        item.button?.window?.delegate = drop
        items[id] = item; drops[id] = drop
        return item
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        if popover.isShown, shownID == id { popover.performClose(nil); return }
        ShelfStore.shared.open = .category(id)
        shownID = id
        let host = NSHostingController(rootView: PinnedShelfPanel(id: id))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    /// The menu bar image: the symbol in its colour (or plain, like other menu bar icons).
    static func image(symbol: String, color: String?) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) else { return nil }
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let c = ShelfLook.nsColor(color) { config = config.applying(.init(paletteColors: [c])) }
        let img = base.withSymbolConfiguration(config)
        img?.isTemplate = color == nil
        return img
    }

    /// Takes files dropped on one category's menu bar icon.
    private final class DropTarget: NSObject, NSWindowDelegate, NSDraggingDestination {
        let id: UUID
        init(id: UUID) { self.id = id }

        // Only light up for something a shelf can keep.
        func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { accepts(sender) ? .copy : [] }
        func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { accepts(sender) ? .copy : [] }
        private func accepts(_ sender: NSDraggingInfo) -> Bool {
            MainActor.assumeIsolated { ShelfDrop.canAccept(sender.draggingPasteboard) }
        }

        /// The same reading as the shelf itself; with no shelf on screen to
        /// show it, a problem is said in a notification.
        func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard, id = self.id
            return MainActor.assumeIsolated {
                guard ShelfDrop.canAccept(pb) else { return false }
                let store = ShelfStore.shared
                ShelfDrop.receive(pb, into: store.ownFolder(id)) { out in
                    var out = out
                    let added = store.add(out.files, to: .category(id))
                    out.duplicates = out.files.count - added
                    if let m = out.message(added: added) {
                        Alerts.shared.notify(id: "shelf-drop-\(id)", title: store.shelf(.category(id)).displayName, body: m)
                    }
                }
                return true
            }
        }
    }
}

/// What a pinned category's menu bar icon opens: the shelf, showing that category.
private struct PinnedShelfPanel: View {
    let id: UUID

    var body: some View {
        ShelfTab(onOpen: { t in ShelfStore.shared.open = t }, fixed: true)
            .padding(14)
            .frame(width: 340)
            .onAppear { ShelfStore.shared.open = .category(id) }
    }
}

/// Icons and colours a category can have.
enum ShelfLook {
    static let symbols = ["folder.fill", "briefcase.fill", "house.fill", "star.fill", "heart.fill", "bookmark.fill",
                          "tag.fill", "flag.fill", "bolt.fill", "camera.fill", "photo.fill", "film.fill",
                          "music.note", "doc.text.fill", "book.fill", "graduationcap.fill", "paintbrush.fill", "hammer.fill",
                          "gamecontroller.fill", "cart.fill", "airplane", "leaf.fill", "tray.full.fill", "archivebox.fill"]
    static let colors: [(name: String, color: Color)] = [
        ("blue", .blue), ("purple", .purple), ("pink", .pink), ("red", .red), ("orange", .orange),
        ("yellow", .yellow), ("green", .green), ("teal", .teal), ("gray", .gray),
    ]

    static func color(_ name: String?) -> Color? { colors.first { $0.name == name }?.color }
    static func nsColor(_ name: String?) -> NSColor? { color(name).map { NSColor($0) } }
}

/// Choose a category's icon and colour, and whether it stays in the menu bar.
struct ShelfLookPicker: View {
    let id: UUID
    private let store = ShelfStore.shared

    var body: some View {
        let c = store.categories.first { $0.id == id }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: c?.symbol ?? "folder.fill")
                    .font(.system(size: 22)).foregroundStyle(ShelfLook.color(c?.color) ?? .accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(c?.displayName ?? "Category").font(.headline)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
                ForEach(ShelfLook.symbols, id: \.self) { s in
                    Button { store.setLook(id, icon: s, color: c?.color) } label: {
                        Image(systemName: s).font(.system(size: 14))
                            .frame(width: 30, height: 30)
                            .background(c?.symbol == s ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Button { store.setLook(id, icon: c?.icon, color: nil) } label: {
                    Circle().strokeBorder(Color.secondary, lineWidth: 1.5).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: c?.color == nil ? 2 : 0).padding(-3))
                }
                .buttonStyle(.plain).help("No colour: matches the menu bar")
                ForEach(ShelfLook.colors, id: \.name) { col in
                    Button { store.setLook(id, icon: c?.icon, color: col.name) } label: {
                        Circle().fill(col.color).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary, lineWidth: c?.color == col.name ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain).help(col.name.capitalized)
                }
            }
            Divider()
            Toggle("Keep in the menu bar", isOn: Binding(get: { c?.pinned == true }, set: { store.setPinned(id, $0) }))
                .disabled(c?.pinned != true && !store.canPinMore)
                .help(c?.pinned != true && !store.canPinMore
                      ? "Up to \(ShelfStore.maxPinned) categories can be in the menu bar. Take one out first."
                      : "Gives this category its own icon in the menu bar: click it to see the files, drop files on it to add them.")
        }
        .padding(16)
        .frame(width: 300)
    }
}
