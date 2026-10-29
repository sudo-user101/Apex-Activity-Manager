import AppKit
import Carbon.HIToolbox

/// Utilities › Preview-Folder: select a folder in Finder (or just have one
/// open) and press the shortcut: a panel by the pointer shows what's inside,
/// with thumbnails, sizes and what takes the space, without opening it.
/// Settings in UserDefaults `folderPreview` (on / off) and `folderPreviewKey`.

/// One thing in the previewed folder.
struct FolderEntry: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var isFolder: Bool
    var size: UInt64?            // nil while measuring
    var modified: Date?
    var created: Date? = nil
    /// Inside an archive: the archive file, and this item's path in it.
    var archive: String? = nil
    var inner: String? = nil
    /// Finder tags.
    var tags: [String] = []
    var url: URL { URL(fileURLWithPath: path) }
    var isArchive: Bool { !isFolder && archive == nil && ArchiveList.isArchive(url) }
    var isDiskImage: Bool { !isFolder && archive == nil && ArchiveTools.isDiskImage(url) }
    /// Inside an archive, an archive of its own (opened by taking it out first).
    var isNestedArchive: Bool { !isFolder && archive != nil && ArchiveList.isArchive(url) }
    /// Can be opened as a place to look inside (a folder, an archive, a disk image).
    var canEnter: Bool { isFolder || isArchive || isDiskImage || isNestedArchive }
    /// One item's kind, in the singular ("Picture", "Archive"). Pure: tested.
    var kind: String {
        if isFolder { return "Folder" }
        if ArchiveList.isArchive(url) { return "Archive" }
        switch Cloud.kind(of: (name as NSString).pathExtension) {
        case "Videos": return "Video"
        case "Photos": return "Picture"
        case "Music and audio": return "Audio"
        case "Documents": return "Document"
        case "Archives and installers": return "Installer"
        default: return url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased() + " file"
        }
    }
    var sizeSort: UInt64 { size ?? 0 }
    var modifiedSort: Date { modified ?? .distantPast }
    var createdSort: Date { created ?? .distantPast }
}

enum FolderPreview {
    static let enabledKey = "folderPreview"
    static let shortcutKey = "folderPreviewKey"
    static let hotKeyID: UInt32 = 2

    enum Choice: String, CaseIterable, Identifiable {
        case optionCommandP, controlOptionP, controlOptionSpace
        var id: String { rawValue }
        var title: String {
            switch self {
            case .optionCommandP: return "⌥⌘P"
            case .controlOptionP: return "⌃⌥P"
            case .controlOptionSpace: return "⌃⌥Space"
            }
        }
        /// Carbon key code and modifiers. Pure: tested.
        var combo: (code: UInt32, modifiers: UInt32) {
            switch self {
            case .optionCommandP: return (UInt32(kVK_ANSI_P), UInt32(optionKey | cmdKey))
            case .controlOptionP: return (UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey))
            case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
            }
        }
    }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    // MARK: Options (Settings › Utilities › Preview-Folder, and the panel's View menu)

    enum Sort: String, CaseIterable, Identifiable { case size, name, modified, kind
        var id: String { rawValue }
        var title: String { switch self { case .size: "Size"; case .name: "Name"; case .modified: "Date Modified"; case .kind: "Kind" } }
    }
    enum Layout: String, CaseIterable, Identifiable { case list, icons
        var id: String { rawValue }
        var title: String { self == .list ? "List" : "Icons" }
    }
    enum Scale: String, CaseIterable, Identifiable { case small, medium, large
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
    enum Keys {
        static let layout = "folderPreview.view", sort = "folderPreview.sort", foldersOnTop = "folderPreview.foldersOnTop"
        static let showHidden = "folderPreview.showHidden", iconSize = "folderPreview.iconSize", textSize = "folderPreview.textSize"
        static let rows = "folderPreview.rows", window = "folderPreview.window", doubleClickOpens = "folderPreview.doubleClickOpens"
        static let archiveLimit = "folderPreview.archiveLimitMB", skip = "folderPreview.skip", columns = "folderPreview.columns"
        static let revealAfterExtract = "folderPreview.revealAfterExtract", trashAfterExtract = "folderPreview.trashAfterExtract"
        static let extractAsk = "folderPreview.extractAsk", newFormat = "folderPreview.newFormat"
    }

    static func iconPoints(_ s: Scale) -> CGFloat { switch s { case .small: 56; case .medium: 80; case .large: 120 } }
    static func textPoints(_ s: Scale) -> CGFloat { switch s { case .small: 11; case .medium: 13; case .large: 15 } }
    static func rowPadding(_ s: Scale) -> CGFloat { switch s { case .small: 0; case .medium: 3; case .large: 7 } }
    static func windowSize(_ s: Scale) -> CGSize {
        switch s { case .small: CGSize(width: 440, height: 480); case .medium: CGSize(width: 560, height: 580); case .large: CGSize(width: 740, height: 700) }
    }

    /// Folder names not measured (their size isn't added up), e.g. "node_modules". Pure: tested.
    static func skipList(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Sorted for showing: by the chosen column (biggest, newest first; names
    /// A–Z), folders first if asked. Pure: tested.
    static func sorted(_ e: [FolderEntry], by sort: Sort, ascending: Bool? = nil, foldersOnTop: Bool) -> [FolderEntry] {
        let byName: (FolderEntry, FolderEntry) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var out: [FolderEntry]
        switch sort {
        case .size: out = sorted(e); if ascending == true { out.reverse() }
        case .name: out = e.sorted(by: byName); if ascending == false { out.reverse() }
        case .modified: out = e.sorted { $0.modifiedSort != $1.modifiedSort ? $0.modifiedSort > $1.modifiedSort : byName($0, $1) }
            if ascending == true { out.reverse() }
        case .kind: out = e.sorted { $0.kind != $1.kind ? $0.kind < $1.kind : byName($0, $1) }; if ascending == false { out.reverse() }
        }
        if foldersOnTop { out = out.filter(\.isFolder) + out.filter { !$0.isFolder } }
        return out
    }

    /// An archive's level as entries (folder sizes added up). Pure: tested.
    static func entries(archive: URL, at inner: String, items: [ArchiveList.Item]) -> [FolderEntry] {
        ArchiveList.children(of: inner, in: items).map {
            FolderEntry(name: ($0.path as NSString).lastPathComponent, path: archive.path + "/" + $0.path, isFolder: $0.isFolder,
                        size: $0.size, modified: $0.modified, archive: archive.path, inner: $0.path)
        }
    }
    static var choice: Choice { Choice(rawValue: UserDefaults.standard.string(forKey: shortcutKey) ?? "") ?? .optionCommandP }

    /// Registers (or removes) the shortcut. False if another app already uses it.
    @MainActor @discardableResult
    static func apply() -> Bool {
        HotKeyCenter.set(id: hotKeyID, combo: enabled ? choice.combo : nil) { FolderPreviewPanel.shared.toggleForFinder() }
    }

    // MARK: Which folder

    /// What Finder has selected (a folder; for a file, the folder it's in),
    /// else the folder of its front window. Asks Finder through Apple Events
    /// (macOS asks once whether Apex may). NSAppleScript belongs on the main thread; it takes a moment.
    @MainActor static func finderFolder() -> (url: URL?, problem: String?) {
        let script = """
        tell application "Finder"
            set sel to selection
            if (count of sel) > 0 then return POSIX path of ((item 1 of sel) as alias)
            if (count of Finder windows) > 0 then return POSIX path of ((target of front Finder window) as alias)
            return POSIX path of (desktop as alias)
        end tell
        """
        var error: NSDictionary?
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue else {
            let code = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
            return (nil, code == -1743
                    ? "macOS didn’t let Apex ask Finder what’s selected. Allow it under System Settings › Privacy & Security › Automation › Apex Activity Manager › Finder."
                    : "Finder didn’t answer. Select a folder in Finder and try again.")
        }
        return (folder(for: URL(fileURLWithPath: out)), nil)
    }

    /// A folder stays itself; a file (or an app, a package) gives the folder it's in. Pure apart from asking the disk.
    static func folder(for url: URL) -> URL {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists, isDir.boolValue, !NSWorkspace.shared.isFilePackage(atPath: url.path) { return url }
        return url.deletingLastPathComponent()
    }

    // MARK: What's inside

    /// The folder's own items (not inside subfolders), hidden ones left out
    /// and counted. Sizes come later (`measure`). Blocking.
    static func list(_ folder: URL, showHidden: Bool = false) -> (entries: [FolderEntry], hidden: Int) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .creationDateKey, .tagNamesKey,
                                      .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let all = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: []) else { return ([], 0) }
        var hidden = 0
        var out: [FolderEntry] = []
        for u in all {
            if u.lastPathComponent.hasPrefix("."), !showHidden { hidden += 1; continue }
            let v = try? u.resourceValues(forKeys: Set(keys))
            let isFolder = v?.isDirectory == true && v?.isPackage != true
            // A file's size is known at once; a folder (or a package) is measured after.
            let size: UInt64? = v?.isDirectory == true ? nil : UInt64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            out.append(FolderEntry(name: u.lastPathComponent, path: u.path, isFolder: isFolder, size: size, modified: v?.contentModificationDate,
                                   created: v?.creationDate, tags: v?.tagNames ?? []))
        }
        return (sorted(out), hidden)
    }

    /// Biggest first once measured; folders not yet measured after the files, by name. Pure: tested.
    static func sorted(_ e: [FolderEntry]) -> [FolderEntry] {
        e.sorted { a, b in
            switch (a.size, b.size) {
            case let (x?, y?): return x != y ? x > y : a.name.localizedStandardCompare(b.name) == .orderedAscending
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Space on this Mac by kind of file, from the folder's own items
    /// (subfolders count as "Folders"). Pure: tested.
    static func kinds(_ e: [FolderEntry]) -> [(kind: String, bytes: UInt64)] {
        var k: [String: UInt64] = [:]
        for x in e {
            let kind = x.isFolder ? "Folders" : Cloud.kind(of: (x.name as NSString).pathExtension)
            k[kind, default: 0] += x.size ?? 0
        }
        return k.filter { $0.value > 0 }.map { ($0.key, $0.value) }.sorted { $0.bytes > $1.bytes }
    }

    /// "3 folders, 41 files". Pure: tested.
    static func counts(_ e: [FolderEntry]) -> String {
        let folders = e.filter(\.isFolder).count, files = e.count - folders
        if e.isEmpty { return "Empty" }
        let parts = [folders > 0 ? "\(folders) folder\(folders == 1 ? "" : "s")" : nil,
                     files > 0 ? "\(files) file\(files == 1 ? "" : "s")" : nil]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}
