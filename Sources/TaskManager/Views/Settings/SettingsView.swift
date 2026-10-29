import SwiftUI

/// Apex › Settings: toolbar tabs like Safari's, each tab its own view. The
/// window is the same size on every tab, so switching tabs never resizes it
/// or moves the tab bar; a tab with more than fits scrolls inside.
struct SettingsView: View {
    enum Tab: String, CaseIterable { case general, menuBar, utilities, macosxChange, alerts, history, privacy, permissions }

    // Test switch: APEX_SETTINGS_TAB=alerts opens on that tab.
    @State private var tab = Tab(rawValue: ProcessInfo.processInfo.environment["APEX_SETTINGS_TAB"] ?? "") ?? .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            MenuBarSettingsTab()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }.tag(Tab.menuBar)
            UtilitiesSettingsTab()
                .tabItem { Label("Utilities", systemImage: "wrench.and.screwdriver") }.tag(Tab.utilities)
            MacOSXChangeSettingsTab()
                .tabItem { Label("MacOSX Change", systemImage: "slider.horizontal.3") }.tag(Tab.macosxChange)
            AlertsSettingsTab()
                .tabItem { Label("Alerts", systemImage: "bell.badge") }.tag(Tab.alerts)
            HistorySettingsTab()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(Tab.history)
            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }.tag(Tab.privacy)
            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "hand.raised") }.tag(Tab.permissions)
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
    }
}

enum SettingsLayout {
    /// Every tab: wide enough for Utilities' list and page.
    static let width: CGFloat = 760
    static let height: CGFloat = 560
}

extension View {
    /// A tab's grouped form filling the window's fixed size; it scrolls if
    /// there's more than fits.
    func settingsForm() -> some View {
        formStyle(.grouped)
            .frame(width: SettingsLayout.width, height: SettingsLayout.height)
    }

    /// The short grey line under a control.
    func settingsCaption() -> some View {
        font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
