import AppKit
import Security
import ApplicationServices
import CoreBluetooth
import ServiceManagement
import UserNotifications

/// Everything Apex may need permission for, in one place (first launch and
/// Settings). Each item says what it's for, whether it's granted, and how to
/// grant it: asked right here where macOS allows it, otherwise the exact
/// System Settings switch is opened.
enum Permission: String, CaseIterable, Identifiable {
    case notifications, accessibility, automation, screenRecording, fullDisk, bluetooth, openAtLogin, helper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifications: return "Notifications"
        case .fullDisk: return "Full Disk Access"
        case .bluetooth: return "Bluetooth"
        case .accessibility: return "Accessibility"
        case .automation: return "Control Finder"
        case .screenRecording: return "Screen Recording"
        case .openAtLogin: return "Open at Login"
        case .helper: return "Battery and Fan Helper"
        }
    }

    var symbol: String {
        switch self {
        case .notifications: return "bell.badge"
        case .fullDisk: return "externaldrive.badge.checkmark"
        case .bluetooth: return "wave.3.right"
        case .accessibility: return "accessibility"
        case .automation: return "folder.badge.gearshape"
        case .screenRecording: return "rectangle.on.rectangle"
        case .openAtLogin: return "power"
        case .helper: return "battery.100.bolt"
        }
    }

    var why: String {
        switch self {
        case .notifications: return "Alerts when an app runs away with the CPU, memory runs low, the disk fills up, or a cloud offload finishes."
        case .fullDisk: return "So Disk › Analyze and Clean can measure every folder (Mail, Safari and others are hidden from apps without it)."
        case .bluetooth: return "To show your connected Bluetooth accessories and their battery."
        case .accessibility: return "For the features that move windows or act on keys: Window Manager, Clean Keyboard, the Dock and keyboard and mouse behaviours in MacOSX Change, and play / pause from the menu bar. Apex never records or stores what you type."
        case .screenRecording: return "Only for the App Switcher’s live window previews. Without it, each window shows its app’s icon and title. Nothing is recorded or saved."
        case .automation: return "So Preview-Folder knows which folder is selected in Finder, and a copied picture can be pasted into the Finder window you’re in. Apex only asks Finder what’s selected."
        case .openAtLogin: return "Keeps the menu bar monitor, alerts, clipboard history and Stay Awake running from the moment you log in."
        case .helper: return "Charge limit, charge schedules, night charging, fan control and lid-closed Stay Awake. Installed once with your password."
        }
    }

    var optional: Bool { self != .notifications }
}

@MainActor @Observable
final class PermissionCenter {
    static let shared = PermissionCenter()
    private(set) var granted: [Permission: Bool] = [:]
    /// Notifications were asked about and answered (allowed or not).
    private(set) var notificationsAnswered = false

    func refresh() {
        granted[.fullDisk] = Self.hasFullDiskAccess()
        granted[.bluetooth] = CBManager.authorization == .allowedAlways
        granted[.accessibility] = MediaKeys.allowed
        Task.detached { let ok = Self.finderAutomation(ask: false); await MainActor.run { PermissionCenter.shared.granted[.automation] = ok } }
        granted[.openAtLogin] = SMAppService.mainApp.status == .enabled
        granted[.helper] = FanController.shared.installed
        granted[.screenRecording] = CGPreflightScreenCaptureAccess()
        // Notifications exist only for a real app bundle (not tests or the bare binary).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            let answered = s.authorizationStatus != .notDetermined
            Task { @MainActor in
                PermissionCenter.shared.granted[.notifications] = ok
                PermissionCenter.shared.notificationsAnswered = answered
            }
        }
    }

    /// Full Disk Access can't be asked for; a protected folder tells whether it's on.
    nonisolated static func hasFullDiskAccess() -> Bool {
        // Opening (not just checking permissions on) a file only readable with the switch on.
        let files = ["/Library/Application Support/com.apple.TCC/TCC.db", NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"]
        if files.contains(where: { FileHandle(forReadingAtPath: $0) != nil }) { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Mail")) != nil
    }

    /// Whether Apex may send Finder Apple Events (asks when `ask` and not decided yet). Blocking.
    nonisolated static func finderAutomation(ask: Bool) -> Bool {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty { return false }
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let desc = target.aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask) == noErr
    }

    // MARK: Allow All, one at a time

    /// The permission Allow All is waiting on, and what it's waiting for.
    private(set) var allowing: Permission?
    private(set) var allowingNote = ""
    @ObservationIgnored private var skipCurrent = false
    @ObservationIgnored private var allowTask: Task<Void, Never>?

    /// Goes through every permission that's off, one at a time: asks where
    /// macOS lets an app ask, otherwise opens the exact switch in System
    /// Settings, and waits until it's on (or Skip) before the next. The
    /// helper needs a password, so it's left to its own button.
    func allowAll() {
        allowTask?.cancel()
        allowTask = Task {
            refresh()
            try? await Task.sleep(for: .milliseconds(300))
            for p in Permission.allCases where p != .helper && granted[p] != true {
                if Task.isCancelled { break }
                allowing = p
                skipCurrent = false
                allowingNote = Self.waitingNote(p)
                grant(p)
                // Up to 3 minutes for each: long enough to find and flip the switch.
                for _ in 0..<360 where !skipCurrent && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    refresh()
                    if granted[p] == true { break }
                    if p == .notifications, notificationsAnswered { break }                       // answered "Don't Allow"
                    if p == .bluetooth || p == .automation, Self.answered(p) { break }
                }
            }
            allowing = nil
            allowingNote = ""
            refresh()
            NSApp.activate(ignoringOtherApps: true)     // back to Apex from System Settings
        }
    }

    func skip() { skipCurrent = true }
    func stopAllowAll() { allowTask?.cancel(); allowTask = nil; allowing = nil; allowingNote = "" }

    /// The question was asked and answered (either way): no point waiting.
    private static func answered(_ p: Permission) -> Bool {
        switch p {
        case .bluetooth: return CBManager.authorization != .notDetermined
        case .automation: return !finderAutomationUndecided()
        default: return false
        }
    }

    nonisolated private static func finderAutomationUndecided() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let desc = target.aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) == OSStatus(errAEEventWouldRequireUserConsent)
    }

    private static func waitingNote(_ p: Permission) -> String {
        switch p {
        case .notifications: return "Choose Allow in the notification that just appeared."
        case .accessibility: return "In System Settings › Privacy & Security › Accessibility, switch on Apex Activity Manager."
        case .automation: return "Choose OK when macOS asks whether Apex may control Finder."
        case .fullDisk: return "In System Settings › Privacy & Security › Full Disk Access, switch on Apex Activity Manager (use + to add it if it isn’t listed)."
        case .bluetooth: return "Choose Allow when macOS asks about Bluetooth."
        case .openAtLogin: return "In System Settings › General › Login Items, switch on Apex Activity Manager."
        case .screenRecording: return "In System Settings › Privacy & Security › Screen & System Audio Recording, switch on Apex Activity Manager."
        case .helper: return ""
        }
    }

    // MARK: A new copy of Apex (rebuilt or updated)

    /// macOS ties each permission to the app's code identity. When that changes
    /// (a new build or an update), the old switches stay on in System Settings
    /// but no longer apply, and macOS asks again as if they were off. On the
    /// first launch with a new identity, Apex clears its own switches that don't
    /// work now (never ones that still do), so System Settings shows the truth
    /// and the next "Allow" adds a switch for this copy.
    static let identityKey = "permissionsCodeIdentity"

    static func codeIdentity() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess, let dict = info as? [String: Any] else { return nil }
        return (dict[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
    }

    /// Which permissions to clear after the identity changed: the ones that
    /// don't work now. Pure: tested.
    nonisolated static func staleToClear(changed: Bool, working: [Permission: Bool]) -> [Permission] {
        guard changed else { return [] }
        return [.accessibility, .automation, .screenRecording, .fullDisk].filter { working[$0] != true }
    }

    static let identityPathKey = "permissionsCodePath"

    /// Whether the identity change is this copy being replaced (clear its old
    /// switches) rather than another copy of Apex in another place being
    /// opened: those share the switches, and clearing would take them away
    /// from each other on every switch between copies. Pure: tested.
    nonisolated static func replacedInPlace(lastID: String?, lastPath: String?, id: String, path: String) -> Bool {
        guard let lastID, lastID != id else { return false }
        return lastPath == path
    }

    func clearStaleAfterUpdate() {
        guard Bundle.main.bundleURL.pathExtension == "app", let id = Self.codeIdentity(), let bundle = Bundle.main.bundleIdentifier else { return }
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let last = UserDefaults.standard.string(forKey: Self.identityKey)
        let lastPath = UserDefaults.standard.string(forKey: Self.identityPathKey)
        UserDefaults.standard.set(id, forKey: Self.identityKey)
        UserDefaults.standard.set(path, forKey: Self.identityPathKey)
        // The first run ever has nothing old to clear; another copy's switches aren't ours to clear.
        guard Self.replacedInPlace(lastID: last, lastPath: lastPath, id: id, path: path) else { return }
        let working: [Permission: Bool] = [.accessibility: AXIsProcessTrusted(), .screenRecording: CGPreflightScreenCaptureAccess(),
                                           .fullDisk: Self.hasFullDiskAccess(), .automation: Self.finderAutomation(ask: false)]
        for p in Self.staleToClear(changed: true, working: working) {
            if let service = Self.tccService(p) { _ = Shell.run("/usr/bin/tccutil", ["reset", service, bundle]) }
        }
        refresh()
    }

    // MARK: Switch on in System Settings but off here

    /// macOS's name for each permission's list, for clearing Apex's entry.
    static func tccService(_ p: Permission) -> String? {
        switch p {
        case .accessibility: "Accessibility"
        case .fullDisk: "SystemPolicyAllFiles"
        case .automation: "AppleEvents"
        case .bluetooth: "BluetoothAlways"
        case .screenRecording: "ScreenCapture"
        default: nil
        }
    }

    /// When System Settings shows Apex switched on but it doesn't work (the
    /// switch belongs to an earlier copy or build of Apex, which macOS treats as
    /// another app): clears Apex's entry and asks again, so the switch that
    /// appears is this copy's. Only Apex's own entry is touched.
    func resetAndAsk(_ p: Permission) {
        guard let service = Self.tccService(p), let id = Bundle.main.bundleIdentifier else { grant(p); return }
        Task.detached {
            _ = Shell.run("/usr/bin/tccutil", ["reset", service, id])
            await MainActor.run {
                PermissionCenter.shared.refresh()
                // The entry is gone, so macOS's own prompt is what adds this copy back.
                if p == .accessibility { AccessibilityAccess.ask(force: true) } else { PermissionCenter.shared.grant(p) }
            }
        }
    }

    func grant(_ p: Permission) {
        switch p {
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                Task { @MainActor in PermissionCenter.shared.refresh() }
            }
        case .fullDisk:
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        case .bluetooth:
            // Touching Bluetooth makes macOS ask; if it was refused before, open the switch.
            if CBManager.authorization == .notDetermined { _ = AccessoryControl.bluetoothDevices() }
            else { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") }
        case .accessibility:
            AccessibilityAccess.ask()
        case .automation:
            Task.detached {
                let ok = Self.finderAutomation(ask: true)
                if !ok { await MainActor.run { PermissionCenter.shared.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") } }
            }
        case .openAtLogin:
            try? SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }
        case .helper:
            Task { await FanController.shared.install(); refresh() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { PermissionCenter.shared.refresh() }
    }

    private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
}

/// The one place Apex asks for Accessibility. macOS's own prompt is shown
/// only after the person switched something on or pressed a button (never at
/// launch or on a shortcut press), and once a run at most; after that the
/// switch in System Settings opens instead. While a feature waits for it,
/// Apex checks every 2 s and starts the features by itself once it's allowed,
/// so nothing has to be switched on again.
@MainActor
enum AccessibilityAccess {
    static var trusted: Bool { AXIsProcessTrusted() }
    private static var promptedThisRun = false
    private static var watch: Timer?

    /// The person asked for a feature that needs it. `force` shows macOS's
    /// prompt again (after Apex's old entry was cleared).
    static func ask(force: Bool = false) {
        guard !trusted else { return }
        if force || !promptedThisRun {
            promptedThisRun = true
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        } else if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
        waitThenStart()
    }

    /// A feature needs it but nobody just asked: wait quietly, no prompt.
    static func waitThenStart() {
        guard watch == nil, !trusted else { return }
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard trusted else { return }
                watch?.invalidate(); watch = nil
                InputTweaks.shared.apply()
                AppSwitcher.shared.apply()
                WindowManager.shared.message = nil
                PermissionCenter.shared.refresh()
            }
        }
    }

    /// Other copies of Apex on this Mac (same app ID, another place). macOS
    /// keeps one Accessibility switch for all of them, tied to one copy, so the
    /// switch shown on may be another copy's.
    static func otherCopies() -> [URL] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
            .filter { $0.resolvingSymlinksInPath().path != me && !$0.path.contains("/.Trash/") }
    }
}
