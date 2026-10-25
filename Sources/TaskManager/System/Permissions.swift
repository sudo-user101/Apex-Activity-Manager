import AppKit
import CoreBluetooth
import ServiceManagement
import UserNotifications

/// Everything Apex may need permission for, in one place (first launch and
/// Settings). Each item says what it's for, whether it's granted, and how to
/// grant it: asked right here where macOS allows it, otherwise the exact
/// System Settings switch is opened.
enum Permission: String, CaseIterable, Identifiable {
    case notifications, fullDisk, bluetooth, openAtLogin, helper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifications: return "Notifications"
        case .fullDisk: return "Full Disk Access"
        case .bluetooth: return "Bluetooth"
        case .openAtLogin: return "Open at Login"
        case .helper: return "Battery and Fan Helper"
        }
    }

    var symbol: String {
        switch self {
        case .notifications: return "bell.badge"
        case .fullDisk: return "externaldrive.badge.checkmark"
        case .bluetooth: return "wave.3.right"
        case .openAtLogin: return "power"
        case .helper: return "battery.100.bolt"
        }
    }

    var why: String {
        switch self {
        case .notifications: return "Alerts when an app runs away with the CPU, memory runs low, the disk fills up, or a cloud offload finishes."
        case .fullDisk: return "So Disk › Analyze and Clean can measure every folder (Mail, Safari and others are hidden from apps without it)."
        case .bluetooth: return "To show your connected Bluetooth accessories and their battery."
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

    func refresh() {
        granted[.fullDisk] = Self.hasFullDiskAccess()
        granted[.bluetooth] = CBManager.authorization == .allowedAlways
        granted[.openAtLogin] = SMAppService.mainApp.status == .enabled
        granted[.helper] = FanController.shared.installed
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            Task { @MainActor in PermissionCenter.shared.granted[.notifications] = ok }
        }
    }

    /// Full Disk Access can't be asked for; a protected folder tells whether it's on.
    nonisolated static func hasFullDiskAccess() -> Bool {
        // Opening (not just checking permissions on) a file only readable with the switch on.
        let files = ["/Library/Application Support/com.apple.TCC/TCC.db", NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"]
        if files.contains(where: { FileHandle(forReadingAtPath: $0) != nil }) { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Mail")) != nil
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
        case .openAtLogin:
            try? SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        case .helper:
            Task { await FanController.shared.install(); refresh() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { PermissionCenter.shared.refresh() }
    }

    private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
}
