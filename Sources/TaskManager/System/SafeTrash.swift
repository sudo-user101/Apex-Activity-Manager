import AppKit
import Foundation
import ProcessIdentityCore

/// Moving things to the Trash so they're really gone once it's emptied:
/// - apps (and folders with apps in them) are quit first, with every helper
///   running from inside them, and their launch agents are unloaded, so no
///   menu bar icon or background process is left behind;
/// - what macOS won't let you move (owned by the system or another user) is
///   moved with your administrator password, in one prompt, into your Trash
///   and made yours, so emptying the Trash works;
/// - what System Integrity Protection guards (Apple's own apps, /System) is
///   explained instead: no app can remove it, not even as administrator.
enum SafeTrash {
    struct Outcome: Sendable {
        var moved: [String] = []
        /// Where each moved item now is in the Trash (when macOS says).
        var trashed: [URL] = []
        var failed: [(name: String, why: String)] = []
        var cancelled = false
        /// Deleted for good (apps), not moved to the Trash.
        var deleted = false
        var message: String {
            let done = deleted ? "Deleted" : "Moved", place = deleted ? "" : " to the Trash"
            if failed.isEmpty { return moved.count == 1 ? "\(done) “\(moved[0])”\(place)." : "\(done) \(moved.count) items\(place)." }
            let list = failed.map { "“\($0.name)”: \($0.why)" }.joined(separator: "\n")
            return (moved.isEmpty ? "" : "\(done) \(moved.count)\(place). ") + (deleted ? "Not deleted:\n" : "Not moved:\n") + list
        }
    }

    /// macOS itself guards these; nothing can remove them. Pure: tested.
    static func isProtected(_ path: String) -> Bool {
        if path.hasPrefix("/System/") || path == "/System" { return true }
        for p in ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/lib/", "/usr/libexec/"] where path.hasPrefix(p) { return true }
        var st = stat()
        if lstat(path, &st) == 0, st.st_flags & UInt32(SF_RESTRICTED) != 0 { return true }
        return false
    }

    /// Apps (`.app` bundles) at or inside `path`, so a folder of apps is handled too.
    static func apps(in path: String) -> [String] {
        if path.hasSuffix(".app") { return [path] }
        var out: [String] = []
        guard let e = FileManager.default.enumerator(atPath: path) else { return out }
        while let rel = e.nextObject() as? String {
            if rel.hasSuffix(".app") { out.append(path + "/" + rel); e.skipDescendants() }
            if out.count > 200 { break }
        }
        return out
    }

    /// The bundle IDs of these apps (from their Info.plist): a running app is
    /// found by its ID even when its path can't be read or has moved.
    nonisolated static func bundleIDs(_ apps: [String]) -> Set<String> {
        Set(apps.compactMap { Bundle(path: $0)?.bundleIdentifier })
    }

    /// Everything running from these apps: by path (the kernel), by the
    /// system's list of apps (path or bundle ID), and processes macOS holds
    /// one of them responsible for (helpers). Each by identity.
    @MainActor
    static func runningApps(_ apps: [String]) -> [(id: ProcessIdentity, name: String)] {
        func inside(_ p: String?) -> Bool { guard let p else { return false }; return apps.contains { p == $0 || p.hasPrefix($0 + "/") } }
        let ids = bundleIDs(apps)
        var out: [pid_t: (ProcessIdentity, String)] = [:]
        for p in running(under: apps) { out[p.id.pid] = (p.id, p.name) }
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated
            && (inside(app.bundleURL?.path) || inside(app.executableURL?.path) || ids.contains(app.bundleIdentifier ?? "\u{0}")) {
            if let id = ProcessIdentity.current(app.processIdentifier) { out[id.pid] = (id, app.localizedName ?? "app") }
        }
        // Helpers macOS counts as the app's (they can sit outside the bundle).
        let main = Set(out.keys)
        if !main.isEmpty {
            let count = proc_listallpids(nil, 0)
            var pids = [pid_t](repeating: 0, count: max(0, Int(count)) + 64)
            let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            for pid in pids.prefix(Int(max(0, n))) where pid > 1 && pid != getpid() && out[pid] == nil {
                if let r = AppAudio.responsiblePID(pid), main.contains(r), let id = ProcessIdentity.current(pid) { out[pid] = (id, "helper") }
            }
        }
        return Array(out.values)
    }

    /// Quits everything running from these apps: asked politely first (they
    /// can save), then ended, then forced; each step only on the exact
    /// processes found (by identity). Launch agents that would start them
    /// again are unloaded. Returns the names still running.
    @MainActor
    static func quitApps(_ apps: [String], patience: TimeInterval = 4) async -> [String] {
        unloadAgents(pointingInto: apps)
        let ids = bundleIDs(apps)
        func inside(_ p: String?) -> Bool { guard let p else { return false }; return apps.contains { p == $0 || p.hasPrefix($0 + "/") } }
        for app in NSWorkspace.shared.runningApplications
        where inside(app.bundleURL?.path) || inside(app.executableURL?.path) || ids.contains(app.bundleIdentifier ?? "\u{0}") {
            app.terminate()
        }
        func wait(_ seconds: TimeInterval) async -> [(id: ProcessIdentity, name: String)] {
            let start = Date()
            var left = runningApps(apps)
            while !left.isEmpty, Date().timeIntervalSince(start) < seconds {
                try? await Task.sleep(for: .milliseconds(300))
                left = runningApps(apps)
            }
            return left
        }
        var left = await wait(patience)
        if left.isEmpty { return [] }
        for p in left { _ = ProcessSignal.send(SIGTERM, to: p.id) }       // ended
        left = await wait(2)
        if left.isEmpty { return [] }
        for p in left { _ = ProcessSignal.send(SIGKILL, to: p.id) }       // forced: you chose to delete it
        left = await wait(2)
        return Array(Set(left.map(\.name))).sorted()
    }

    /// Quits everything running from inside these paths (apps in a folder
    /// being moved to the Trash). Returns, per path, the names still running.
    @MainActor
    static func quitEverything(under paths: [String], timeout: TimeInterval = 6) async -> [String: [String]] {
        var still: [String: [String]] = [:]
        for p in paths {
            let left = await quitApps([p], patience: timeout / 2)
            if !left.isEmpty { still[p] = left }
        }
        return still
    }

    /// The path with links resolved (/var → /private/var); unchanged if it can't be.
    nonisolated static func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    /// Processes whose program is inside these paths, straight from the
    /// kernel (not the last sample, which can be a second old).
    nonisolated static func running(under given: [String]) -> [(id: ProcessIdentity, path: String, name: String)] {
        // The kernel reports real paths (/private/var/…, not /var/…): compare those.
        let paths = given.map(realPath)
        func inside(_ p: String) -> Bool { paths.contains { p == $0 || p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [(ProcessIdentity, String, String)] = []
        var buf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(max(0, n))) where pid > 1 && pid != getpid() {
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let path = String(cString: buf)
            guard inside(path), let id = ProcessIdentity.current(pid) else { continue }
            // Reported under the path the caller gave, so it matches their list.
            let shown = zip(paths, given).first { path == $0.0 || path.hasPrefix($0.0 + "/") }.map { $0.1 + path.dropFirst($0.0.count) } ?? path
            out.append((id, shown, (path as NSString).lastPathComponent))
        }
        return out
    }

    /// `launchctl bootout` for the user's launch agents whose program is inside these paths.
    static func unloadAgents(pointingInto paths: [String]) {
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for f in files where f.hasSuffix(".plist") {
            let plist = dir + "/" + f
            guard let d = NSDictionary(contentsOfFile: plist) else { continue }
            let program = (d["Program"] as? String) ?? ((d["ProgramArguments"] as? [String])?.first ?? "")
            if paths.contains(where: { program.hasPrefix($0) }) {
                _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", plist])
            }
        }
    }

    /// Moves `paths` to the Trash: apps quit first; what needs it, with one
    /// administrator prompt; protected items explained.
    @MainActor
    static func move(_ paths: [String]) async -> Outcome {
        var out = Outcome()
        let appPaths = paths.flatMap { Self.apps(in: $0) }
        let stillRunning = appPaths.isEmpty ? [:] : await quitEverything(under: appPaths)

        var needAdmin: [String] = []
        for p in paths {
            let name = (p as NSString).lastPathComponent
            if isProtected(p) { out.failed.append((name, "macOS protects it (System Integrity Protection); no app can remove it.")); continue }
            // An app at or inside this path that didn't quit: leave it (moving a running app leaves it running).
            let running = stillRunning.filter { $0.key == p || $0.key.hasPrefix(p + "/") }.flatMap { $0.value }
            if !running.isEmpty {
                out.failed.append((name, "still running and didn’t quit (" + Array(Set(running)).sorted().joined(separator: ", ") + "). Quit it, then try again."))
                continue
            }
            do {
                var to: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &to)
                out.moved.append(name)
                if let to { out.trashed.append(to as URL) }
            }
            catch let e as CocoaError where e.code == .fileWriteNoPermission || e.code == .fileReadNoPermission { needAdmin.append(p) }
            catch let e as NSError where e.code == NSFileWriteNoPermissionError || e.domain == NSPOSIXErrorDomain && (e.code == Int(EACCES) || e.code == Int(EPERM)) { needAdmin.append(p) }
            catch { out.failed.append((name, error.localizedDescription)) }
        }
        if !needAdmin.isEmpty {
            let script = adminScript(needAdmin, trash: NSHomeDirectory() + "/.Trash", user: NSUserName())
            let r = await Task.detached { Shell.runAsAdmin(script, prompt: "Apex needs your password to move items that belong to the system or another user to your Trash.") }.value
            if Shell.isUserCancelled(r) {
                out.cancelled = true
                out.failed += needAdmin.map { (($0 as NSString).lastPathComponent, "it needs your administrator password (cancelled).") }
            } else {
                for p in needAdmin {
                    let name = (p as NSString).lastPathComponent
                    if FileManager.default.fileExists(atPath: p) { let why = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        out.failed.append((name, why.isEmpty ? "macOS didn’t allow it." : why)) }
                    else { out.moved.append(name) }
                }
            }
        }
        return out
    }

    /// Apps are deleted for good (you confirm first): quit with every helper,
    /// then removed, with the administrator password when macOS asks for it.
    /// Apps macOS protects are explained. Nothing that isn't a `.app` is
    /// touched here.
    @MainActor
    static func deleteApps(_ paths: [String]) async -> Outcome {
        var out = Outcome(deleted: true)
        var needAdmin: [String] = []
        for p in paths {
            let name = (p as NSString).lastPathComponent
            guard p.hasSuffix(".app"), p.split(separator: "/").count >= 2 else { out.failed.append((name, "isn’t an app.")); continue }
            if isProtected(p) { out.failed.append((name, "macOS protects it (System Integrity Protection); no app can remove it.")); continue }
            let still = await quitApps([p])
            if !still.isEmpty {
                out.failed.append((name, "is still running and couldn’t be quit (" + still.joined(separator: ", ") + ")."))
                continue
            }
            do { try FileManager.default.removeItem(atPath: p); out.moved.append(name) }
            catch let e as NSError where e.code == NSFileWriteNoPermissionError || e.domain == NSPOSIXErrorDomain && (e.code == Int(EACCES) || e.code == Int(EPERM))
                || (e.underlyingErrors.first as NSError?).map { $0.code == Int(EACCES) || $0.code == Int(EPERM) } == true { needAdmin.append(p) }
            catch { out.failed.append((name, error.localizedDescription)) }
        }
        if !needAdmin.isEmpty {
            let script = needAdmin.map { "/bin/rm -rf " + Shell.quote($0) }.joined(separator: "; ")
            let r = await Task.detached { Shell.runAsAdmin(script, prompt: "Apex needs your password to delete apps that belong to the system or another user.") }.value
            for p in needAdmin {
                let name = (p as NSString).lastPathComponent
                if Shell.isUserCancelled(r) { out.cancelled = true; out.failed.append((name, "it needs your administrator password (cancelled).")) }
                else if FileManager.default.fileExists(atPath: p) {
                    let why = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    out.failed.append((name, why.isEmpty ? "macOS didn’t allow it." : why))
                } else { out.moved.append(name) }
            }
        }
        return out
    }

    /// The root script: each item into the user's Trash (a time added so
    /// nothing is overwritten), then made the user's own so emptying the
    /// Trash needs no password. Pure: tested.
    static func adminScript(_ paths: [String], trash: String, user: String, stamp: String = "\(Int(Date().timeIntervalSince1970))") -> String {
        paths.map { p in
            let name = (p as NSString).lastPathComponent
            let dest = trash + "/" + name + " " + stamp
            return "/bin/mv -f \(Shell.quote(p)) \(Shell.quote(dest)) && /usr/sbin/chown -R \(Shell.quote(user)) \(Shell.quote(dest))"
        }.joined(separator: "; ")
    }
}
