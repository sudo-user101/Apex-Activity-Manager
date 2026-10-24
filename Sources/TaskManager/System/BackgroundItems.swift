import AppKit

/// What macOS itself lists in System Settings › General › Login Items, from
/// its Background Task Management database (`sfltool dumpbtm`, no admin
/// needed, about 4 s, so it's read in the background):
///  * apps that **open at login**,
///  * login items, agents and daemons apps registered to run **in the
///    background** (often from inside the app bundle, so they have no plist
///    in a LaunchAgents folder).
/// Older plist agents and daemons are already listed from their folders, so
/// they're skipped here.
struct BTMRecord: Hashable, Sendable {
    enum Kind: String, Sendable { case app, loginItem, agent, daemon, legacy, other }
    var name: String
    var developer: String
    var kind: Kind
    var enabled: Bool
    var url: String             // file:///… for apps; a path inside the parent bundle for embedded items
    var identifier: String      // "2.com.vendor.app"
    var bundleID: String
    var parent: String          // parent's identifier, for embedded items
}

enum BackgroundItems {
    static func read() -> [BTMRecord] {
        guard let out = Shell.capture("/usr/bin/sfltool", ["dumpbtm"]) else { return [] }
        return parse(out, uid: getuid())
    }

    /// Records for this user (and the system), from `sfltool dumpbtm` text.
    static func parse(_ text: String, uid: uid_t) -> [BTMRecord] {
        var out: [BTMRecord] = []
        var inScope = false
        var cur: [String: String] = [:]
        func flush() {
            defer { cur = [:] }
            guard inScope, let type = cur["Type"], let disp = cur["Disposition"] else { return }
            let kind: BTMRecord.Kind
            if type.hasPrefix("legacy") { kind = .legacy }
            else if type.hasPrefix("app") { kind = .app }
            else if type.hasPrefix("login item") { kind = .loginItem }
            else if type.hasPrefix("agent") { kind = .agent }
            else if type.hasPrefix("daemon") { kind = .daemon }
            else { kind = .other }
            func v(_ k: String) -> String { let x = cur[k] ?? ""; return x == "(null)" ? "" : x }
            out.append(BTMRecord(name: v("Name"), developer: v("Developer Name"), kind: kind,
                                 enabled: disp.hasPrefix("[enabled"), url: v("URL"), identifier: v("Identifier"),
                                 bundleID: v("Bundle Identifier"), parent: v("Parent Identifier")))
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") {
                flush()
                let id = line.dropFirst("Records for UID ".count).prefix { $0 != " " }
                inScope = id == "\(uid)" || id == "0"
            } else if line.hasPrefix("#"), line.hasSuffix(":"), line.dropFirst().dropLast().allSatisfy(\.isNumber) {
                flush()
            } else if let colon = line.firstIndex(of: ":"), cur.isEmpty || !line.hasPrefix("#") {
                let key = String(line[..<colon]), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if cur[key] == nil { cur[key] = value }
            }
        }
        flush()
        // The same item can appear in the user's and the system's records.
        var seen = Set<String>()
        return out.filter { seen.insert($0.identifier + $0.url).inserted }
    }

    /// The rows the Startup page adds: open-at-login apps and background items.
    static func startupItems(_ records: [BTMRecord], runningApps: [String: pid_t]) -> [StartupItem] {
        let byID = Dictionary(records.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        return records.compactMap { r in
            switch r.kind {
            case .app where r.enabled:
                let path = URL(string: r.url)?.path ?? ""
                return StartupItem(label: r.bundleID.isEmpty ? r.identifier : r.bundleID, plistPath: "btm:" + r.identifier,
                                   scope: .openAtLogin, enabled: true, running: runningApps[r.bundleID] != nil,
                                   pid: runningApps[r.bundleID], displayName: r.name, vendor: r.developer,
                                   program: path, iconPath: path)
            case .loginItem, .agent, .daemon:
                let parent = byID[r.parent]
                let parentPath = parent.flatMap { URL(string: $0.url)?.path } ?? ""
                let appName = parent?.name ?? ""
                let shortName = r.name.split(separator: ".").last.map(String.init) ?? r.name
                return StartupItem(label: r.bundleID.isEmpty ? r.name : r.bundleID, plistPath: "btm:" + r.identifier,
                                   scope: .background, enabled: r.enabled, running: false, pid: nil,
                                   displayName: appName.isEmpty ? shortName : "\(appName) (\(LabelDecoder.words(shortName)))",
                                   vendor: r.developer.isEmpty ? (parent?.developer ?? "") : r.developer,
                                   program: parentPath.isEmpty ? r.url : parentPath + "/" + r.url, iconPath: parentPath)
            default:
                return nil
            }
        }
    }

    /// Open at Login on/off for an app, through System Events (macOS asks
    /// once for permission to control it). nil on success.
    static func setOpenAtLogin(_ on: Bool, name: String, path: String) -> String? {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = on
            ? "tell application \"System Events\" to make login item at end with properties {path:\"\(esc(path))\", hidden:false}"
            : "tell application \"System Events\" to delete login item \"\(esc(name))\""
        let r = Shell.run("/usr/bin/osascript", ["-e", script])
        if r.status == 0 { return nil }
        if r.stderr.contains("-1743") { return "Apex needs permission to control System Events: System Settings › Privacy & Security › Automation." }
        return r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).ifEmptyMessage("macOS refused the change.")
    }
}

private extension String {
    func ifEmptyMessage(_ s: String) -> String { isEmpty ? s : self }
}
