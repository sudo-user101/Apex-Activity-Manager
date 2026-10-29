import AppKit
import ApplicationServices
import SwiftUI

/// Utilities › Clean Keyboard: locks the keyboard (every key, the volume and
/// brightness keys included, and if asked the trackpad and mouse) so it can
/// be wiped without typing anything. A black screen (crumbs and smudges show
/// up) or a small notice says how long is left; it always unlocks by itself
/// when the time is up, and Done ends it sooner while the pointer still works.
/// Needs Accessibility. Settings in UserDefaults `cleanKeyboard.*`.
@MainActor @Observable
final class CleanKeyboard {
    static let shared = CleanKeyboard()

    enum Keys {
        static let enabled = "cleanKeyboard", seconds = "cleanKeyboard.seconds", black = "cleanKeyboard.blackScreen"
        static let pointer = "cleanKeyboard.lockPointer"
    }
    static let choices: [(title: String, seconds: Int)] = [("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300)]

    static var seconds: Int { let s = UserDefaults.standard.integer(forKey: Keys.seconds); return s > 0 ? s : 60 }
    static var blackScreen: Bool { UserDefaults.standard.object(forKey: Keys.black) as? Bool ?? true }
    static var lockPointer: Bool { UserDefaults.standard.bool(forKey: Keys.pointer) }

    private(set) var isOn = false
    private(set) var endsAt: Date?
    private(set) var problem: String?
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var windows: [NSWindow] = []
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored fileprivate var pointerLocked = false

    var remaining: Int { max(0, Int((endsAt?.timeIntervalSinceNow ?? 0).rounded(.up))) }

    /// What the lock swallows. Pure: tested.
    nonisolated static func blocks(_ type: CGEventType, lockPointer: Bool) -> Bool {
        switch type {
        case .keyDown, .keyUp, .flagsChanged: return true
        case CGEventType(rawValue: 14)!: return true          // media, volume, brightness keys
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            return lockPointer
        case CGEventType(rawValue: 29)!, CGEventType(rawValue: 30)!, CGEventType(rawValue: 31)!:   // gestures, magnify, swipe
            return lockPointer
        default: return false
        }
    }

    /// "0:45". Pure: tested.
    nonisolated static func clock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    func start() {
        guard !isOn else { return }
        guard AXIsProcessTrusted() else {
            AccessibilityAccess.ask()
            problem = "Allow Apex under System Settings › Privacy & Security › Accessibility first; macOS doesn’t let an app hold back keys without it."
            return
        }
        pointerLocked = Self.lockPointer
        var mask: CGEventMask = 0
        for raw in 0...31 where Self.blocks(CGEventType(rawValue: UInt32(raw)) ?? .null, lockPointer: pointerLocked) { mask |= 1 << CGEventMask(raw) }
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: cleanTapCallback, userInfo: nil) else {
            problem = "macOS didn’t let Apex lock the keyboard. Check Accessibility in System Settings."
            return
        }
        problem = nil
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        isOn = true
        endsAt = Date().addingTimeInterval(TimeInterval(Self.seconds))
        showWindows()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let c = CleanKeyboard.shared
                if c.remaining == 0 { c.stop() }
            }
        }
    }

    func stop() {
        ticker?.invalidate(); ticker = nil
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        isOn = false
        endsAt = nil
    }

    fileprivate func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }

    // MARK: The screen while cleaning

    private func showWindows() {
        let black = Self.blackScreen
        for screen in black ? NSScreen.screens : [NSScreen.main].compactMap({ $0 }) {
            let frame: NSRect = black ? screen.frame
                : NSRect(x: screen.visibleFrame.midX - 200, y: screen.visibleFrame.maxY - 150, width: 400, height: 120)
            let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.level = black ? .screenSaver : .statusBar
            w.isOpaque = black
            w.backgroundColor = black ? .black : .clear
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.hidesOnDeactivate = false
            w.contentView = NSHostingView(rootView: CleanKeyboardNotice(black: black))
            w.setFrame(frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
    }
}

private func cleanTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { CleanKeyboard.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    let locked = MainActor.assumeIsolated { CleanKeyboard.shared.pointerLocked }
    return CleanKeyboard.blocks(type, lockPointer: locked) ? nil : Unmanaged.passUnretained(event)
}

/// What's on screen while the keyboard is locked.
private struct CleanKeyboardNotice: View {
    let black: Bool
    private var cleaner: CleanKeyboard { CleanKeyboard.shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let card = VStack(spacing: black ? 14 : 8) {
                Image(systemName: "keyboard").font(.system(size: black ? 54 : 26, weight: .light))
                Text("Keyboard locked for cleaning").font(black ? .title.weight(.semibold) : .headline)
                Text(cleaner.isOn ? "Unlocks by itself in \(CleanKeyboard.clock(cleaner.remaining))" : "Unlocked")
                    .font(black ? .title3 : .callout).monospacedDigit().opacity(0.75)
                if !CleanKeyboard.lockPointer {
                    Button("Done") { cleaner.stop() }
                        .controlSize(black ? .large : .regular)
                }
            }
            .foregroundStyle(black ? Color.white.opacity(0.85) : .primary)
            if black {
                card.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
            } else {
                card.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}
