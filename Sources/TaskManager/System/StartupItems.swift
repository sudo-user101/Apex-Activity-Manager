import AppKit

/// Something that starts automatically: a LaunchAgent / LaunchDaemon plist,
/// an app that opens at login, or a background item an app registered.
struct StartupItem: Identifiable, Hashable, Sendable {
    var id: String { plistPath }
    enum Scope: String, Sendable {
        case user = "Login Agent (you)", allUsers = "Login Agent (all users)", system = "System Daemon"
        case openAtLogin = "Opens at Login", background = "Allowed in Background"
    }

    let label: String
    let plistPath: String
    let scope: Scope
    var enabled: Bool
    var running: Bool
    var pid: pid_t?
    let displayName: String
    let vendor: String
    let program: String
    /// .app bundle used for the icon ("" = generic).
    let iconPath: String

    var isDaemon: Bool { scope == .system }
    /// Added from Apex Activity Manager's "Add App…" (removable here).
    var addedByTaskManager: Bool { label.hasPrefix(StartupItems.ownPrefix) }
    /// Listed by macOS's Login Items database rather than a plist folder.
    var fromLoginItems: Bool { scope == .openAtLogin || scope == .background }
    var statusText: String {
        if scope == .background { return enabled ? "Allowed" : "Not allowed" }
        return enabled ? "Enabled" : "Disabled"
    }
    var enabledSort: Int { enabled ? 1 : 0 }
}

enum StartupItems {
    static let ownPrefix = "com.taskmanager.login."

    /// Makes an app open at login with a per-user LaunchAgent that runs
    /// `open -a <app>`. Needs no extra permissions, shows up in this list
    /// (and in System Settings › Login Items › Allow in the Background), and
    /// can be switched off or removed here.
    static func addLoginApp(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let label = ownPrefix + String(slug)
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        let path = "\(dir)/\(label).plist"
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", url.path],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "AssociatedBundleIdentifiers": Bundle(url: url)?.bundleIdentifier.map { [$0] } ?? [],
        ]
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return error.localizedDescription
        }
        // Make sure it isn't left disabled by an earlier override.
        _ = Shell.run("/bin/launchctl", ["enable", "\(Launchd.guiDomain)/\(label)"])
        return nil
    }

    static func remove(_ item: StartupItem) -> String? {
        guard item.addedByTaskManager else { return "Only items added from Apex Activity Manager can be removed here." }
        _ = Shell.run("/bin/launchctl", ["bootout", "\(Launchd.guiDomain)/\(item.label)"])
        do { try FileManager.default.removeItem(atPath: item.plistPath) } catch { return error.localizedDescription }
        return nil
    }

    /// Reads plists directly (no tool spawned per file).
    static func load() -> [StartupItem] {
        let overrides = Launchd.enabledOverrides()
        let running = Dictionary(Launchd.services().compactMap { s in s.pid.map { (s.label, $0) } }, uniquingKeysWith: { a, _ in a })
        let fm = FileManager.default
        let sources: [(String, StartupItem.Scope)] = [
            (NSHomeDirectory() + "/Library/LaunchAgents", .user),
            ("/Library/LaunchAgents", .allUsers),
            ("/Library/LaunchDaemons", .system),
        ]
        var items: [StartupItem] = []
        for (dir, scope) in sources {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let path = dir + "/" + file
                let plist = (NSDictionary(contentsOfFile: path) as? [String: Any]) ?? [:]
                let fileLabel = String(file.dropLast(6))
                let label = (plist["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fileLabel
                var candidates: [String] = []
                if let p = plist["Program"] as? String { candidates.append(p) }
                if let a = plist["ProgramArguments"] as? [String] { candidates += a }
                let program = candidates.first { $0.hasPrefix("/") } ?? candidates.first ?? ""
                let decoded = LabelDecoder.decode(label)
                var icon = iconBundle(candidates)
                var name = decoded.displayName
                if !icon.isEmpty,
                   candidates.contains(where: { $0.hasPrefix(icon + "/") || $0 == icon }),
                   let bundleName = bundleName(icon) {
                    name = bundleName
                }
                if label.hasPrefix(ownPrefix), let app = candidates.last(where: { $0.hasSuffix(".app") }) {
                    icon = app
                    name = bundleName(app) ?? (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                }
                if icon.isEmpty { icon = LabelDecoder.hintedApp(vendorKey: decoded.vendorKey, text: label) }
                items.append(StartupItem(
                    label: label, plistPath: path, scope: scope,
                    // launchd's override database wins; otherwise the plist's own Disabled key.
                    enabled: overrides[label] ?? overrides[fileLabel] ?? !((plist["Disabled"] as? Bool) ?? false),
                    running: running[label] != nil, pid: running[label],
                    displayName: name, vendor: decoded.vendor, program: program, iconPath: icon))
            }
        }
        return items.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private static func iconBundle(_ paths: [String]) -> String {
        let fm = FileManager.default
        for p in paths {
            // Every ".app" prefix of the path, innermost last; prefer the outermost that exists.
            var search = p.startIndex
            while let r = p.range(of: ".app", range: search..<p.endIndex) {
                let end = r.upperBound
                if end == p.endIndex || p[end] == "/" {
                    let bundle = String(p[..<end])
                    if fm.fileExists(atPath: bundle) { return bundle }
                }
                search = r.upperBound
            }
        }
        return ""
    }

    private static func bundleName(_ bundle: String) -> String? {
        guard let b = Bundle(path: bundle) else { return nil }
        return (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }
}

/// Readable names and icons for launchd jobs, worked out from the system
/// itself: the label's reverse-DNS parts ("com.google.keystone.agent" →
/// maker "google", product "keystone agent"), an installed app whose bundle ID
/// shares the label's prefix, or an app in /Applications named after the maker.
enum LabelDecoder {
    struct Decoded { let vendorKey: String; let vendor: String; let displayName: String }

    /// Top-level reverse-DNS parts that never name a maker.
    static let topLevel: Set<String> = ["com", "org", "net", "io", "co", "dev", "app", "me", "us", "uk", "de", "eu", "tv", "info"]

    static func decode(_ label: String) -> Decoded {
        var parts = label.split(separator: ".").map(String.init)
        if parts.count >= 2, topLevel.contains(parts[0].lowercased()) { parts.removeFirst() }
        guard let makerRaw = parts.first else { return Decoded(vendorKey: "", vendor: "", displayName: label) }
        let maker = installedName(forPrefixOf: label).map { firstWord($0) } ?? words(makerRaw)
        var product = parts.dropFirst().map(words).filter { !$0.isEmpty }.joined(separator: " ")
        if product.lowercased().hasPrefix(maker.lowercased()) {
            product = String(product.dropFirst(maker.count)).trimmingCharacters(in: .whitespaces)
        }
        let name = collapseRepeats([maker, product].filter { !$0.isEmpty }.joined(separator: " "))
        return Decoded(vendorKey: makerRaw.lowercased(), vendor: maker, displayName: name.isEmpty ? label : name)
    }

    /// An app for this job: an installed app whose bundle ID is a prefix of the
    /// label (longest first), else one in /Applications named after the maker.
    static func hintedApp(vendorKey: String, text: String) -> String {
        if let url = appURL(forPrefixOf: text.split(separator: " ").first.map(String.init) ?? text) { return url.path }
        guard vendorKey.count >= 3 else { return "" }
        return applications.first { $0.key.contains(vendorKey) }?.value ?? ""
    }

    // MARK: Helpers

    private static func appURL(forPrefixOf label: String) -> URL? {
        let parts = label.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        for n in stride(from: parts.count, through: 2, by: -1) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.prefix(n).joined(separator: ".")) { return url }
        }
        return nil
    }

    private static func installedName(forPrefixOf label: String) -> String? {
        appURL(forPrefixOf: label).flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String }
    }

    /// Lower-cased app name → path, for apps directly in /Applications (read once).
    private static let applications: [(key: String, value: String)] = {
        let dir = "/Applications"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasSuffix(".app") }.sorted()
            .map { (key: $0.dropLast(4).lowercased().replacingOccurrences(of: " ", with: ""), value: dir + "/" + $0) }
    }()

    private static func firstWord(_ s: String) -> String { String(s.split(separator: " ").first ?? Substring(s)) }

    /// "MyCoolHelper" / "my-cool_helper" → "My Cool Helper"; version-like parts vanish.
    static func words(_ raw: String) -> String {
        if raw.isEmpty || raw.allSatisfy({ $0.isNumber || $0 == "v" || $0 == "V" || $0 == "-" }) { return "" }
        var out = "", prev: Character?
        for ch in raw {
            if ch == "-" || ch == "_" { out.append(" "); prev = " "; continue }
            if let p = prev, p.isLowercase, ch.isUppercase { out.append(" ") }
            out.append(ch); prev = ch
        }
        return out.split(separator: " ").map { w in
            w.count <= 4 && w.allSatisfy({ $0.isUppercase || $0.isNumber }) ? String(w) : w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    private static func collapseRepeats(_ s: String) -> String {
        var out: [Substring] = []
        for w in s.split(separator: " ") where out.last?.lowercased() != w.lowercased() { out.append(w) }
        return out.joined(separator: " ")
    }
}
