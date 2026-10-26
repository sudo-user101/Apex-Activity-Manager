import AppKit

/// Removing an app: the app alone, or the app and everything it left in your
/// Library. Files are matched only by the app's bundle identifier (or one of
/// its extensions' identifiers, which start with it) or by the app's exact
/// name, in the folders macOS apps keep their data in. Everything goes to the
/// Trash, so it can be put back.
enum AppRemover {
    /// The groups shown in the remove sheet, each with its own tick.
    enum Group: String, CaseIterable, Sendable { case data, system, signIns, documents }

    struct Leftover: Identifiable, Hashable, Sendable {
        var id: String { path }
        /// A file's path; for a sign-in "keychain:…", for an installer record "receipt:…".
        let path: String
        let kind: String           // "Settings", "Caches"…
        var size: UInt64 = 0
        var group: Group = .data
        /// System files outside your home folder: removing them asks for your password.
        var needsAdmin = false
        /// Shown instead of the file name (sign-ins, installer records).
        var label: String? = nil
        var keychain: KeychainRef? = nil
        var name: String { label ?? (path as NSString).lastPathComponent }
        var isFile: Bool { path.hasPrefix("/") }
    }

    /// A saved sign-in in the login keychain (never its password).
    struct KeychainRef: Hashable, Sendable {
        let internet: Bool
        let service: String       // service, or server for website passwords
        let account: String
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
            // Data kept under the company's folder: "Application Support/Google/Chrome"
            // for com.google.Chrome. Only the app's own folder inside, never the company folder.
            if let vendor = vendorName(app.bundleID) {
                for name in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where name.lowercased() == vendor {
                    let vdir = base + "/" + name
                    for sub in (try? fm.contentsOfDirectory(atPath: vdir)) ?? [] where namesApp(sub, app) {
                        let p = vdir + "/" + sub
                        if !out.contains(where: { $0.path == p }) { out.append(Leftover(path: p, kind: kind, size: FastSize.allocated(p).bytes)) }
                    }
                }
            }
            // A folder named like the app's file ("Application Support/Google Chrome").
            let fileName = ((app.path as NSString).lastPathComponent as NSString).deletingPathExtension
            if fileName.count >= 3, fileName.lowercased() != app.name.lowercased() {
                for name in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where name.lowercased() == fileName.lowercased() {
                    let p = base + "/" + name
                    if !out.contains(where: { $0.path == p }) { out.append(Leftover(path: p, kind: kind, size: FastSize.allocated(p).bytes)) }
                }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// "com.google.Chrome" → "google". nil for short ids and Apple's. Pure: tested.
    static func vendorName(_ bundleID: String) -> String? {
        let parts = bundleID.lowercased().split(separator: ".")
        guard parts.count >= 3, parts[1].count >= 3, parts[1] != "apple" else { return nil }
        return String(parts[1])
    }

    /// A folder inside the company folder that is this app's: its short name
    /// ("Chrome") or its file name ("Google Chrome").
    private static func namesApp(_ folder: String, _ app: AppInfo) -> Bool {
        let f = folder.lowercased()
        let file = ((app.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        return (app.name.count >= 3 && f == app.name.lowercased()) || (file.count >= 3 && f == file)
    }

    /// Moves the app (and the given leftovers) to the Trash. Returns what
    /// couldn't be moved.
    static func remove(appPath: String, leftovers: [Leftover]) -> [String] {
        var failed: [String] = []
        // Files in your home folder (and the app): to the Trash.
        for p in [appPath] + leftovers.filter({ $0.isFile && !$0.needsAdmin }).map(\.path) {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) }
            catch { failed.append((p as NSString).lastPathComponent) }
        }
        // System files and installer records: one password prompt for all of them.
        let admin = leftovers.filter { $0.needsAdmin }
        if !admin.isEmpty {
            let r = Shell.runAsAdmin(adminScript(admin, trash: NSHomeDirectory() + "/.Trash"),
                                     prompt: "Apex needs your password to remove the app’s system files.")
            if r.status != 0 { failed += admin.map(\.name) }
        }
        // Saved sign-ins: macOS may ask for your password for each.
        for l in leftovers {
            guard let k = l.keychain else { continue }
            var q: [String: Any] = [kSecClass as String: k.internet ? kSecClassInternetPassword : kSecClassGenericPassword,
                                    kSecAttrAccount as String: k.account]
            q[(k.internet ? kSecAttrServer : kSecAttrService) as String] = k.service
            let s = SecItemDelete(q as CFDictionary)
            if s != errSecSuccess && s != errSecItemNotFound { failed.append(l.name) }
        }
        return failed
    }

    /// The root shell script for system files: background services are stopped
    /// first, files go to your Trash (with the time added so nothing is
    /// overwritten), installer records are forgotten. Pure: tested.
    static func adminScript(_ items: [Leftover], trash: String, stamp: String = "\(Int(Date().timeIntervalSince1970))") -> String {
        var lines: [String] = []
        for l in items {
            if l.path.hasPrefix("receipt:") {
                lines.append("/usr/sbin/pkgutil --forget \(Shell.quote(String(l.path.dropFirst(8)))) >/dev/null 2>&1")
                continue
            }
            if l.path.hasPrefix("/Library/LaunchDaemons/") {
                lines.append("/bin/launchctl bootout system \(Shell.quote(l.path)) >/dev/null 2>&1")
            }
            let name = (l.path as NSString).lastPathComponent
            lines.append("/bin/mv -f \(Shell.quote(l.path)) \(Shell.quote(trash + "/" + name + " " + stamp))")
        }
        return lines.joined(separator: "; ")
    }
}
