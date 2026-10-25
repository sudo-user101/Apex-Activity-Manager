import AppKit
import CoreWLAN

extension SafeAction {
    /// Actions that don't need a doctor's own context.
    @MainActor static func runCommon(_ a: SafeAction) {
        switch a {
        case .openDiskUtility: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
        case .openTimeMachine: open("x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")
        case .openStorageSettings: open("x-apple.systempreferences:com.apple.settings.Storage")
        case .openNetworkSettings: open("x-apple.systempreferences:com.apple.Network-Settings.extension")
        case .openWiFiSettings: open("x-apple.systempreferences:com.apple.wifi-settings-extension")
        case .openLoginPage: open("http://captive.apple.com")      // plain http, so the network can show its page
        case .restartWiFi:
            Task.detached {
                guard let wifi = CWWiFiClient.shared().interface() else { return }
                try? wifi.setPower(false)
                try? await Task.sleep(for: .seconds(3))
                try? wifi.setPower(true)
            }
        case .checkForErrors, .freeUpSpace, .testSpeed: break   // handled by the doctor showing the finding
        }
    }

    private static func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
}
