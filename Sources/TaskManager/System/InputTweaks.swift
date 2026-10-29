import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Settings › MacOSX Change: the behaviours Apex runs itself (macOS has no
/// setting for them), shown beside the hidden settings in each group. Most
/// change keyboard or mouse events as they happen, through one event tap,
/// which macOS allows only with Accessibility. Each is off until switched
/// on, and stops the moment it's switched off or Apex quits.
/// UserDefaults `behaviour.<id>`; options in `behaviour.<id>.<option>`.

struct MacBehaviour: Identifiable, Sendable {
    var id: String
    var group: String
    var title: String
    var detail: String
    /// Changes keyboard or mouse events: needs Accessibility.
    var usesInput = true
}

enum MacBehaviours {
    static let all: [MacBehaviour] = [
        .init(id: "finder.cutPaste", group: "Finder", title: "⌘X and ⌘V move files",
              detail: "Cut files with ⌘X, then ⌘V moves them, instead of copying. Text being edited is cut as usual."),
        .init(id: "finder.f2Rename", group: "Finder", title: "F2 renames the selected file",
              detail: "As on Windows. Press fn-F2 on keyboards where F2 changes brightness."),
        .init(id: "finder.pasteImage", group: "Finder", title: "Paste a copied image as a file",
              detail: "⌘V in a Finder window saves a copied picture there as a PNG (Finder asks once whether Apex may see its window)."),
        .init(id: "dock.clickMinimize", group: "Dock", title: "Click the Dock icon to minimize",
              detail: "The app in front minimizes its windows when you click its Dock icon. Click again to bring them back."),
        .init(id: "ui.quitTwice", group: "Windows & dialogs", title: "Press ⌘Q twice to quit an app",
              detail: "The first ⌘Q shows a reminder; press it again within 1.5 seconds to quit. Stops quitting by accident."),
        .init(id: "ui.quitOnClose", group: "Windows & dialogs", title: "Quit chosen apps when their last window closes",
              detail: "As on Windows. Choose the apps below.", usesInput: false),
        .init(id: "keys.debounce", group: "Keyboard & typing", title: "Ignore double letters from a worn keyboard",
              detail: "A key that registers twice within 40 ms is counted once. Holding a key still repeats."),
        .init(id: "keys.brightness", group: "Keyboard & typing", title: "Screen brightness from the keyboard",
              detail: "Up and down arrows with the shortcut below change the brightness of the screen the pointer is on, in 16 steps, on any display Apex can dim.",
              usesInput: false),
        .init(id: "mouse.sideButtons", group: "Mouse", title: "Mouse side buttons go back and forward",
              detail: "In Finder, Safari and other apps that use ⌘[ and ⌘]. Browsers that already handle the buttons are left alone."),
        .init(id: "mouse.reverseWheel", group: "Mouse", title: "Reverse the mouse wheel only",
              detail: "Keeps natural scrolling on the trackpad while a mouse wheel scrolls the other way. (A Magic Mouse counts as a trackpad.)"),
        .init(id: "mouse.linearWheel", group: "Mouse", title: "Each wheel notch scrolls the same amount",
              detail: "Three lines a notch however fast the wheel spins, instead of speeding up."),
        .init(id: "mouse.clickFilter", group: "Mouse", title: "Ignore double clicks from a worn mouse button",
              detail: "A second click within 50 ms of letting go is ignored. Real double-clicks are much slower and still work."),
        .init(id: "clip.cleanLinks", group: "Clipboard & links", title: "Remove tracking from copied links",
              detail: "utm_…, fbclid, gclid and similar are taken out of a link as you copy it. The page opens the same.", usesInput: false),
        .init(id: "clip.plainPaste", group: "Clipboard & links", title: "⌥⇧⌘V pastes as plain text in every app",
              detail: "No fonts, colours or links come along. What you copied stays on the clipboard."),
        .init(id: "clip.autoClear", group: "Clipboard & links", title: "Clear the clipboard after a while",
              detail: "Also when the Mac sleeps or the screen locks. Clipboard History keeps its own list.", usesInput: false),
        .init(id: "sys.micMute", group: "Apps & system", title: "⌥M mutes the microphone",
              detail: "In every app; press again to turn it back on. A notice shows which. Some apps (and Siri) can still listen to a muted mic’s device; it isn’t a privacy lock.",
              usesInput: false),
        .init(id: "sys.headphoneVolume", group: "Apps & system", title: "Turn the volume down when headphones disconnect",
              detail: "So music doesn’t blast from the speakers when headphones are unplugged or AirPods drop.", usesInput: false),
        .init(id: "sys.blockMusic", group: "Apps & system", title: "The play key doesn’t open Music",
              detail: "If pressing play starts the Music app when nothing was playing, Apex closes it again. Opening Music yourself still works."),
    ]

    static func key(_ id: String) -> String { "behaviour." + id }
    static func isOn(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: key(id)) }

    @MainActor static func set(_ id: String, on: Bool) {
        UserDefaults.standard.set(on, forKey: key(id))
        if on, all.first(where: { $0.id == id })?.usesInput == true { AccessibilityAccess.ask() }
        InputTweaks.shared.apply()
    }

    @MainActor static func undoAll() { for b in all where isOn(b.id) { UserDefaults.standard.set(false, forKey: key(b.id)) }; InputTweaks.shared.apply() }

    /// Minutes before the clipboard is cleared.
    static var clearMinutes: Int {
        let m = UserDefaults.standard.integer(forKey: key("clip.autoClear") + ".minutes")
        return m > 0 ? m : 5
    }
    static var quitOnCloseApps: [String] { UserDefaults.standard.stringArray(forKey: key("ui.quitOnClose") + ".apps") ?? [] }
}

/// The decisions, apart from macOS. Pure: tested.
enum InputRules {
    static let chatterSeconds = 0.05, debounceSeconds = 0.04, quitWindow = 1.5

    /// A mouse wheel's scroll with the behaviours applied: (lines, points) per axis.
    /// Continuous scrolling (trackpads, Magic Mouse) is never touched.
    static func wheel(lines: Int64, points: Double, continuous: Bool, reverse: Bool, linear: Bool) -> (lines: Int64, points: Double) {
        guard !continuous, lines != 0 || points != 0 else { return (lines, points) }
        var l = lines, p = points
        if linear {
            let sign: Int64 = (l != 0 ? l : Int64(p.sign == .minus ? -1 : 1)) < 0 ? -1 : 1
            l = 3 * sign; p = Double(30 * sign)
        }
        if reverse { l = -l; p = -p }
        return (l, p)
    }

    /// A press that comes too soon after the last release of the same button or key.
    static func isChatter(sinceLastUp: Double?, limit: Double) -> Bool {
        guard let s = sinceLastUp else { return false }
        return s >= 0 && s < limit
    }

    /// Side buttons (3 = back, 4 = forward) → the key to send, or nil to leave the click alone.
    static let nativeSideButtons: Set<String> = [
        "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    static func sideButton(_ button: Int64, app: String?) -> Int? {
        if let app, nativeSideButtons.contains(app) { return nil }
        switch button {
        case 3: return kVK_ANSI_LeftBracket
        case 4: return kVK_ANSI_RightBracket
        default: return nil
        }
    }

    enum FinderKey: Equatable { case none, cut, move, rename, pasteImage }

    /// What a key pressed in Finder becomes. `editing` = a text field has focus.
    static func finderKey(code: Int, command: Bool, otherMods: Bool, editing: Bool, cutPending: Bool,
                          imageOnly: Bool, cutPaste: Bool, f2: Bool, pasteImage: Bool) -> FinderKey {
        guard !editing else { return .none }
        if code == kVK_F2, !command, !otherMods, f2 { return .rename }
        guard command, !otherMods else { return .none }
        if code == kVK_ANSI_X, cutPaste { return .cut }
        if code == kVK_ANSI_V {
            if cutPending, cutPaste { return .move }
            if imageOnly, pasteImage { return .pasteImage }
        }
        return .none
    }

    /// ⌘Q pressed: quit now (true), or the first press (false: show the reminder).
    static func quitAllowed(lastPress: Date?, lastApp: String?, app: String?, now: Date) -> Bool {
        guard let lastPress, lastApp == app else { return false }
        return now.timeIntervalSince(lastPress) <= quitWindow
    }

    /// Tracking taken out of a link; nil when there's nothing to take out.
    static let trackers: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "li_fat_id", "igshid", "igsh",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "rb_clickid", "s_cid",
        "ref_src", "ref_url", "spm", "si", "trk", "trkCampaign", "sc_campaign", "srsltid",
    ]
    static func cleanLink(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), !t.contains("\n"), var c = URLComponents(string: t), let scheme = c.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let items = c.queryItems, !items.isEmpty else { return nil }
        // "si" is tracking on YouTube and Spotify links only; elsewhere it may be real.
        let host = c.host?.lowercased() ?? ""
        let siTracks = ["youtube.com", "youtu.be", "spotify.com"].contains { host == $0 || host.hasSuffix("." + $0) }
        let kept = items.filter { i in
            let n = i.name.lowercased()
            if n.hasPrefix("utm_") { return false }
            if n == "si" { return !siTracks }
            return !trackers.contains(i.name) && !trackers.contains(n)
        }
        guard kept.count < items.count else { return nil }
        c.queryItems = kept.isEmpty ? nil : kept
        return c.string
    }
}

/// Runs the switched-on behaviours.
@MainActor
final class InputTweaks {
    static let shared = InputTweaks()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timers: [Timer] = []
    private var observers: [NSObjectProtocol] = []
    private(set) var lastProblem: String?

    // State the tap keeps between events.
    fileprivate var lastMouseUp: [Int64: TimeInterval] = [:]
    fileprivate var droppedDown: Set<Int64> = []
    fileprivate var lastKeyUp: [Int64: TimeInterval] = [:]
    fileprivate var droppedKeys: Set<Int64> = []
    fileprivate var cutChange: Int?
    fileprivate var quitPress: (Date, String?)?
    fileprivate var playPressed: Date?

    private var lastChange = NSPasteboard.general.changeCount
    private var lastCopy = Date()
    private var windowsSeen: [pid_t: Int] = [:]

    var on: Set<String> = []

    /// Starts or stops each behaviour to match the switches.
    func apply() {
        on = Set(MacBehaviours.all.filter { MacBehaviours.isOn($0.id) }.map(\.id))
        let wantsTap = MacBehaviours.all.contains { $0.usesInput && on.contains($0.id) }
        if wantsTap { startTap() } else { stopTap() }
        timers.forEach { $0.invalidate() }; timers = []
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
        if on.contains("clip.cleanLinks") || on.contains("clip.autoClear") {
            timers.append(Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { InputTweaks.shared.watchClipboard() } })
        }
        if on.contains("clip.autoClear") {
            let clear: @Sendable (Notification) -> Void = { _ in MainActor.assumeIsolated { InputTweaks.shared.clearClipboard() } }
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: clear))
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: clear))
        }
        if on.contains("ui.quitOnClose") {
            windowsSeen = [:]
            timers.append(Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in MainActor.assumeIsolated { InputTweaks.shared.quitWindowless() } })
        }
        WindowTweaks.apply(on)
        // Window shortcuts moved to Utilities › Window Manager: someone who had them keeps them.
        if UserDefaults.standard.bool(forKey: MacBehaviours.key("win.layout")) {
            UserDefaults.standard.removeObject(forKey: MacBehaviours.key("win.layout"))
            UserDefaults.standard.set(true, forKey: WindowManager.Keys.enabled)
        }
        WindowManager.shared.apply()
        if on.contains("sys.blockMusic") {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { InputTweaks.shared.musicLaunched(app) }
            })
        }
    }

    // MARK: The event tap

    private func startTap() {
        guard AXIsProcessTrusted() else {
            lastProblem = "Allow Apex under System Settings › Privacy & Security › Accessibility; these start by themselves once it’s on."
            AccessibilityAccess.waitThenStart()
            stopTap(); return
        }
        lastProblem = nil
        guard tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel,
                                    CGEventType(rawValue: 14)!]   // NX_SYSDEFINED: media keys
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else {
            lastProblem = "macOS didn’t let Apex watch the keyboard and mouse. Check Accessibility in System Settings."
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func stopTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }

    fileprivate func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }

    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) -> CGEvent? {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .scrollWheel where on.contains("mouse.reverseWheel") || on.contains("mouse.linearWheel"):
            let continuous = e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            for (lf, pf) in [(CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventPointDeltaAxis1),
                             (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2)] {
                let r = InputRules.wheel(lines: e.getIntegerValueField(lf), points: e.getDoubleValueField(pf), continuous: continuous,
                                         reverse: on.contains("mouse.reverseWheel"), linear: on.contains("mouse.linearWheel"))
                e.setIntegerValueField(lf, value: r.lines)
                e.setDoubleValueField(pf, value: r.points)
                e.setDoubleValueField(lf == .scrollWheelEventDeltaAxis1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2,
                                      value: Double(r.lines))
            }
            return e
        case .leftMouseDown where on.contains("mouse.clickFilter") || on.contains("dock.clickMinimize"):
            if on.contains("mouse.clickFilter"),
               InputRules.isChatter(sinceLastUp: lastMouseUp[0].map { now - $0 }, limit: InputRules.chatterSeconds) { droppedDown.insert(0); return nil }
            if on.contains("dock.clickMinimize"), WindowTweaks.dockClick(at: e.location) { droppedDown.insert(0); return nil }
            return e
        case .leftMouseUp:
            if droppedDown.remove(0) != nil { return nil }
            lastMouseUp[0] = now
            return e
        case .otherMouseDown where on.contains("mouse.sideButtons"):
            let button = e.getIntegerValueField(.mouseEventButtonNumber)
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if let key = InputRules.sideButton(button, app: app) { postKey(key, flags: .maskCommand); droppedDown.insert(button); return nil }
            return e
        case .otherMouseUp:
            return droppedDown.remove(e.getIntegerValueField(.mouseEventButtonNumber)) != nil ? nil : e
        case .keyDown:
            return keyDown(e, now: now)
        case .keyUp:
            let code = e.getIntegerValueField(.keyboardEventKeycode)
            if droppedKeys.remove(code) != nil { return nil }
            lastKeyUp[code] = now
            return e
        case CGEventType(rawValue: 14)!:
            // Media keys: data1 = key << 16 | (down ? 0xA : 0xB) << 8. 16 = play/pause.
            if on.contains("sys.blockMusic"), let ns = NSEvent(cgEvent: e), ns.subtype.rawValue == 8 {
                let key = (ns.data1 & 0xFFFF0000) >> 16, down = ((ns.data1 & 0xFF00) >> 8) == 0xA
                if key == 16, down { playPressed = Date() }
            }
            return e
        default:
            return e
        }
    }

    private func keyDown(_ e: CGEvent, now: TimeInterval) -> CGEvent? {
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        let repeating = e.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if on.contains("keys.debounce"), !repeating,
           InputRules.isChatter(sinceLastUp: lastKeyUp[code].map { now - $0 }, limit: InputRules.debounceSeconds) {
            droppedKeys.insert(code); return nil
        }
        let flags = e.flags
        let command = flags.contains(.maskCommand)
        let others = flags.contains(.maskControl) || flags.contains(.maskAlternate) || flags.contains(.maskShift)
        let front = NSWorkspace.shared.frontmostApplication

        if on.contains("clip.plainPaste"), code == kVK_ANSI_V, command, flags.contains(.maskAlternate), flags.contains(.maskShift),
           !flags.contains(.maskControl), !repeating {
            pastePlain(); return nil
        }
        if on.contains("ui.quitTwice"), code == kVK_ANSI_Q, command, !others, !repeating, let front,
           front.bundleIdentifier != "com.apple.finder" {
            let now = Date()
            if InputRules.quitAllowed(lastPress: quitPress?.0, lastApp: quitPress?.1, app: front.bundleIdentifier, now: now) {
                quitPress = nil; return e
            }
            quitPress = (now, front.bundleIdentifier)
            QuitReminder.show(front.localizedName ?? "this app")
            return nil
        }
        if front?.bundleIdentifier == "com.apple.finder", !repeating,
           on.contains("finder.cutPaste") || on.contains("finder.f2Rename") || on.contains("finder.pasteImage") {
            let relevant = code == kVK_F2 || (command && (code == kVK_ANSI_X || code == kVK_ANSI_V))
            guard relevant else { return e }
            let pb = NSPasteboard.general
            let imageOnly = pb.canReadObject(forClasses: [NSImage.self], options: nil)
                && !pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            let action = InputRules.finderKey(code: Int(code), command: command, otherMods: others, editing: Self.editingText(front!.processIdentifier),
                                              cutPending: cutChange.map { $0 == pb.changeCount } ?? false, imageOnly: imageOnly,
                                              cutPaste: on.contains("finder.cutPaste"), f2: on.contains("finder.f2Rename"),
                                              pasteImage: on.contains("finder.pasteImage"))
            switch action {
            case .none: return e
            case .cut:
                // Copy now; the paste that follows moves. The copy bumps the change count by one.
                cutChange = pb.changeCount + 1
                e.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_ANSI_C))
                return e
            case .move:
                cutChange = nil
                e.flags.insert(.maskAlternate)
                return e
            case .rename:
                e.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Return))
                e.flags = []
                return e
            case .pasteImage:
                DispatchQueue.main.async { Self.pasteImageIntoFinder() }
                return nil
            }
        }
        return e
    }

    /// A text field or text area has focus in that app (renaming, the search field…).
    static func editingText(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &role)
        let r = role as? String ?? ""
        return r == kAXTextFieldRole || r == kAXTextAreaRole || r == "AXSearchField" || r == kAXComboBoxRole
    }

    private func postKey(_ code: Int, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let k = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            k?.flags = flags
            k?.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: Clipboard

    private func watchClipboard() {
        let pb = NSPasteboard.general
        if pb.changeCount != lastChange {
            lastChange = pb.changeCount
            lastCopy = Date()
            if on.contains("clip.cleanLinks"), pb.types?.contains(.string) == true,
               !(pb.types?.contains(.init("org.nspasteboard.ConcealedType")) ?? false),
               let s = pb.string(forType: .string), let clean = InputRules.cleanLink(s) {
                pb.clearContents()
                pb.setString(clean, forType: .string)
                lastChange = pb.changeCount
            }
        }
        if on.contains("clip.autoClear"), Date().timeIntervalSince(lastCopy) > Double(MacBehaviours.clearMinutes * 60),
           !(pb.types ?? []).isEmpty {
            clearClipboard()
        }
    }

    private func clearClipboard() {
        NSPasteboard.general.clearContents()
        lastChange = NSPasteboard.general.changeCount
        lastCopy = Date()
    }

    /// Puts plain text on the clipboard, pastes, then puts back what was there.
    private func pastePlain() {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string) else { return }
        let saved = (pb.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        postKey(kVK_ANSI_V, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pb.clearContents()
            pb.writeObjects(saved.map { types in
                let item = NSPasteboardItem()
                for (t, d) in types { item.setData(d, forType: t) }
                return item
            })
            MainActor.assumeIsolated { InputTweaks.shared.lastChange = pb.changeCount }
        }
    }

    /// ⌘V in Finder with a copied picture: saved into the front window's folder as PNG.
    static func pasteImageIntoFinder() {
        guard let image = NSImage(pasteboard: .general), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let r = FolderPreview.finderFolder()
        guard let folder = r.url else { if let p = r.problem { QuitReminder.show(p, plain: true) }; return }
        let url = pastedImageURL(in: folder, now: Date())
        do {
            try png.write(to: url, options: .withoutOverwriting)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { QuitReminder.show("Couldn’t save the picture there: \(error.localizedDescription)", plain: true) }
    }

    /// "Pasted image 2026-10-28 at 19.57.12.png", numbered if taken. Pure apart from checking the folder.
    nonisolated static func pastedImageURL(in folder: URL, now: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Pasted image \(f.string(from: now))"
        var url = folder.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(base) \(n).png"); n += 1 }
        return url
    }

    // MARK: Apps

    /// Chosen apps that had windows and now have none are quit.
    private func quitWindowless() {
        let chosen = Set(MacBehaviours.quitOnCloseApps)
        guard !chosen.isEmpty else { return }
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var count: [pid_t: Int] = [:]
        for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = w[kCGWindowOwnerPID as String] as? pid_t,
               let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Width"] ?? 0) > 100, (b["Height"] ?? 0) > 60 {
                count[pid, default: 0] += 1
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, chosen.contains(id) else { continue }
            let pid = app.processIdentifier, n = count[pid] ?? 0
            if n == 0, (windowsSeen[pid] ?? 0) > 0 { app.terminate() }
            windowsSeen[pid] = n
        }
    }

    private func musicLaunched(_ app: NSRunningApplication?) {
        guard app?.bundleIdentifier == "com.apple.Music", let p = playPressed, Date().timeIntervalSince(p) < 3 else { return }
        playPressed = nil
        app?.forceTerminate()
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { InputTweaks.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    let out = MainActor.assumeIsolated { InputTweaks.shared.handle(type, event) }
    return out.map { Unmanaged.passUnretained($0) }
}

/// A small reminder near the top of the screen ("Press ⌘Q again to quit Safari").
@MainActor
enum QuitReminder {
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?

    static func show(_ text: String, plain: Bool = false) {
        let message = plain ? text : "Press ⌘Q again to quit \(text)"
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        let width = min(520, max(260, label.intrinsicContentSize.width + 48))
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return p
        }()
        panel = p
        let effect = NSVisualEffectView()
        effect.material = .hudWindow; effect.state = .active; effect.wantsLayer = true; effect.layer?.cornerRadius = 12
        label.frame = NSRect(x: 24, y: 14, width: width - 48, height: 24)
        label.sizeToFit(); label.frame.origin.x = (width - label.frame.width) / 2
        let height = max(52, label.frame.height + 28)
        label.frame.origin.y = (height - label.frame.height) / 2
        effect.addSubview(label)
        p.contentView = effect
        let screen = NSScreen.main?.visibleFrame ?? .zero
        p.setFrame(NSRect(x: screen.midX - width / 2, y: screen.maxY - height - 60, width: width, height: height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        hide?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { panel?.orderOut(nil) } }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (plain ? 3 : InputRules.quitWindow), execute: work)
    }
}
