import AppKit

/// Removing an app: the app alone, or the app and everything it left in your
/// Library. Files are matched only by the app's bundle identifier (or one of
/// its extensions' identifiers, which start with it) or by the app's exact
/// name, in the folders macOS apps keep their data in. Everything goes to the
/// Trash, so it can be put back.
enum AppRemover {
    struct Leftover: Identifiable, Hashable, Sendable {
        var id: String { path }
        let path: String
        let kind: String           // "Settings", "Caches"…
        var size: UInt64 = 0
        var name: String { (path as NSString).lastPathComponent }
    }

    struct AppInfo: Sendable {
        let path: String
        let name: String
        let bundleID: String
        let isApple: Bool
        let isRunning: Bool
    }

    static func info(_ path: String) -> AppInfo? {
        guard path.hasSuffix(".app"), let b = Bundle(path: path), let id = b.bundleIdentifier else { return nil }
        let name = (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        return AppInfo(path: path, name: name, bundleID: id,
                       isApple: id.hasPrefix("com.apple.") || path.hasPrefix("/System/"), isRunning: running)
    }

    /// Where apps keep per-user data, and what each place holds.
    static let places: [(String, String)] = [
        ("Application Support", "App data"), ("Caches", "Caches"), ("Preferences", "Settings"),
        ("Containers", "App container"), ("Group Containers", "Shared app data"),
        ("Saved Application State", "Saved windows"), ("HTTPStorages", "Web storage"), ("WebKit", "Web data"),
        ("Logs", "Logs"), ("LaunchAgents", "Starts at login"), ("Cookies", "Cookies"),
        ("Application Scripts", "Scripts"), ("Preferences/ByHost", "Settings"),
    ]

    /// Whether a file or folder name belongs to the app. Pure: tested.
    static func belongs(_ name: String, bundleID: String, appName: String) -> Bool {
        let id = bundleID.lowercased(), n = name.lowercased()
        // com.vendor.app and its files: .plist, .savedState, .binarycookies.
        let ext = (n as NSString).pathExtension
        let base = ["plist", "savedstate", "binarycookies"].contains(ext) ? (n as NSString).deletingPathExtension : n
        if base == id { return true }
        // Prefix matches (extensions, helpers, group containers) only for full
        // reverse-DNS ids, so a short id can't catch another vendor's files.
        guard id.split(separator: ".").count >= 3 else { return false }
        if n.hasPrefix(id + ".") { return true }
        // Group containers: "TEAMID.com.vendor.app" or "group.com.vendor.app".
        if n.hasSuffix("." + id) || n.contains("." + id + ".") { return true }
        // Folders named exactly like the app ("Application Support/Slack").
        let plainName = appName.lowercased()
        return plainName.count >= 3 && n == plainName
    }

    /// Everything the app left in this user's Library. Blocking: call off the main thread.
    static func leftovers(for app: AppInfo, home: String = NSHomeDirectory()) -> [Leftover] {
        guard !app.isApple else { return [] }
        var out: [Leftover] = []
        let fm = FileManager.default
        for (dir, kind) in places {
            let base = home + "/Library/" + dir
            for name in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where belongs(name, bundleID: app.bundleID, appName: app.name) {
                // "Preferences/ByHost" is listed on its own; don't count it twice as a folder.
                if dir == "Preferences" && name == "ByHost" { continue }
                let p = base + "/" + name
                out.append(Leftover(path: p, kind: kind, size: FastSize.allocated(p).bytes))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Moves the app (and the given leftovers) to the Trash. Returns what
    /// couldn't be moved.
    static func remove(appPath: String, leftovers: [Leftover]) -> [String] {
        var failed: [String] = []
        for p in [appPath] + leftovers.map(\.path) {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) }
            catch { failed.append((p as NSString).lastPathComponent) }
        }
        return failed
    }
}
