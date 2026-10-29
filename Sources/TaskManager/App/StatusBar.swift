import AppKit
import SwiftUI

/// The menu bar item. One click opens the panel (Monitor, Energy, Shelf,
/// Clipboard); three quick clicks open the main window. An AppKit status item
/// rather than SwiftUI's MenuBarExtra, which can't tell clicks apart.
@MainActor
final class StatusBar: NSObject, NSPopoverDelegate {
    static let shared = StatusBar()

    private var item: NSStatusItem?
    private let popover = NSPopover()

    func update() {
        let model = AppModel.shared
        if model.showMenuBar, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            i.button?.target = self
            i.button?.action = #selector(clicked(_:))
            i.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            i.button?.imagePosition = .imageLeading
            item = i
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            let host = NSHostingController(rootView: MenuBarPanel().environment(model))
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
            observeLabel()
            // Test switch: APEX_OPEN=menubar[:tab] opens the panel at launch (no clicks needed).
            if let v = ProcessInfo.processInfo.environment["APEX_OPEN"], v.hasPrefix("menubar") {
                if let tab = v.split(separator: ":").dropFirst().first { UserDefaults.standard.set(String(tab), forKey: "menuTab") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, let b = self.item?.button else { return }
                    self.popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
                }
            }
        } else if !model.showMenuBar, let i = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
        refreshLabel()
    }

    /// Where the menu bar item is on screen; nil when Apex isn't in the menu bar.
    var itemFrame: NSRect? {
        guard let b = item?.button, let w = b.window, w.isVisible else { return nil }
        let f = w.convertToScreen(b.convert(b.bounds, to: nil))
        return f.isEmpty ? nil : f
    }

    /// A small nod from the menu bar item: something just went into it.
    func bounce() {
        guard let b = item?.button, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        b.wantsLayer = true
        guard let layer = b.layer else { return }
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = [1, 1.22, 0.94, 1].map { FloatingShelf.scaled($0, centreOf: layer) }
        a.keyTimes = [0, 0.35, 0.7, 1]
        a.duration = 0.32
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "bounce")
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let clicks = NSApp.currentEvent?.clickCount ?? 1
        if clicks >= 3 {
            popover.performClose(nil)
            openApp()
        } else if clicks == 1 {
            if popover.isShown { popover.performClose(nil) }
            else { popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY) }
        } else if !popover.isShown {
            // The second click of a triple closed it: show it again until the third.
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    func openApp() {
        if let open = AppModel.shared.openMainWindow { open() }
        else { NSWorkspace.shared.open(Bundle.main.bundleURL) }   // reopen creates the window
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidShow(_ notification: Notification) { AppModel.shared.menuPanelOpen = true }
    func popoverDidClose(_ notification: Notification) { AppModel.shared.menuPanelOpen = false }

    // MARK: Label

    private func observeLabel() {
        withObservationTracking {
            _ = AppModel.shared.menuStats
            _ = AppModel.shared.menuBarStyle
        } onChange: {
            Task { @MainActor in
                self.refreshLabel()
                if self.item != nil { self.observeLabel() }
            }
        }
    }

    private func refreshLabel() {
        guard let button = item?.button else { return }
        let model = AppModel.shared
        let m = model.menuStats
        button.image = StatusBarIcon.image      // a line sketch of the app icon
        let text: String
        switch model.menuBarStyle {
        case "cpu": text = "\(m.cpu)%"
        case "memory": text = "\(m.memory)%"
        case "both": text = "\(m.cpu)% · \(m.memory)%"
        default: text = ""
        }
        button.attributedTitle = NSAttributedString(string: text.isEmpty ? "" : " " + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
        button.toolTip = "Apex: click for the panel, triple-click to open the app"
    }
}
