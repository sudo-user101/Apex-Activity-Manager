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
    /// The name without its extension (what Rename edits).
    var baseName: String { url.deletingPathExtension().lastPathComponent }
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
    /// Categories: the SF Symbol and colour chosen for it, and whether it has
    /// its own icon in the menu bar.
    var icon: String? = nil
    var color: String? = nil
    var pinned: Bool? = nil
    var symbol: String { icon ?? "folder.fill" }
    /// A shelf's name: the one given, or one made from what's on it
    /// ("Photo 1 + 2 more"). Pure: tested.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        guard let first = items.first else { return "Empty shelf" }
        let base = first.url.deletingPathExtension().lastPathComponent
        return items.count == 1 ? base : "\(base) + \(items.count - 1) more"
    }
    var title: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return items.isEmpty ? "Empty shelf" : "\(items.count) \(items.count == 1 ? "item" : "items") · \(f.string(from: created))"
    }
    var count: String { "\(items.count) \(items.count == 1 ? "item" : "items")" }

    /// The icons of what's on it, most common first, for the short chip ("7 · 📷"). Pure: tested.
    var kindSymbols: [String] { kinds.map(\.symbol) }

    /// What's on it, counted by kind with an icon ("2 screenshots", "1 video",
    /// "1 PDF", "3 files"), for the short stack chips. Pure: tested.
    var kinds: [(symbol: String, text: String)] {
        var n: [Int] = [0, 0, 0, 0, 0]   // screenshots, images, videos, PDFs, files
        for i in items {
            switch MediaCompressor.kind(i.url) {
            case .image:
                // Screenshots (macOS's own names) and images pasted or dragged in
                // without a file, which Apex saves as "Image <date>".
                let name = i.name
                n[name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot") || name.hasPrefix("Image 2") ? 0 : 1] += 1
            case .video: n[2] += 1
            case .pdf: n[3] += 1
            case .other: n[4] += 1
            }
        }
        let words = [("camera.viewfinder", "screenshot", "screenshots"), ("photo", "image", "images"), ("film", "video", "videos"),
                     ("doc.richtext", "PDF", "PDFs"), ("doc", "file", "files")]
        return zip(n, words).filter { $0.0 > 0 }.map { c, w in (w.0, "\(c) \(c == 1 ? w.1 : w.2)") }
    }
}

/// Which shelf the shelf window shows.
enum ShelfTarget: Hashable, Sendable { case current, side(UUID), category(UUID) }

/// The current shelf and the ones before it, shelves put to the side, and
/// named categories; all saved to disk. No count limits: as many shelves and
/// files as the Mac's memory and disk allow.
@MainActor @Observable
final class ShelfStore {
    static let shared = ShelfStore()

    private(set) var shelves: [ShelfSet] = []     // [0] is the current shelf
    var current: ShelfSet { shelves.first ?? ShelfSet() }
    /// Shelves minimized to the side (newest first).
    private(set) var side: [ShelfSet] = []
    /// Named categories; minimizing into one adds to it.
    private(set) var categories: [ShelfSet] = []
    /// The shelf on show (in the floating shelf and the menu bar).
    var open: ShelfTarget = .current
    var shown: ShelfSet { shelf(open) }

    func shelf(_ target: ShelfTarget) -> ShelfSet {
        switch target {
        case .current: return current
        case .side(let id): return side.first { $0.id == id } ?? current
        case .category(let id): return categories.first { $0.id == id } ?? current
        }
    }

    /// Where Apex keeps a shelf's own files (pictures, links and text dropped
    /// without a file, files an app handed over on drop); removed with the shelf.
    func ownFolder(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString, isDirectory: true) }

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
        // Kept shelves emptied by older versions (they left an empty chip behind).
        var changed = side.contains { $0.items.isEmpty }
        side.removeAll { $0.items.isEmpty }
        // Items saved before aliases were followed: point them at the real files.
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

    /// Returns how many went on (the rest were already there). Only files:
    /// a web address is never taken for a path.
    @discardableResult
    func add(_ urls: [URL], original: URL? = nil) -> Int {
        var s = shown
        let before = s.items.count
        s.items = Self.merged(urls.filter(\.isFileURL).map { ShelfItem(path: Self.resolved($0).path, original: original?.path) }, into: s.items)
        replaceShown(s)
        return s.items.count - before
    }

    /// `new` on top of `old`, without the same file twice (the same file
    /// however its path is written: /var or /private/var, "a/../b"), and
    /// never twice from one drop. Pure: tested.
    nonisolated static func merged(_ new: [ShelfItem], into old: [ShelfItem]) -> [ShelfItem] {
        var out = old
        var have = Set(old.map { canonical($0.path) })
        for item in new.reversed() where have.insert(canonical(item.path)).inserted { out.insert(item, at: 0) }
        return out
    }

    /// One spelling per file. Pure.
    nonisolated static func canonical(_ path: String) -> String {
        let u = URL(fileURLWithPath: path).standardizedFileURL
        // The folder it's in is resolved (it exists even when the file is gone).
        var dir = u.deletingLastPathComponent().path
        if let r = realpath(dir, nil) { dir = String(cString: r); free(r) }
        var out = (dir as NSString).appendingPathComponent(u.lastPathComponent)
        for p in ["/private/var/", "/private/tmp/", "/private/etc/"] where out.hasPrefix(p) { out = String(out.dropFirst(8)) }
        return out
    }

    /// Puts `copy` where the file at `path` was on the shown shelf (same place
    /// in the order), remembering it was made from that file.
    func replace(path: String, with copy: URL) {
        var s = shown
        guard let i = s.items.firstIndex(where: { $0.path == path }) else { add([copy], original: URL(fileURLWithPath: path)); return }
        s.items[i] = ShelfItem(path: copy.path, original: path)
        replaceShown(s)
    }

    func remove(_ item: ShelfItem) {
        var s = shown
        s.items.removeAll { $0.id == item.id }
        replaceShown(s)
    }

    /// Takes files that were moved or deleted off the shelf on show.
    func removeMissing() {
        var s = shown
        s.items.removeAll { !$0.exists }
        replaceShown(s)
    }

    /// Renames the file itself (in its folder) and every shelf entry that
    /// points at it. `base` is the name without the extension, which stays.
    @discardableResult
    func rename(_ item: ShelfItem, to base: String) throws -> URL {
        let to = try Self.renamed(item.url, base: base)
        guard to != item.url else { return to }
        try FileManager.default.moveItem(at: item.url, to: to)
        repoint(from: item.path, to: to.path)
        return to
    }

    /// Every shelf entry that pointed at `old` (or was made from it) now points at `new`.
    private func repoint(from old: String, to new: String) {
        func fix(_ set: inout ShelfSet) {
            for j in set.items.indices {
                if set.items[j].path == old { set.items[j].path = new }
                if set.items[j].original == old { set.items[j].original = new }
            }
        }
        for i in shelves.indices { fix(&shelves[i]) }
        for i in side.indices { fix(&side[i]) }
        for i in categories.indices { fix(&categories[i]) }
        save()
    }

    /// Moves the file into `folder` (the shelf follows it) or copies it there
    /// (the shelf keeps the original). A name already taken there gets " 2",
    /// " 3"… so nothing is overwritten. Returns where it went.
    @discardableResult
    func send(_ item: ShelfItem, to folder: URL, move: Bool) throws -> URL {
        let to = Self.freeName(for: item.url, in: folder) { FileManager.default.fileExists(atPath: $0.path) }
        if move {
            try FileManager.default.moveItem(at: item.url, to: to)
            repoint(from: item.path, to: to.path)
        } else {
            try FileManager.default.copyItem(at: item.url, to: to)
        }
        ShelfDestinations.remember(folder)
        return to
    }

    /// `name.ext` in `folder`, or `name 2.ext`, `name 3.ext`… if taken. Pure (`taken` is asked): tested.
    nonisolated static func freeName(for url: URL, in folder: URL, taken: (URL) -> Bool) -> URL {
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 1
        while true {
            let name = (n == 1 ? base : "\(base) \(n)") + (ext.isEmpty ? "" : "." + ext)
            let to = folder.appendingPathComponent(name)
            if !taken(to) || n > 9999 { return to }
            n += 1
        }
    }

    struct RenameError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The new location for `url` named `base` + its extension. Pure (except
    /// for checking the name is free): tested.
    nonisolated static func renamed(_ url: URL, base: String) throws -> URL {
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { throw RenameError(message: "Type a name first.") }
        guard !b.contains("/"), !b.contains(":") else { throw RenameError(message: "A name can’t contain “/” or “:”.") }
        guard !b.hasPrefix(".") else { throw RenameError(message: "A name starting with “.” would hide the file.") }
        let ext = url.pathExtension
        let name = ext.isEmpty ? b : b + "." + ext
        guard name.utf8.count <= 255 else { throw RenameError(message: "That name is too long.") }
        let to = url.deletingLastPathComponent().appendingPathComponent(name)
        if to.lastPathComponent == url.lastPathComponent { return url }
        // Only a change of capital letters is the same file on most Mac disks: allowed.
        if FileManager.default.fileExists(atPath: to.path), to.path.lowercased() != url.path.lowercased() {
            throw RenameError(message: "There’s already a file called “\(name)” there.")
        }
        return to
    }

    /// Starts an empty shelf; the current one moves to the recent list.
    func newShelf() {
        open = .current
        guard !current.items.isEmpty else { return }
        shelves.insert(ShelfSet(), at: 0)
        save()
    }

    // MARK: Minimize: to the side, or into a category

    /// Shelves kept at the screen edge / in the menu bar (never an empty one).
    var edgeShelves: [ShelfSet] { side.filter { $0.inMenuBar != true && !$0.items.isEmpty } }
    var menuBarShelves: [ShelfSet] { side.filter { $0.inMenuBar == true && !$0.items.isEmpty } }

    /// Puts the shelf on show to the side (or, `menuBar`, into the menu bar's
    /// Shelf tab); the next drag starts a new one.
    func minimizeToSide(menuBar: Bool = false) {
        if open == .current, !current.items.isEmpty {
            var s = current
            s.inMenuBar = menuBar ? true : nil
            side.insert(s, at: 0)
            shelves[0] = ShelfSet()
        }
        open = .current
        save()
    }

    /// After its files were dropped somewhere: the shelf's job is done. The
    /// current shelf closes, like ×, into Recently closed (nothing is put in
    /// the menu bar or a category by itself: only the user puts things there);
    /// a side shelf or category the user kept stays where it is.
    func finishAfterDrop() {
        if open == .current { newShelf() }
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
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = categories.firstIndex(where: { $0.id == id }) {
            if !clean.isEmpty { categories[i].name = clean; save() }
        } else if let i = side.firstIndex(where: { $0.id == id }) {
            side[i].name = clean.isEmpty ? nil : clean; save()     // empty: back to the automatic name
        }
    }

    /// An empty category (Shelves › New Category), e.g. "Work" kept in the menu bar.
    @discardableResult
    func addCategory(named name: String, icon: String? = nil, pinned: Bool = false) -> UUID {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = categories.first(where: { $0.name?.localizedCaseInsensitiveCompare(clean) == .orderedSame }) { return existing.id }
        var c = ShelfSet(name: clean.isEmpty ? "Category \(categories.count + 1)" : clean)
        c.icon = icon; c.pinned = pinned && canPinMore ? true : nil
        categories.append(c)
        save()
        return c.id
    }

    func setLook(_ id: UUID, icon: String?, color: String?) {
        guard let i = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[i].icon = icon; categories[i].color = color
        save()
    }

    /// At most this many categories keep an icon in the menu bar (more would crowd it).
    static let maxPinned = 5

    /// False when pinning would go over `maxPinned`.
    @discardableResult
    func setPinned(_ id: UUID, _ on: Bool) -> Bool {
        guard let i = categories.firstIndex(where: { $0.id == id }) else { return false }
        if on, categories[i].pinned != true, pinnedCategories.count >= Self.maxPinned { return false }
        categories[i].pinned = on ? true : nil
        save()
        return true
    }

    var canPinMore: Bool { pinnedCategories.count < Self.maxPinned }

    /// Categories with their own icon in the menu bar.
    var pinnedCategories: [ShelfSet] { categories.filter { $0.pinned == true } }

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
        FloatingShelf.shared.updateSideHandle()      // nothing left to the side: the edge tab goes
    }

    /// Its × : the shelf leaves the side (or the menu bar) and goes to
    /// Recently closed, like any closed shelf, so it can be opened again.
    func closeSide(_ id: UUID) {
        guard let s = side.first(where: { $0.id == id }) else { return }
        side.removeAll { $0.id == id }
        if !s.items.isEmpty { shelves.insert(s, at: min(1, shelves.count)) }
        if open == .side(id) { open = .current }
        save()
        FloatingShelf.shared.updateSideHandle()
    }

    /// Close All in "To the side".
    func closeAllEdgeShelves() { for s in edgeShelves { closeSide(s.id) } }

    /// Adds files straight into a side shelf or category (dropped on its row).
    @discardableResult
    func add(_ urls: [URL], to target: ShelfTarget) -> Int {
        let previous = open
        open = target
        let n = add(urls)
        open = previous
        return n
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
            // A kept shelf with nothing left on it is gone (no empty chip or edge entry).
            if s.items.isEmpty { side.removeAll { $0.id == id }; open = .current }
            else if let i = side.firstIndex(where: { $0.id == id }) { side[i] = s }
        case .category(let id):
            if let i = categories.firstIndex(where: { $0.id == id }) { categories[i] = s }
        }
        save()
    }

    /// Removes a recent shelf, and any files Apex saved for it (images dropped
    /// without a file). The user's own files are never touched.
    func removeRecent(_ id: UUID) {
        guard let i = shelves.indices.dropFirst().first(where: { shelves[$0].id == id }) else { return }
        let old = shelves.remove(at: i)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(old.id.uuidString, isDirectory: true))
        save()
    }

    func clearRecent() {
        for old in shelves.dropFirst() { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old.id.uuidString, isDirectory: true)) }
        shelves = [current]
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(shelves) { try? d.write(to: file, options: .atomic) }
        if let d = try? JSONEncoder().encode(side) { try? d.write(to: sideFile, options: .atomic) }
        if let d = try? JSONEncoder().encode(categories) { try? d.write(to: categoriesFile, options: .atomic) }
    }
}

/// The last folders files were moved or copied to from a shelf (UserDefaults
/// `shelfDestinations`, newest first, at most 5), offered at the top of the
/// Move To / Copy To menus.
enum ShelfDestinations {
    static let key = "shelfDestinations"
    static var folders: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0.path, isDirectory: &d) && d.boolValue }
    }
    static func remember(_ folder: URL, in d: UserDefaults = .standard) {
        d.set(updated(d.stringArray(forKey: key) ?? [], adding: folder.path), forKey: key)
    }
    /// Newest first, no repeats, at most 5. Pure: tested.
    static func updated(_ list: [String], adding path: String) -> [String] {
        Array(([path] + list.filter { $0 != path }).prefix(5))
    }
}
