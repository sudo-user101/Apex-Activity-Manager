import AppKit

/// Apps Apex quit to free memory, so they can be reopened the way they were.
///
/// Before quitting, each app's own `NSQuitAlwaysKeepsWindows` preference is
/// turned on, so macOS saves its windows instead of closing them (the same
/// per-app setting as "Close windows when quitting an app" in System
/// Settings). After the app reopens, the previous value is put back.
/// Apps that don't support window restoration reopen without their windows.
struct QuitApp: Codable, Hashable, Sendable {
    var bundleID: String
    var name: String
    var path: String
    var wasHidden: Bool
    var wasFrontmost: Bool
    var keepWindowsBefore: Bool?        // the app's own setting before Apex changed it (nil = not set)
}

struct QuitSession: Codable, Sendable {
    var date: Date
    var apps: [QuitApp]
}

@MainActor
enum AppSession {
    static let key = "quitSession"
    static let keepWindowsKey = "NSQuitAlwaysKeepsWindows" as CFString

    static var last: QuitSession? {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(QuitSession.self, from: $0) } }
        set {
            if let newValue, let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// Quits the apps (normally, so they can ask to save) and remembers them.
    static func quit(_ pids: [pid_t]) {
        var saved: [QuitApp] = []
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier,
                  let url = app.bundleURL else { continue }
            let before = CFPreferencesCopyAppValue(keepWindowsKey, id as CFString) as? Bool
            CFPreferencesSetAppValue(keepWindowsKey, kCFBooleanTrue, id as CFString)
            CFPreferencesAppSynchronize(id as CFString)
            saved.append(QuitApp(bundleID: id, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                 path: url.path, wasHidden: app.isHidden, wasFrontmost: app.isActive, keepWindowsBefore: before))
            app.terminate()
        }
        guard !saved.isEmpty else { return }
        // Several Quit rounds add up until Reopen is used.
        var session = last ?? QuitSession(date: Date(), apps: [])
        session.date = Date()
        session.apps.removeAll { a in saved.contains { $0.bundleID == a.bundleID } }
        session.apps += saved
        last = session
    }

    /// Reopens every remembered app that isn't running, hidden ones hidden,
    /// the one that was in front last (so it ends up in front).
    static func reopen() async -> (opened: [String], failed: [String]) {
        guard let s = last else { return ([], []) }
        var opened: [String] = [], failed: [String] = []
        let ordered = s.apps.filter { !$0.wasFrontmost } + s.apps.filter(\.wasFrontmost)
        for a in ordered {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleID).isEmpty { opened.append(a.name); continue }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = a.wasFrontmost
            cfg.hides = a.wasHidden
            do {
                _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: a.path), configuration: cfg)
                opened.append(a.name)
            } catch { failed.append(a.name) }
        }
        last = nil
        // Give each app time to restore its windows at launch, then put its setting back.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            for a in s.apps { restoreSetting(a) }
        }
        return (opened, failed)
    }

    /// Forget the list without reopening (and put each app's setting back).
    static func discard() {
        for a in last?.apps ?? [] { restoreSetting(a) }
        last = nil
    }

    private static func restoreSetting(_ a: QuitApp) {
        let id = a.bundleID as CFString
        CFPreferencesSetAppValue(keepWindowsKey, a.keepWindowsBefore.map { $0 ? kCFBooleanTrue : kCFBooleanFalse }, id)
        CFPreferencesAppSynchronize(id)
    }
}
