import Foundation
import Security

/// Everything else that belongs to an app, beyond its data in your Library:
/// system helpers and background services, installer records, saved
/// sign-ins and files you made with it. Each is matched by the app's own
/// identifiers (bundle ID, the program a service starts), never by guesswork
/// on a company name alone. Blocking: call off the main thread.
extension AppRemover {
    /// The developer team that signed the app ("EQHXZ8M8AV"), from its code signature.
    static func teamID(_ appPath: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: appPath) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        return d[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Background services, helper tools and data outside your home folder.
    static func systemItems(for app: AppInfo, root: String = "") -> [Leftover] {
        guard !app.isApple else { return [] }
        let fm = FileManager.default
        var out: [Leftover] = []
        func add(_ p: String, _ kind: String) {
            guard !out.contains(where: { $0.path == p }) else { return }
            out.append(Leftover(path: p, kind: kind, size: FastSize.allocated(p).bytes, group: .system,
                                needsAdmin: !fm.isWritableFile(atPath: (p as NSString).deletingLastPathComponent)))
        }
        // Background services: by their label, or because they start a program inside the app.
        for (dir, kind) in [("/Library/LaunchDaemons", "Background service"), ("/Library/LaunchAgents", "Starts at login (all users)")] {
            for name in (try? fm.contentsOfDirectory(atPath: root + dir)) ?? [] where name.hasSuffix(".plist") {
                let p = root + dir + "/" + name
                if belongs(name, bundleID: app.bundleID, appName: app.name) || startsProgram(p, inside: app.path) { add(p, kind) }
            }
        }
        // Helper tools installed with administrator rights.
        for name in (try? fm.contentsOfDirectory(atPath: root + "/Library/PrivilegedHelperTools")) ?? []
        where belongs(name, bundleID: app.bundleID, appName: app.name) {
            add(root + "/Library/PrivilegedHelperTools/" + name, "Helper tool")
        }
        // Shared data for all users: same rules as in your Library.
        for (dir, kind) in [("Application Support", "App data (all users)"), ("Caches", "Caches (all users)"),
                            ("Preferences", "Settings (all users)"), ("Logs", "Logs (all users)")] {
            let base = root + "/Library/" + dir
            for name in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where belongs(name, bundleID: app.bundleID, appName: app.name) {
                add(base + "/" + name, kind)
            }
            if let vendor = vendorName(app.bundleID) {
                for name in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where name.lowercased() == vendor {
                    for sub in (try? fm.contentsOfDirectory(atPath: base + "/" + name)) ?? []
                    where sub.lowercased() == app.name.lowercased() || sub.lowercased() == fileName(app).lowercased() {
                        add(base + "/" + name + "/" + sub, kind)
                    }
                }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Whether a launchd plist starts a program inside the app bundle.
    static func startsProgram(_ plist: String, inside appPath: String) -> Bool {
        guard let d = NSDictionary(contentsOfFile: plist) as? [String: Any] else { return false }
        let program = d["Program"] as? String ?? (d["ProgramArguments"] as? [String])?.first ?? ""
        return !program.isEmpty && (program == appPath || program.hasPrefix(appPath + "/"))
    }

    /// Installer records (`pkgutil --pkgs`) whose id is the app's or one of its parts'.
    static func receipts(for app: AppInfo) -> [Leftover] {
        guard !app.isApple, let out = Shell.capture("/usr/sbin/pkgutil", ["--pkgs"]) else { return [] }
        return matchingReceipts(out.split(separator: "\n").map(String.init), app).map {
            Leftover(path: "receipt:" + $0, kind: "Installer record", group: .system, needsAdmin: true, label: $0)
        }
    }

    /// Pure: tested.
    static func matchingReceipts(_ ids: [String], _ app: AppInfo) -> [String] {
        ids.filter { belongs($0, bundleID: app.bundleID, appName: app.name) }
    }

    /// Saved sign-ins whose name is the app's: its bundle ID, or its name as a
    /// whole word ("Chrome Safe Storage"). Only names are read, never passwords.
    static func signIns(for app: AppInfo) -> [Leftover] {
        guard !app.isApple else { return [] }
        var out: [Leftover] = []
        for internet in [false, true] {
            let q: [String: Any] = [kSecClass as String: internet ? kSecClassInternetPassword : kSecClassGenericPassword,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
            var res: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &res) == errSecSuccess, let items = res as? [[String: Any]] else { continue }
            for a in items {
                let service = (a[(internet ? kSecAttrServer : kSecAttrService) as String] as? String) ?? ""
                let label = (a[kSecAttrLabel as String] as? String) ?? service
                let account = (a[kSecAttrAccount as String] as? String) ?? ""
                guard signInBelongs(service: service, label: label, app) else { continue }
                let ref = KeychainRef(internet: internet, service: service, account: account)
                let id = "keychain:\(internet ? "i" : "g"):\(service):\(account)"
                guard !out.contains(where: { $0.path == id }) else { continue }
                out.append(Leftover(path: id, kind: account.isEmpty ? "Saved sign-in" : "Saved sign-in · \(account)",
                                    group: .signIns, label: label, keychain: ref))
            }
        }
        return out
    }

    /// Pure: tested.
    static func signInBelongs(service: String, label: String, _ app: AppInfo) -> Bool {
        let id = app.bundleID.lowercased()
        for text in [service.lowercased(), label.lowercased()] {
            if text == id || text.hasPrefix(id + ".") || text.hasPrefix(id + " ") { return true }
            for name in [app.name, fileName(app)] where name.count >= 4 {
                let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                let nameWords = name.lowercased().split(separator: " ").map(String.init)
                // The whole name, as words, at the start: "Chrome Safe Storage", "Slack", not "chromecast".
                if words.starts(with: nameWords) { return true }
            }
        }
        return false
    }

    /// Files you made with the app: document types it says it owns (or
    /// defined itself), found with Spotlight in your home folder, outside
    /// Library. Your own work, so never ticked by default.
    static func documents(for app: AppInfo, limit: Int = 300) -> [Leftover] {
        guard !app.isApple, let types = ownedTypes(app.path), !types.isEmpty else { return [] }
        let query = types.map { "kMDItemContentType == '\($0)'" }.joined(separator: " || ")
        guard let out = Shell.capture("/usr/bin/mdfind", ["-onlyin", NSHomeDirectory(), query], allowFailure: true) else { return [] }
        let lib = NSHomeDirectory() + "/Library/"
        return out.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix(lib) && !$0.hasPrefix(app.path) }
            .prefix(limit)
            .map { Leftover(path: $0, kind: "Made with \(app.name)", size: FastSize.allocated($0).bytes, group: .documents) }
            .sorted { $0.size > $1.size }
    }

    /// Content types the app owns (`LSHandlerRank` Owner) or declares itself.
    static func ownedTypes(_ appPath: String) -> [String]? {
        guard let info = Bundle(path: appPath)?.infoDictionary else { return nil }
        return ownedTypes(info)
    }

    /// Pure: tested.
    static func ownedTypes(_ info: [String: Any]) -> [String] {
        var types = Set<String>()
        for d in (info["CFBundleDocumentTypes"] as? [[String: Any]]) ?? [] where (d["LSHandlerRank"] as? String) == "Owner" {
            for t in (d["LSItemContentTypes"] as? [String]) ?? [] where !t.hasPrefix("public.") && !t.hasPrefix("com.apple.") { types.insert(t) }
        }
        for d in (info["UTExportedTypeDeclarations"] as? [[String: Any]]) ?? [] {
            if let t = d["UTTypeIdentifier"] as? String, !t.hasPrefix("public."), !t.hasPrefix("com.apple.") { types.insert(t) }
        }
        return types.sorted()
    }

    static func fileName(_ app: AppInfo) -> String {
        ((app.path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
