import SwiftUI

/// Apex › Settings: toolbar tabs like Safari's, each tab its own view. The
/// window takes each tab's height (macOS animates the resize); 500 pt wide.
struct SettingsView: View {
    enum Tab: String, CaseIterable { case general, alerts, history, shelf, permissions }

    // Test switch: APEX_SETTINGS_TAB=alerts opens on that tab.
    @State private var tab = Tab(rawValue: ProcessInfo.processInfo.environment["APEX_SETTINGS_TAB"] ?? "") ?? .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            AlertsSettingsTab()
                .tabItem { Label("Alerts", systemImage: "bell.badge") }.tag(Tab.alerts)
            HistorySettingsTab()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(Tab.history)
            ShelfSettingsTab()
                .tabItem { Label("Shelf", systemImage: "tray.full") }.tag(Tab.shelf)
            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "hand.raised") }.tag(Tab.permissions)
        }
        .frame(width: SettingsLayout.width)
    }
}

enum SettingsLayout {
    static let width: CGFloat = 500
}

extension View {
    /// A tab's grouped form, as tall as what's in it (no scrolling, no fixed height).
    func settingsForm() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: SettingsLayout.width)
    }

    /// The short grey line under a control.
    func settingsCaption() -> some View {
        font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
