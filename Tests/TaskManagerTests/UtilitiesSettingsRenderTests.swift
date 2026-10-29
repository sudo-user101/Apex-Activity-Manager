import AppKit
import SwiftUI
import XCTest
@testable import TaskManager

/// APEX_RENDER_UTILITIES=dir: Settings › Utilities on a few utilities, light and dark.
final class UtilitiesSettingsRenderTests: XCTestCase {
    @MainActor func testRender() async throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_RENDER_UTILITIES"] else { throw XCTSkip("set APEX_RENDER_UTILITIES") }
        let saved = UserDefaults.standard.string(forKey: "settingsUtility")
        defer { UserDefaults.standard.set(saved, forKey: "settingsUtility") }
        for u in ["shelf", "folderPreview", "windowManager", "clipboard", "stayAwake", "cleanKeyboard"] {
            UserDefaults.standard.set(u, forKey: "settingsUtility")
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: UtilitiesSettingsTab().environment(AppModel.shared).environment(\.colorScheme, scheme))
                let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: UtilitiesSettingsTab.width, height: UtilitiesSettingsTab.height),
                                 styleMask: .borderless, backing: .buffered, defer: false)
                w.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                w.contentView = host
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/utilities-\(u)-\(scheme == .dark ? "dark" : "light").png"))
                w.orderOut(nil)
            }
        }
    }
}

/// APEX_RENDER_UTILITIES=dir also renders Settings › MacOSX Change (reads macOS's settings, changes nothing).
final class MacChangeSettingsRenderTests: XCTestCase {
    @MainActor func testRender() async throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_RENDER_UTILITIES"] else { throw XCTSkip("set APEX_RENDER_UTILITIES") }
        let saved = UserDefaults.standard.string(forKey: "settingsMacChangeGroup")
        defer { UserDefaults.standard.set(saved, forKey: "settingsMacChangeGroup") }
        for (g, scheme) in [("Finder", ColorScheme.light), ("Dock", .dark), ("Mouse", .light), ("Clipboard & links", .dark), ("Apps & system", .light)] {
            UserDefaults.standard.set(g, forKey: "settingsMacChangeGroup")
            let host = NSHostingView(rootView: MacOSXChangeSettingsTab().environment(\.colorScheme, scheme))
            let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: UtilitiesSettingsTab.width, height: UtilitiesSettingsTab.height),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            w.contentView = host
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/macchange-\(g).png"))
            w.orderOut(nil)
        }
    }
}

/// Settings follow changes made elsewhere: clipboard history switched off from
/// outside (as the menu bar's switch does) shows in Settings › Utilities at once.
final class SettingsFollowTheAppTests: XCTestCase {
    @MainActor private func snapshot(_ host: NSView) -> Data {
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.tiffRepresentation!
    }

    @MainActor func testUtilitiesReflectAChangeMadeElsewhere() async throws {
        let savedSel = UserDefaults.standard.string(forKey: "settingsUtility")
        let wasOn = ClipboardHistory.shared.enabled
        defer { ClipboardHistory.shared.enabled = wasOn; UserDefaults.standard.set(savedSel, forKey: "settingsUtility") }
        UserDefaults.standard.set("clipboard", forKey: "settingsUtility")
        ClipboardHistory.shared.enabled = true
        let host = NSHostingView(rootView: UtilitiesSettingsTab().environment(AppModel.shared))
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: UtilitiesSettingsTab.width, height: UtilitiesSettingsTab.height),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = host; w.orderFrontRegardless()
        defer { w.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let on = snapshot(host)
        ClipboardHistory.shared.enabled = false                 // changed outside Settings
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let off = snapshot(host)
        XCTAssertNotEqual(on, off, "the switch and the list's On/Off follow the change")
        ClipboardHistory.shared.enabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(snapshot(host), on, "and back")
    }

    /// Alerts › a setting saved elsewhere is shown when it changes.
    @MainActor func testAlertsReReadSavedSettings() async throws {
        let saved = Alerts.shared.settings
        defer { Alerts.shared.settings = saved }
        let host = NSHostingView(rootView: AlertsSettingsTab().environment(AppModel.shared))
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 560, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = host; w.orderFrontRegardless()
        defer { w.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let before = snapshot(host)
        var s = saved; s.heat.toggle()
        Alerts.shared.settings = s                              // saved from elsewhere
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNotEqual(snapshot(host), before)
    }
}

/// Every Settings tab is the same size, so switching tabs never resizes the window or moves the tab bar.
final class SettingsSameSizeTests: XCTestCase {
    @MainActor func testEveryTabIsTheSameSize() {
        let tabs: [(String, AnyView)] = [
            ("General", AnyView(GeneralSettingsTab())), ("Menu Bar", AnyView(MenuBarSettingsTab())),
            ("Utilities", AnyView(UtilitiesSettingsTab())), ("MacOSX Change", AnyView(MacOSXChangeSettingsTab())),
            ("Alerts", AnyView(AlertsSettingsTab())), ("History", AnyView(HistorySettingsTab())),
            ("Privacy", AnyView(PrivacySettingsTab())), ("Permissions", AnyView(PermissionsSettingsTab())),
        ]
        for (name, v) in tabs {
            let size = NSHostingView(rootView: v.environment(AppModel.shared)).fittingSize
            XCTAssertEqual(size, NSSize(width: SettingsLayout.width, height: SettingsLayout.height), name)
        }
    }
}

/// APEX_RENDER_UTILITIES=dir: General and Alerts at the window's fixed size.
final class SettingsFixedSizeRenderTests: XCTestCase {
    @MainActor func testRender() throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_RENDER_UTILITIES"] else { throw XCTSkip("set APEX_RENDER_UTILITIES") }
        for (name, v) in [("general", AnyView(GeneralSettingsTab())), ("alerts", AnyView(AlertsSettingsTab()))] {
            let host = NSHostingView(rootView: v.environment(AppModel.shared).background(Color(nsColor: .windowBackgroundColor)))
            let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: SettingsLayout.width, height: SettingsLayout.height), styleMask: .borderless, backing: .buffered, defer: false)
            w.contentView = host; w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/settings-\(name).png"))
            w.orderOut(nil)
        }
    }
}
