import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

/// Utilities › App Switcher: hold the keys and press Tab to go through every
/// open window (minimized ones and every window of an app too), newest first,
/// with live previews; let go to jump to it. W closes the window, Q quits the
/// app, H hides it, M minimizes, Esc cancels. ⌥Tab by default, or in place of
/// ⌘Tab; ⌘` for the front app's windows. Keys go through an event tap
/// (Accessibility); previews need Screen Recording, without it each window
/// shows its app's icon and title. Settings in UserDefaults `appSwitcher.*`.

struct SwitcherItem: Identifiable, Equatable {
    var id: String { "\(pid)-\(windowID)-\(index)" }
    let pid: pid_t
    let windowID: CGWindowID          // 0: an app with no window
    let index: Int
    let appName: String
    let title: String
    let minimized: Bool
    let bundleURL: URL?
    var element: AXUIElement?
    static func == (a: SwitcherItem, b: SwitcherItem) -> Bool { a.id == b.id }
}

/// The choices apart from macOS. Pure: tested.
enum SwitcherRules {
    /// Windows front to back (`zOrder` = CGWindowIDs as the window server
    /// lists them), minimized ones last, or one entry per app in that order.
    static func ordered(_ items: [SwitcherItem], zOrder: [CGWindowID], appOrder: [pid_t], onePerApp: Bool, minimizedLast: Bool) -> [SwitcherItem] {
        let rank = Dictionary(zOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let appRank = Dictionary(appOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var out = items.sorted { a, b in
            if minimizedLast, a.minimized != b.minimized { return !a.minimized }
            let ra = rank[a.windowID] ?? Int.max - 1000 + (appRank[a.pid] ?? 999)
            let rb = rank[b.windowID] ?? Int.max - 1000 + (appRank[b.pid] ?? 999)
            return ra != rb ? ra < rb : a.index < b.index
        }
        if onePerApp {
            var seen = Set<pid_t>()
            out = out.filter { seen.insert($0.pid).inserted }
        }
        return out
    }

    /// Where the selection goes. Pure: tested.
    static func step(_ i: Int, by d: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((i + d) % count + count) % count
    }

    /// The first selection: the window after the one in front (a quick tap goes back to the last window).
    static func start(count: Int) -> Int { count > 1 ? 1 : 0 }
}

@MainActor @Observable
final class AppSwitcher {
    static let shared = AppSwitcher()

    enum Keys {
        static let enabled = "appSwitcher", trigger = "appSwitcher.trigger", windowsKey = "appSwitcher.windowsKey"
        static let onePerApp = "appSwitcher.onePerApp", previews = "appSwitcher.previews", delay = "appSwitcher.delayMs"
        static let minimizedLast = "appSwitcher.minimizedLast", hints = "appSwitcher.hints"
    }
    static var enabled: Bool { UserDefaults.standard.bool(forKey: Keys.enabled) }
    /// "option" (⌥Tab) or "command" (⌘Tab, in place of macOS's).
    static var trigger: String { UserDefaults.standard.string(forKey: Keys.trigger) ?? "option" }
    static func flag(_ k: String, _ d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }

    private(set) var items: [SwitcherItem] = []
    private(set) var selected = 0
    private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    private(set) var visible = false
    private(set) var problem: String?

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored fileprivate var active = false
    @ObservationIgnored private var modifier: CGEventFlags = .maskAlternate
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var showTimer: DispatchWorkItem?

    // MARK: On / off

    func apply() {
        if Self.enabled { startTap() } else { stopTap() }
        // In place of macOS's ⌘Tab (and ⌘`): its own shortcuts are switched off
        // while this is on, and always back on when it's off or Apex quits.
        Self.systemSwitcher(enabled: !(Self.enabled && tap != nil && Self.trigger == "command"), ids: [1, 2])
        Self.systemSwitcher(enabled: !(Self.enabled && tap != nil && Self.flag(Keys.windowsKey, false)), ids: [6, 27])
    }

    /// Restores macOS's own switcher shortcuts (called when Apex quits).
    static func restoreSystemShortcuts() { systemSwitcher(enabled: true, ids: [1, 2, 6, 27]) }

    /// macOS's symbolic hot keys: 1 ⌘Tab, 2 ⇧⌘Tab, 6 and 27 ⌘` (next window).
    private static let setHotKey: (@convention(c) (Int32, Bool) -> Int32)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let f = dlsym(h, "CGSSetSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(f, to: (@convention(c) (Int32, Bool) -> Int32).self)
    }()
    private static func systemSwitcher(enabled: Bool, ids: [Int32]) { for id in ids { _ = setHotKey?(id, enabled) } }

    private func startTap() {
        guard AXIsProcessTrusted() else {
            AccessibilityAccess.waitThenStart()
            problem = "Allow Apex under System Settings › Privacy & Security › Accessibility; the switcher starts by itself once it’s on."
            return
        }
        problem = nil
        guard tap == nil else { return }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: switcherTapCallback, userInfo: nil) else {
            problem = "macOS didn’t let Apex watch the keyboard. Check Accessibility in System Settings."
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func stopTap() {
        cancel()
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }

    fileprivate func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }

    // MARK: Keys

    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        let flags = e.flags
        let triggerFlag: CGEventFlags = Self.trigger == "command" ? .maskCommand : .maskAlternate
        if type == .flagsChanged {
            if active, !flags.contains(modifier) { commit() }
            return false
        }
        if !active {
            guard type == .keyDown else { return false }
            let others: CGEventFlags = [.maskControl, triggerFlag == .maskCommand ? .maskAlternate : .maskCommand]
            if code == kVK_Tab, flags.contains(triggerFlag), flags.isDisjoint(with: others) {
                begin(appOnly: false, modifier: triggerFlag, backwards: flags.contains(.maskShift)); return true
            }
            if code == kVK_ANSI_Grave, flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate),
               Self.flag(Keys.windowsKey, false) {
                begin(appOnly: true, modifier: .maskCommand, backwards: flags.contains(.maskShift)); return true
            }
            return false
        }
        // While it's open, every key is the switcher's.
        guard type == .keyDown else { return true }
        switch code {
        case kVK_Tab, kVK_ANSI_Grave: move(flags.contains(.maskShift) ? -1 : 1)
        case kVK_RightArrow, kVK_DownArrow: move(1)
        case kVK_LeftArrow, kVK_UpArrow: move(-1)
        case kVK_Escape: cancel()
        case kVK_Return, kVK_Space: commit()
        case kVK_ANSI_W: act(.close)
        case kVK_ANSI_Q: act(.quit)
        case kVK_ANSI_H: act(.hide)
        case kVK_ANSI_M: act(.minimize)
        default: break
        }
        return true
    }

    private func begin(appOnly: Bool, modifier: CGEventFlags, backwards: Bool) {
        self.modifier = modifier
        active = true
        items = Self.collect(appOnly: appOnly, onePerApp: !appOnly && Self.flag(Keys.onePerApp, false),
                             minimizedLast: Self.flag(Keys.minimizedLast, true))
        selected = backwards ? max(0, items.count - 1) : SwitcherRules.start(count: items.count)
        thumbnails = [:]
        // Shown after a moment: a quick tap switches without the panel flashing up.
        let delay = Double(UserDefaults.standard.object(forKey: Keys.delay) as? Int ?? 100) / 1000
        let work = DispatchWorkItem { MainActor.assumeIsolated { AppSwitcher.shared.show() } }
        showTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func move(_ d: Int) { selected = SwitcherRules.step(selected, by: d, count: items.count); if !visible { show() } }

    private func finish() {
        showTimer?.cancel(); showTimer = nil
        active = false
        visible = false
        panel?.orderOut(nil)
    }

    func cancel() { finish() }

    func commit() {
        let item = items.indices.contains(selected) ? items[selected] : nil
        finish()
        if let item { focus(item) }
    }

    func pick(_ i: Int) { selected = i; commit() }

    // MARK: Windows

    /// Every regular app's windows (standard ones, minimized too), via Accessibility.
    static func collect(appOnly: Bool, onePerApp: Bool, minimizedLast: Bool) -> [SwitcherItem] {
        let front = NSWorkspace.shared.frontmostApplication
        var apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        if appOnly, let f = front { apps = apps.filter { $0.processIdentifier == f.processIdentifier } }
        var items: [SwitcherItem] = []
        for app in apps {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.15)
            var list: CFTypeRef?
            AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &list)
            let windows = ((list as? [AXUIElement]) ?? []).filter { WindowAX.string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String }
            for (i, w) in windows.enumerated() {
                items.append(SwitcherItem(pid: app.processIdentifier, windowID: windowID(w), index: i, appName: app.localizedName ?? "App",
                                          title: WindowAX.string(w, kAXTitleAttribute) ?? "", minimized: WindowAX.bool(w, kAXMinimizedAttribute),
                                          bundleURL: app.bundleURL, element: w))
            }
            // Finder with no window still belongs in the list (as macOS's ⌘Tab has it).
            if windows.isEmpty, !appOnly, app.bundleIdentifier == "com.apple.finder" || !app.isHidden {
                items.append(SwitcherItem(pid: app.processIdentifier, windowID: 0, index: 0, appName: app.localizedName ?? "App",
                                          title: "No windows", minimized: false, bundleURL: app.bundleURL, element: nil))
            }
        }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let z = info.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        var appOrder: [pid_t] = front.map { [$0.processIdentifier] } ?? []
        for w in info { if let p = w[kCGWindowOwnerPID as String] as? pid_t, !appOrder.contains(p) { appOrder.append(p) } }
        return SwitcherRules.ordered(items, zOrder: z, appOrder: appOrder, onePerApp: onePerApp, minimizedLast: minimizedLast)
    }

    /// The window server's number for an Accessibility window (how every switcher maps them).
    private static let getWindow: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
        guard let h = dlopen(nil, RTLD_NOW), let f = dlsym(h, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(f, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
    }()
    static func windowID(_ w: AXUIElement) -> CGWindowID {
        var id: CGWindowID = 0
        _ = getWindow?(w, &id)
        return id
    }

    private func focus(_ item: SwitcherItem) {
        guard let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        if app.isHidden { app.unhide() }
        if let w = item.element {
            if item.minimized { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
        app.activate()
    }

    enum Action { case close, quit, hide, minimize }

    private func act(_ a: Action) {
        guard items.indices.contains(selected) else { return }
        let item = items[selected]
        let app = NSRunningApplication(processIdentifier: item.pid)
        switch a {
        case .close:
            if let w = item.element {
                var button: CFTypeRef?
                if AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &button) == .success, let b = button {
                    AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
                }
            }
            items.remove(at: selected)
        case .quit:
            app?.terminate()
            items.removeAll { $0.pid == item.pid }
        case .hide:
            app?.hide()
            items.removeAll { $0.pid == item.pid }
        case .minimize:
            if let w = item.element { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        }
        if items.isEmpty { cancel(); return }
        selected = min(selected, items.count - 1)
    }

    // MARK: The panel

    private func show() {
        guard active, !items.isEmpty else { return }
        visible = true
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .popUpMenu; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.contentView = NSHostingView(rootView: SwitcherView())
            return p
        }()
        panel = p
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        let size = SwitcherView.size(count: items.count, previews: showPreviews, within: area.size)
        p.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        if showPreviews { loadThumbnails() }
    }

    var showPreviews: Bool { Self.flag(Keys.previews, true) && CGPreflightScreenCaptureAccess() && !Self.flag(Keys.onePerApp, false) }

    private func loadThumbnails() {
        let ids = Set(items.map(\.windowID).filter { $0 != 0 })
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
            for w in content.windows where ids.contains(w.windowID) && w.frame.width > 40 {
                guard active else { return }
                let config = SCStreamConfiguration()
                let scale = 360 / max(w.frame.width, 1)
                config.width = Int(w.frame.width * scale * 2); config.height = Int(w.frame.height * scale * 2)
                config.showsCursor = false
                if let cg = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config) {
                    thumbnails[w.windowID] = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
                }
            }
        }
    }
}

private func switcherTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { AppSwitcher.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    let used = MainActor.assumeIsolated { AppSwitcher.shared.handle(type, event) }
    return used ? nil : Unmanaged.passUnretained(event)
}

struct SwitcherView: View {
    private var s: AppSwitcher { AppSwitcher.shared }
    static let card = CGSize(width: 200, height: 160), icon: CGFloat = 96

    static func size(count: Int, previews: Bool, within: CGSize) -> CGSize {
        let w = previews ? card.width : icon + 40, h = previews ? card.height : icon + 50
        let perRow = max(1, min(count, Int((within.width * 0.9 - 32) / (w + 12))))
        let rows = Int(ceil(Double(count) / Double(perRow)))
        let hint: CGFloat = AppSwitcher.flag(AppSwitcher.Keys.hints, true) ? 26 : 0
        return CGSize(width: CGFloat(perRow) * (w + 12) + 20, height: min(within.height * 0.9, CGFloat(rows) * (h + 12) + 20 + hint))
    }

    var body: some View {
        let previews = s.showPreviews
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: previews ? Self.card.width : Self.icon + 40), spacing: 12)], spacing: 12) {
                        ForEach(Array(s.items.enumerated()), id: \.element.id) { i, item in
                            cell(item, selected: i == s.selected, previews: previews)
                                .id(i)
                                .onTapGesture { s.pick(i) }
                        }
                    }
                    .padding(10)
                }
                .onChange(of: s.selected) { proxy.scrollTo(s.selected) }
            }
            if AppSwitcher.flag(AppSwitcher.Keys.hints, true) {
                Text("Tab next · ⇧Tab back · W close window · Q quit · H hide · M minimize · Esc cancel")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private func cell(_ item: SwitcherItem, selected: Bool, previews: Bool) -> some View {
        let appIcon = item.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if previews, let t = s.thumbnails[item.windowID] {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: Self.card.width - 16, height: Self.card.height - 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).opacity(item.minimized ? 0.6 : 1)
                    Image(nsImage: appIcon).resizable().frame(width: 30, height: 30).offset(x: 6, y: 6)
                } else {
                    Image(nsImage: appIcon).resizable().frame(width: previews ? 72 : Self.icon, height: previews ? 72 : Self.icon)
                        .frame(width: previews ? Self.card.width - 16 : Self.icon, height: previews ? Self.card.height - 52 : Self.icon)
                        .opacity(item.minimized ? 0.6 : 1)
                }
            }
            Text(item.title.isEmpty || !previews ? item.appName : item.title)
                .font(.caption.weight(selected ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                .frame(width: previews ? Self.card.width - 16 : Self.icon + 24)
            if item.minimized { Text("Minimized").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}
