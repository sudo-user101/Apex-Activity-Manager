import AppKit
import Foundation

/// Disk clean-up: caches, logs, developer caches, leftovers, old installers,
/// project build folders and the Trash, each reviewed before anything moves.
/// Safety rules: scan first and show sizes; everything goes to the Trash
/// (recoverable) except emptying the Trash itself; caches of running apps are
/// skipped; "leftovers" only counts data of apps that are no longer installed
/// and never anything from Apple.
struct CleanItem: Identifiable, Sendable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let size: UInt64
    let detail: String
}

struct CleanCategory: Identifiable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case caches, logs, developer, leftovers, installers, projects, trash
    }
    var id: Kind { kind }
    let kind: Kind
    var items: [CleanItem]
    var size: UInt64 { items.reduce(0) { $0 + $1.size } }

    var title: String {
        switch kind {
        case .caches: return "App caches"
        case .logs: return "Logs"
        case .developer: return "Developer caches"
        case .leftovers: return "Leftovers from removed apps"
        case .installers: return "Installers"
        case .projects: return "Project build files"
        case .trash: return "Trash"
        }
    }
    var explanation: String {
        switch kind {
        case .caches: return "Temporary files apps keep to load faster. Apps rebuild them as needed. Running apps are skipped."
        case .logs: return "Diagnostic logs written by apps. Safe to remove."
        case .developer: return "Xcode build data, simulator caches and package-manager caches (npm, pip, Homebrew, CocoaPods, Gradle, Go)."
        case .leftovers: return "Settings and data left behind by apps you’ve already deleted."
        case .installers: return "Disk images and installer packages in Downloads you probably don’t need any more."
        case .projects: return "Rebuildable folders in your code projects: node_modules, build outputs and similar."
        case .trash: return "Items already in the Trash. Emptying it can’t be undone."
        }
    }
    var symbol: String {
        switch kind {
        case .caches: return "archivebox"
        case .logs: return "doc.text"
        case .developer: return "hammer"
        case .leftovers: return "shippingbox"
        case .installers: return "opticaldiscdrive"
        case .projects: return "folder.badge.gearshape"
        case .trash: return "trash"
        }
    }
    /// Pre-ticked when the result is clearly safe.
    var selectedByDefault: Bool { [.caches, .logs, .developer].contains(kind) }
}

enum DiskCleaner {
    static let home = NSHomeDirectory()
    private static let fm = FileManager.default

    static func scan(progress: @escaping @Sendable (CleanCategory.Kind) -> Void) -> [CleanCategory] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).map { $0.lowercased() })
        let kinds = CleanCategory.Kind.allCases
        let results = UnsafeMutableBufferPointer<CleanCategory?>.allocate(capacity: kinds.count)
        results.initialize(repeating: nil)
        defer { _ = results.deinitialize(); results.deallocate() }   // deinitialize, or the item arrays leak
        // Categories are independent, so size them in parallel.
        DispatchQueue.concurrentPerform(iterations: kinds.count) { idx in
            let kind = kinds[idx]
            progress(kind)
            let items: [CleanItem]
            switch kind {
            case .caches: items = caches(skipping: running)
            case .logs: items = children(of: home + "/Library/Logs", detail: "Logs")
            case .developer: items = developer()
            case .leftovers: items = leftovers()
            case .installers: items = installers()
            case .projects: items = projects()
            case .trash: items = children(of: home + "/.Trash", detail: "In Trash")
            }
            results[idx] = CleanCategory(kind: kind, items: items.filter { $0.size > 0 }.sorted { $0.size > $1.size })
        }
        return results.compactMap { $0 }
    }

    // MARK: Categories

    private static let developerCachePaths: [(String, String)] = [
        ("/Library/Developer/Xcode/DerivedData", "Xcode build data"),
        ("/Library/Developer/Xcode/iOS DeviceSupport", "Xcode device support"),
        ("/Library/Developer/Xcode/watchOS DeviceSupport", "Xcode device support"),
        ("/Library/Developer/CoreSimulator/Caches", "Simulator caches"),
        ("/Library/Caches/Homebrew", "Homebrew downloads"),
        ("/Library/Caches/pip", "pip cache"),
        ("/Library/Caches/CocoaPods", "CocoaPods cache"),
        ("/Library/Caches/go-build", "Go build cache"),
        ("/Library/Caches/Yarn", "Yarn cache"),
        ("/Library/Caches/pnpm", "pnpm cache"),
        ("/.npm/_cacache", "npm cache"),
        ("/.gradle/caches", "Gradle cache"),
        ("/.cache/huggingface/xet", "Hugging Face download cache"),
    ]

    private static func developer() -> [CleanItem] {
        developerCachePaths.compactMap { rel, label in
            let p = home + rel
            guard fm.fileExists(atPath: p) else { return nil }
            return CleanItem(path: p, name: label, size: size(of: p), detail: "~" + rel)
        }
    }

    private static func caches(skipping running: Set<String>) -> [CleanItem] {
        let dev = Set(developerCachePaths.map { home + $0.0 })
        let mine = (Bundle.main.bundleIdentifier ?? "").lowercased()
        return children(of: home + "/Library/Caches", detail: "Cache").filter { item in
            let n = (item.path as NSString).lastPathComponent.lowercased()
            if dev.contains(item.path) || n == mine { return false }
            // Skip caches belonging to running apps (by bundle id prefix).
            return !running.contains(where: { n == $0 || n.hasPrefix($0 + ".") })
        }
    }

    /// Containers / Application Support / Saved State for bundle IDs whose
    /// app is no longer installed (Launch Services can't find it).
    private static func leftovers() -> [CleanItem] {
        var out: [CleanItem] = []
        var known: [String: Bool] = [:]
        func installed(_ id: String) -> Bool {
            if let k = known[id] { return k }
            let v = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            known[id] = v
            return v
        }
        func isRemovedApp(_ id: String) -> Bool {
            let l = id.lowercased()
            let parts = id.split(separator: ".")
            // Must look like a real bundle id (reverse-DNS, 3+ parts), never Apple's.
            guard parts.count >= 3, !id.hasPrefix("."), !l.hasPrefix("com.apple."), !l.hasPrefix("group."),
                  !l.hasPrefix("systemgroup."), parts.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } })
            else { return false }
            // Extensions / widgets / helpers use the parent app's id as a prefix
            // (com.nextcloud.desktopclient.FileProviderExt): keep them if any
            // prefix belongs to an installed app.
            for n in stride(from: parts.count, through: 2, by: -1) {
                if installed(parts.prefix(n).joined(separator: ".")) { return false }
            }
            // Also keep it if a running process uses that id prefix.
            let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            if running.contains(where: { l.hasPrefix($0.lowercased()) || $0.lowercased().hasPrefix(l) }) { return false }
            return true
        }
        for (dir, suffix, label) in [("/Library/Containers", "", "App container"),
                                     ("/Library/Saved Application State", ".savedState", "Saved window state"),
                                     ("/Library/Application Support", "", "App data"),
                                     ("/Library/HTTPStorages", "", "Web storage"),
                                     ("/Library/WebKit", "", "Web data")] {
            let base = home + dir
            for name in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
                let id = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
                guard (suffix.isEmpty || name.hasSuffix(suffix)), isRemovedApp(id) else { continue }
                let p = base + "/" + name
                out.append(CleanItem(path: p, name: id, size: size(of: p), detail: label))
            }
        }
        return out
    }

    private static func installers() -> [CleanItem] {
        let dl = home + "/Downloads"
        let exts = ["dmg", "pkg", "mpkg", "iso", "xip"]
        return ((try? fm.contentsOfDirectory(atPath: dl)) ?? []).compactMap { name in
            guard exts.contains((name as NSString).pathExtension.lowercased()) else { return nil }
            let p = dl + "/" + name
            let date = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date
            return CleanItem(path: p, name: name, size: size(of: p),
                             detail: date.map { "Downloaded " + $0.formatted(.relative(presentation: .named)) } ?? "Downloads")
        }
    }

    /// node_modules etc. in common code folders (2 levels of projects deep).
    private static func projects() -> [CleanItem] {
        let roots = ["/Developer", "/Projects", "/Code", "/code", "/src", "/Documents/GitHub", "/Documents/Projects", "/repos"]
            .map { home + $0 }.filter { fm.fileExists(atPath: $0) }
        let targets: [(String, String?)] = [("node_modules", "package.json"), (".next", "package.json"), (".turbo", nil),
                                             ("target", "Cargo.toml"), (".build", "Package.swift"), ("Pods", "Podfile"),
                                             (".gradle", nil), ("__pycache__", nil), (".venv", nil)]
        var out: [CleanItem] = []
        func visit(_ dir: String, depth: Int) {
            guard depth <= 4, let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for e in entries {
                let p = dir + "/" + e
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
                if let t = targets.first(where: { $0.0 == e }) {
                    if t.1 == nil || fm.fileExists(atPath: dir + "/" + t.1!) {
                        out.append(CleanItem(path: p, name: (dir as NSString).lastPathComponent + "/" + e,
                                             size: size(of: p), detail: (dir as NSString).abbreviatingWithTildeInPath))
                    }
                    continue
                }
                if e.hasPrefix(".") || e == "Library" { continue }
                visit(p, depth: depth + 1)
            }
        }
        roots.forEach { visit($0, depth: 0) }
        return out
    }

    // MARK: Helpers

    private static func children(of dir: String, detail: String) -> [CleanItem] {
        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0 != ".DS_Store" }
        let paths = names.map { dir + "/" + $0 }
        let sizes = FastSize.allocated(paths)        // in parallel
        return names.indices.map { CleanItem(path: paths[$0], name: names[$0], size: sizes[$0], detail: detail) }
    }

    static func size(of path: String) -> UInt64 { FastSize.allocated(path).bytes }

    /// Moves items to the Trash (recoverable). Returns (freed bytes, failures).
    static func trash(_ items: [CleanItem]) -> (UInt64, [String]) {
        var freed: UInt64 = 0, failed: [String] = []
        for i in items {
            do { try fm.trashItem(at: URL(fileURLWithPath: i.path), resultingItemURL: nil); freed += i.size }
            catch { failed.append(i.name) }
        }
        return (freed, failed)
    }

    /// Permanently deletes the Trash contents (asks first in the UI).
    static func emptyTrash(_ items: [CleanItem]) -> (UInt64, [String]) {
        var freed: UInt64 = 0, failed: [String] = []
        for i in items {
            do { try fm.removeItem(atPath: i.path); freed += i.size } catch { failed.append(i.name) }
        }
        return (freed, failed)
    }
}
