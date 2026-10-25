import AppKit
import UniformTypeIdentifiers

/// One file on a shelf. Files stay where they are; the shelf only points at
/// them. Images dropped without a file (e.g. dragged from a browser) are saved
/// into the shelf's own folder.
struct ShelfItem: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var path: String
    var added = Date()
    /// For a compressed or detail-free copy: the file it was made from (to compare).
    var original: String? = nil
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

struct ShelfSet: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var created = Date()
    var items: [ShelfItem] = []
    /// Categories have a name ("Project screenshots"); other shelves don't.
    var name: String? = nil
    /// Minimized to the menu bar (kept in its Shelf tab) instead of the screen edge.
    var inMenuBar: Bool? = nil
    var title: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return items.isEmpty ? "Empty shelf" : "\(items.count) \(items.count == 1 ? "item" : "items") · \(f.string(from: created))"
    }
    var count: String { "\(items.count) \(items.count == 1 ? "item" : "items")" }
}

/// Which shelf the shelf window shows.
enum ShelfTarget: Hashable, Sendable { case current, side(UUID), category(UUID) }

/// The current shelf and the ones before it (5 in all), shelves put to the
/// side, and named categories; all saved to disk.
@MainActor @Observable
final class ShelfStore {
    static let shared = ShelfStore()
    static let keep = 5
    static let keepSide = 10

    private(set) var shelves: [ShelfSet] = []     // [0] is the current shelf
    var current: ShelfSet { shelves.first ?? ShelfSet() }
    /// Shelves minimized to the side (newest first).
    private(set) var side: [ShelfSet] = []
    /// Named categories; minimizing into one adds to it.
    private(set) var categories: [ShelfSet] = []
    /// The shelf on show (in the floating shelf and the menu bar).
    var open: ShelfTarget = .current
    var shown: ShelfSet {
        switch open {
        case .current: return current
        case .side(let id): return side.first { $0.id == id } ?? current
        case .category(let id): return categories.first { $0.id == id } ?? current
        }
    }

    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var file: URL { folder.appendingPathComponent("shelves.json") }
    @ObservationIgnored private var sideFile: URL { folder.appendingPathComponent("side.json") }
    @ObservationIgnored private var categoriesFile: URL { folder.appendingPathComponent("categories.json") }

    /// `folder`: tests use their own; the app uses Application Support.
    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apex Activity Manager/Shelf", isDirectory: true)
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([ShelfSet].self, from: d) { shelves = s }
        if shelves.isEmpty { shelves = [ShelfSet()] }
        if let d = try? Data(contentsOf: sideFile), let s = try? JSONDecoder().decode([ShelfSet].self, from: d) { side = s }
        if let d = try? Data(contentsOf: categoriesFile), let s = try? JSONDecoder().decode([ShelfSet].self, from: d) { categories = s }
        // Items saved before aliases were followed: point them at the real files.
        var changed = false
        for i in shelves.indices {
            for j in shelves[i].items.indices {
                let real = Self.resolved(shelves[i].items[j].url).path
                if real != shelves[i].items[j].path { shelves[i].items[j].path = real; changed = true }
            }
        }
        if changed { save() }
    }

    /// A Finder alias (or symbolic link) → the file it points to, so the shelf
    /// shows, compresses and hands out the real file. Anything else unchanged.
    nonisolated static func resolved(_ url: URL) -> URL {
        guard (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true,
              let target = try? URL(resolvingAliasFileAt: url) else { return url }
        return target
    }

    func add(_ urls: [URL], original: URL? = nil) {
        var s = shown
        s.items = Self.merged(urls.map { ShelfItem(path: Self.resolved($0).path, original: original?.path) }, into: s.items)
        replaceShown(s)
    }

    /// `new` on top of `old`, without the same file twice. Pure: tested.
    nonisolated static func merged(_ new: [ShelfItem], into old: [ShelfItem]) -> [ShelfItem] {
        var out = old
        for item in new.reversed() where !out.contains(where: { $0.path == item.path }) { out.insert(item, at: 0) }
        return out
    }

    /// Saves image data (no file behind it) into the shelf folder and adds it.
    func add(image: NSImage) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let dir = folder.appendingPathComponent(shown.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Image \(f.string(from: Date())).png")
        guard (try? png.write(to: url)) != nil else { return }
        add([url])
    }

    func remove(_ item: ShelfItem) {
        var s = shown
        s.items.removeAll { $0.id == item.id }
        replaceShown(s)
    }

    /// Starts an empty shelf; the current one moves to the recent list.
    func newShelf() {
        open = .current
        guard !current.items.isEmpty else { return }
        shelves.insert(ShelfSet(), at: 0)
        trim()
        save()
    }

    // MARK: Minimize: to the side, or into a category

    /// Shelves kept at the screen edge / in the menu bar.
    var edgeShelves: [ShelfSet] { side.filter { $0.inMenuBar != true } }
    var menuBarShelves: [ShelfSet] { side.filter { $0.inMenuBar == true } }

    /// Puts the shelf on show to the side (or, `menuBar`, into the menu bar's
    /// Shelf tab); the next drag starts a new one.
    func minimizeToSide(menuBar: Bool = false) {
        if open == .current, !current.items.isEmpty {
            var s = current
            s.inMenuBar = menuBar ? true : nil
            side.insert(s, at: 0)
            while side.count > Self.keepSide { side.removeLast() }
            shelves[0] = ShelfSet()
        }
        open = .current
        save()
    }

    /// Adds the shelf on show to a category (files already in it aren't
    /// added twice), and clears it away: the current shelf starts empty, a
    /// side shelf is removed, another category is folded in.
    func minimize(toCategory id: UUID) {
        guard let c = categories.firstIndex(where: { $0.id == id }) else { return }
        let source = shown
        if open != .category(id) {
            categories[c].items = Self.merged(source.items, into: categories[c].items)
            switch open {
            case .current: shelves[0] = ShelfSet()
            case .side(let sid): side.removeAll { $0.id == sid }
            case .category(let cid): categories.removeAll { $0.id == cid }
            }
        }
        open = .current
        save()
    }

    /// A new category holding the shelf on show (the + button).
    @discardableResult
    func newCategory(named name: String) -> UUID {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same name as an existing category: that one is used, so nothing is split.
        if let existing = categories.first(where: { $0.name?.localizedCaseInsensitiveCompare(clean) == .orderedSame }) {
            minimize(toCategory: existing.id)
            return existing.id
        }
        let c = ShelfSet(name: clean.isEmpty ? "Category \(categories.count + 1)" : clean)
        categories.append(c)
        minimize(toCategory: c.id)
        return c.id
    }

    func renameCategory(_ id: UUID, to name: String) {
        guard let i = categories.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { categories[i].name = clean; save() }
    }

    func deleteCategory(_ id: UUID) {
        categories.removeAll { $0.id == id }
        if open == .category(id) { open = .current }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id.uuidString, isDirectory: true))
        save()
    }

    func removeSide(_ id: UUID) {
        side.removeAll { $0.id == id }
        if open == .side(id) { open = .current }
        save()
    }

    /// Adds files straight into a side shelf or category (dropped on its row).
    func add(_ urls: [URL], to target: ShelfTarget) {
        let previous = open
        open = target
        add(urls)
        open = previous
    }

    /// Brings back an older shelf as the current one.
    func restore(_ shelf: ShelfSet) {
        guard let i = shelves.firstIndex(where: { $0.id == shelf.id }), i > 0 else { return }
        let s = shelves.remove(at: i)
        if current.items.isEmpty { shelves.removeFirst() }
        shelves.insert(s, at: 0)
        save()
    }

    func clearCurrent() {
        var s = shown
        s.items = []
        replaceShown(s)
    }

    /// The newest screenshot in macOS's screenshot folder, if any.
    nonisolated static func latestScreenshot() -> URL? {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let dir = URL(fileURLWithPath: (custom as NSString?)?.expandingTildeInPath
                      ?? (NSHomeDirectory() + "/Desktop"))
        let keys: [URLResourceKey] = [.creationDateKey]
        guard let list = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return nil }
        let sorted = list.filter { ["png", "jpg", "jpeg", "heic", "mov"].contains($0.pathExtension.lowercased()) }
            .map { u in (u, (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }.map(\.0)
        // Spotlight marks screenshots and screen recordings; that's language-independent.
        return sorted.prefix(40).first { u in
            (NSMetadataItem(url: u)?.value(forAttribute: "kMDItemIsScreenCapture") as? Bool) == true
        }
    }

    private func replaceShown(_ s: ShelfSet) {
        switch open {
        case .current:
            if shelves.isEmpty { shelves = [s] } else { shelves[0] = s }
        case .side(let id):
            if let i = side.firstIndex(where: { $0.id == id }) { side[i] = s }
        case .category(let id):
            if let i = categories.firstIndex(where: { $0.id == id }) { categories[i] = s }
        }
        save()
    }

    /// Keeps 5 shelves; files Apex saved for dropped-out shelves are removed.
    private func trim() {
        while shelves.count > Self.keep {
            let old = shelves.removeLast()
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old.id.uuidString, isDirectory: true))
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(shelves) { try? d.write(to: file, options: .atomic) }
        if let d = try? JSONEncoder().encode(side) { try? d.write(to: sideFile, options: .atomic) }
        if let d = try? JSONEncoder().encode(categories) { try? d.write(to: categoriesFile, options: .atomic) }
    }
}
