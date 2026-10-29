import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Utilities › Window Manager: put windows in place with the keyboard or by
/// dragging them to a screen edge or corner, save and bring back whole
/// layouts of apps. Windows are moved through Accessibility (as every window
/// manager on macOS does); shortcuts are global hot keys; dragging is watched
/// with a mouse monitor and a footprint shows where the window will go.
/// Settings in UserDefaults `windowManager.*`.

enum WindowAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf, centerHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case firstFourth, secondFourth, thirdFourth, lastFourth
    case topLeftSixth, topCenterSixth, topRightSixth, bottomLeftSixth, bottomCenterSixth, bottomRightSixth
    case maximize, almostMaximize, maximizeHeight, center, larger, smaller, restore
    case nextDisplay, previousDisplay
    case tileAll, cascadeApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: "Left half"; case .rightHalf: "Right half"; case .topHalf: "Top half"; case .bottomHalf: "Bottom half"
        case .centerHalf: "Centre half"
        case .topLeft: "Top left quarter"; case .topRight: "Top right quarter"; case .bottomLeft: "Bottom left quarter"
        case .bottomRight: "Bottom right quarter"
        case .firstThird: "First third"; case .centerThird: "Centre third"; case .lastThird: "Last third"
        case .firstTwoThirds: "First two thirds"; case .lastTwoThirds: "Last two thirds"
        case .firstFourth: "First fourth"; case .secondFourth: "Second fourth"; case .thirdFourth: "Third fourth"; case .lastFourth: "Last fourth"
        case .topLeftSixth: "Top left sixth"; case .topCenterSixth: "Top centre sixth"; case .topRightSixth: "Top right sixth"
        case .bottomLeftSixth: "Bottom left sixth"; case .bottomCenterSixth: "Bottom centre sixth"; case .bottomRightSixth: "Bottom right sixth"
        case .maximize: "Fill the screen"; case .almostMaximize: "Almost fill the screen"; case .maximizeHeight: "Full height"
        case .center: "Centre"; case .larger: "Bigger"; case .smaller: "Smaller"; case .restore: "Back to how it was"
        case .nextDisplay: "Next display"; case .previousDisplay: "Previous display"
        case .tileAll: "Tile every window on this screen"; case .cascadeApp: "Cascade this app’s windows"
        }
    }

    var group: String {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf, .centerHalf: "Halves"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: "Quarters"
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds: "Thirds"
        case .firstFourth, .secondFourth, .thirdFourth, .lastFourth: "Fourths"
        case .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth: "Sixths"
        case .maximize, .almostMaximize, .maximizeHeight, .center, .larger, .smaller, .restore: "Size"
        case .nextDisplay, .previousDisplay: "Displays"
        case .tileAll, .cascadeApp: "Many windows"
        }
    }

    /// The default key (with the chosen modifiers), as the well-known window managers use. Nil = no shortcut until chosen.
    var key: (code: Int, shift: Bool, label: String)? {
        switch self {
        case .leftHalf: (kVK_LeftArrow, false, "←"); case .rightHalf: (kVK_RightArrow, false, "→")
        case .topHalf: (kVK_UpArrow, false, "↑"); case .bottomHalf: (kVK_DownArrow, false, "↓")
        case .topLeft: (kVK_ANSI_U, false, "U"); case .topRight: (kVK_ANSI_I, false, "I")
        case .bottomLeft: (kVK_ANSI_J, false, "J"); case .bottomRight: (kVK_ANSI_K, false, "K")
        case .firstThird: (kVK_ANSI_D, false, "D"); case .centerThird: (kVK_ANSI_F, false, "F"); case .lastThird: (kVK_ANSI_G, false, "G")
        case .firstTwoThirds: (kVK_ANSI_E, false, "E"); case .lastTwoThirds: (kVK_ANSI_T, false, "T")
        case .maximize: (kVK_Return, false, "Return"); case .maximizeHeight: (kVK_UpArrow, true, "⇧↑")
        case .center: (kVK_ANSI_C, false, "C"); case .larger: (kVK_ANSI_Equal, false, "="); case .smaller: (kVK_ANSI_Minus, false, "−")
        case .restore: (kVK_Delete, false, "⌫")
        case .nextDisplay: (kVK_RightArrow, true, "⇧→"); case .previousDisplay: (kVK_LeftArrow, true, "⇧←")
        case .tileAll: (kVK_ANSI_A, true, "⇧A"); case .cascadeApp: (kVK_ANSI_C, true, "⇧C")
        default: nil
        }
    }
}

/// The geometry, apart from macOS. Rectangles use Accessibility's top-left origin. Pure: tested.
enum WindowGeometry {
    /// Where `action` puts a window in `area` (a screen's usable part), `gap` points between windows and edges.
    static func rect(_ a: WindowAction, in area: CGRect, current: CGRect, gap: CGFloat = 0) -> CGRect {
        let portrait = area.height > area.width
        func part(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            let r = CGRect(x: area.minX + area.width * x, y: area.minY + area.height * y, width: area.width * w, height: area.height * h)
            return inset(r, in: area, gap: gap)
        }
        // On a portrait screen, thirds and fourths run top to bottom.
        func slice(_ start: CGFloat, _ length: CGFloat) -> CGRect { portrait ? part(0, start, 1, length) : part(start, 0, length, 1) }
        switch a {
        case .leftHalf: return part(0, 0, 0.5, 1)
        case .rightHalf: return part(0.5, 0, 0.5, 1)
        case .topHalf: return part(0, 0, 1, 0.5)
        case .bottomHalf: return part(0, 0.5, 1, 0.5)
        case .centerHalf: return part(0.25, 0, 0.5, 1)
        case .topLeft: return part(0, 0, 0.5, 0.5)
        case .topRight: return part(0.5, 0, 0.5, 0.5)
        case .bottomLeft: return part(0, 0.5, 0.5, 0.5)
        case .bottomRight: return part(0.5, 0.5, 0.5, 0.5)
        case .firstThird: return slice(0, 1.0 / 3)
        case .centerThird: return slice(1.0 / 3, 1.0 / 3)
        case .lastThird: return slice(2.0 / 3, 1.0 / 3)
        case .firstTwoThirds: return slice(0, 2.0 / 3)
        case .lastTwoThirds: return slice(1.0 / 3, 2.0 / 3)
        case .firstFourth: return slice(0, 0.25)
        case .secondFourth: return slice(0.25, 0.25)
        case .thirdFourth: return slice(0.5, 0.25)
        case .lastFourth: return slice(0.75, 0.25)
        case .topLeftSixth: return part(0, 0, 1.0 / 3, 0.5)
        case .topCenterSixth: return part(1.0 / 3, 0, 1.0 / 3, 0.5)
        case .topRightSixth: return part(2.0 / 3, 0, 1.0 / 3, 0.5)
        case .bottomLeftSixth: return part(0, 0.5, 1.0 / 3, 0.5)
        case .bottomCenterSixth: return part(1.0 / 3, 0.5, 1.0 / 3, 0.5)
        case .bottomRightSixth: return part(2.0 / 3, 0.5, 1.0 / 3, 0.5)
        case .maximize: return inset(area, in: area, gap: gap)
        case .almostMaximize: return part(0.05, 0.05, 0.9, 0.9)
        case .maximizeHeight: return CGRect(x: current.minX, y: area.minY + gap, width: current.width, height: area.height - gap * 2)
        case .center:
            let w = min(current.width, area.width), h = min(current.height, area.height)
            return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
        case .larger, .smaller:
            let step: CGFloat = a == .larger ? 30 : -30
            let w = min(area.width, max(200, current.width + step * 2)), h = min(area.height, max(150, current.height + step * 2))
            var r = CGRect(x: current.midX - w / 2, y: current.midY - h / 2, width: w, height: h)
            r.origin.x = min(max(r.minX, area.minX), area.maxX - w)
            r.origin.y = min(max(r.minY, area.minY), area.maxY - h)
            return r.integral
        case .restore, .nextDisplay, .previousDisplay, .tileAll, .cascadeApp:
            return current
        }
    }

    /// Gaps: half a gap where windows meet, a whole one at the screen's edges.
    static func inset(_ r: CGRect, in area: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0 else { return snapped(r) }
        let e: CGFloat = 1
        let left = abs(r.minX - area.minX) < e ? gap : gap / 2, right = abs(r.maxX - area.maxX) < e ? gap : gap / 2
        let top = abs(r.minY - area.minY) < e ? gap : gap / 2, bottom = abs(r.maxY - area.maxY) < e ? gap : gap / 2
        return snapped(CGRect(x: r.minX + left, y: r.minY + top, width: r.width - left - right, height: r.height - top - bottom))
    }

    /// Each edge to the nearest point, so windows side by side meet exactly.
    static func snapped(_ r: CGRect) -> CGRect {
        let x0 = r.minX.rounded(), y0 = r.minY.rounded(), x1 = r.maxX.rounded(), y1 = r.maxY.rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Pressing the same shortcut again: halves grow to two thirds then shrink
    /// to a third; thirds move along. Pure: tested.
    static func cycled(_ a: WindowAction, step: Int) -> (action: WindowAction, fraction: CGFloat?) {
        switch a {
        case .leftHalf, .rightHalf:
            let f: [CGFloat] = [0.5, 2.0 / 3, 1.0 / 3]
            return (a, f[step % 3])
        case .firstThird, .centerThird, .lastThird:
            let order: [WindowAction] = [.firstThird, .centerThird, .lastThird]
            let start = order.firstIndex(of: a) ?? 0
            return (order[(start + step) % 3], nil)
        default: return (a, nil)
        }
    }

    /// A half at a width other than ½ (for cycling).
    static func half(_ a: WindowAction, fraction: CGFloat, in area: CGRect, gap: CGFloat) -> CGRect {
        let w = area.width * fraction
        let r = a == .leftHalf ? CGRect(x: area.minX, y: area.minY, width: w, height: area.height)
                               : CGRect(x: area.maxX - w, y: area.minY, width: w, height: area.height)
        return inset(r, in: area, gap: gap)
    }

    /// Dragging a window with the pointer at `p` (top-left origin) near a
    /// screen's edge: where it would snap. Corners are quarters, sides
    /// halves, the top fills the screen, the bottom thirds (two thirds with
    /// ⇧). Nil away from the edges. Pure: tested.
    static func snap(at p: CGPoint, screen: CGRect, shift: Bool, margin: CGFloat = 6, corner: CGFloat = 40) -> WindowAction? {
        let nearL = p.x <= screen.minX + margin, nearR = p.x >= screen.maxX - margin
        let nearT = p.y <= screen.minY + margin, nearB = p.y >= screen.maxY - margin
        let inTopBand = p.y <= screen.minY + corner, inBottomBand = p.y >= screen.maxY - corner
        let inLeftBand = p.x <= screen.minX + corner, inRightBand = p.x >= screen.maxX - corner
        if (nearL && inTopBand) || (nearT && inLeftBand) { return .topLeft }
        if (nearR && inTopBand) || (nearT && inRightBand) { return .topRight }
        if (nearL && inBottomBand) || (nearB && inLeftBand) { return .bottomLeft }
        if (nearR && inBottomBand) || (nearB && inRightBand) { return .bottomRight }
        if nearL { return .leftHalf }
        if nearR { return .rightHalf }
        if nearT { return .maximize }
        if nearB {
            let x = (p.x - screen.minX) / screen.width
            if shift { return x < 0.5 ? .firstTwoThirds : .lastTwoThirds }
            return x < 1.0 / 3 ? .firstThird : x < 2.0 / 3 ? .centerThird : .lastThird
        }
        return nil
    }

    /// Every window in a grid on one screen, as even as the count allows. Pure: tested.
    static func tiles(count: Int, in area: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let cols = Int(ceil(sqrt(Double(count)))), rows = Int(ceil(Double(count) / Double(cols)))
        var out: [CGRect] = []
        for i in 0..<count {
            let r = i / cols, c = i % cols
            let inRow = r == rows - 1 ? count - cols * (rows - 1) : cols       // the last row shares the width
            let w = area.width / CGFloat(inRow), h = area.height / CGFloat(rows)
            out.append(inset(CGRect(x: area.minX + w * CGFloat(c), y: area.minY + h * CGFloat(r), width: w, height: h), in: area, gap: gap))
        }
        return out
    }
}

/// A saved layout: where each app's windows were.
struct WindowWorkspace: Codable, Equatable, Sendable {
    struct Place: Codable, Equatable, Sendable { var app: String; var index: Int; var title: String; var frame: CGRect }
    var name: String
    var places: [Place]
}

@MainActor @Observable
final class WindowManager {
    static let shared = WindowManager()

    enum Keys {
        static let enabled = "windowManager", shortcuts = "windowManager.shortcuts", modifiers = "windowManager.modifiers"
        static let snapping = "windowManager.snapping", gap = "windowManager.gap", cycle = "windowManager.cycle"
        static let restoreOnDrag = "windowManager.restoreOnDrag", ignored = "windowManager.ignored", off = "windowManager.offActions"
        static let workspaces = "windowManager.workspaces"
    }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: Keys.enabled) }
    static var gap: CGFloat { CGFloat(UserDefaults.standard.integer(forKey: Keys.gap)) }
    static var modifiers: String { UserDefaults.standard.string(forKey: Keys.modifiers) ?? "ctrlOpt" }
    static var ignored: [String] { UserDefaults.standard.stringArray(forKey: Keys.ignored) ?? [] }
    static var offActions: Set<String> { Set(UserDefaults.standard.stringArray(forKey: Keys.off) ?? []) }
    static func flag(_ key: String, _ fallback: Bool = true) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }

    static func modifierMask(_ m: String) -> UInt32 {
        switch m {
        case "ctrlOptCmd": UInt32(controlKey | optionKey | cmdKey)
        case "ctrlCmd": UInt32(controlKey | cmdKey)
        default: UInt32(controlKey | optionKey)
        }
    }
    static func modifierLabel(_ m: String) -> String { m == "ctrlOptCmd" ? "⌃⌥⌘" : m == "ctrlCmd" ? "⌃⌘" : "⌃⌥" }

    private(set) var workspaces: [WindowWorkspace] = []
    var message: String?

    @ObservationIgnored private var before: [Int: CGRect] = [:]
    @ObservationIgnored private var snapped: [Int: CGRect] = [:]
    @ObservationIgnored private var last: (action: WindowAction, window: Int, frame: CGRect, step: Int)?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var drag: (window: AXUIElement, key: Int, start: CGRect, moved: Bool)?
    @ObservationIgnored private var footprint: NSPanel?
    @ObservationIgnored private var target: (action: WindowAction, rect: CGRect, area: CGRect)?

    private init() {
        if let d = UserDefaults.standard.data(forKey: Keys.workspaces), let w = try? JSONDecoder().decode([WindowWorkspace].self, from: d) { workspaces = w }
    }

    /// Registers the shortcuts and the drag watcher to match the settings.
    func apply() {
        // Hot key ids 100… are this utility's.
        let on = Self.enabled
        let base = Self.modifierMask(Self.modifiers), off = Self.offActions
        let useKeys = on && Self.flag(Keys.shortcuts)
        for (i, a) in WindowAction.allCases.enumerated() {
            let combo: (UInt32, UInt32)? = useKeys && !off.contains(a.rawValue)
                ? a.key.map { (UInt32($0.code), base | ($0.shift ? UInt32(shiftKey) : 0)) } : nil
            _ = HotKeyCenter.set(id: UInt32(100 + i), combo: combo) { WindowManager.shared.perform(a) }
        }
        _ = HotKeyCenter.set(id: 170, combo: useKeys ? (UInt32(kVK_Space), base) : nil) { WindowThrow.shared.toggle() }
        for n in 1...4 {
            let combo: (UInt32, UInt32)? = on ? (UInt32([kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4][n - 1]), UInt32(controlKey | optionKey | cmdKey)) : nil
            _ = HotKeyCenter.set(id: UInt32(160 + n), combo: combo) { WindowManager.shared.restoreWorkspace(n - 1) }
        }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if on, Self.flag(Keys.snapping) {
            for (mask, handler) in [(NSEvent.EventTypeMask.leftMouseDown, mouseDown), (.leftMouseDragged, mouseDragged), (.leftMouseUp, mouseUp)] {
                if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { e in MainActor.assumeIsolated { handler(e) } }) { monitors.append(m) }
            }
        }
    }

    // MARK: Screens (Accessibility's top-left coordinates)

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func usable(_ s: NSScreen) -> CGRect {
        let v = s.visibleFrame
        return CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
    }

    private func whole(_ s: NSScreen) -> CGRect {
        let f = s.frame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    private func screen(for r: CGRect) -> NSScreen? {
        NSScreen.screens.max { usable($0).intersection(r).area < usable($1).intersection(r).area }
    }

    // MARK: Acting on the front window

    private func frontWindow() -> (AXUIElement, NSRunningApplication)? {
        guard AXIsProcessTrusted() else {
            AccessibilityAccess.waitThenStart()
            message = "Allow Apex under System Settings › Privacy & Security › Accessibility to move windows."
            return nil
        }
        guard let app = NSWorkspace.shared.frontmostApplication, !Self.ignored.contains(app.bundleIdentifier ?? "") else { return nil }
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &w) == .success,
              let win = w else { return nil }
        return (win as! AXUIElement, app)
    }

    func perform(_ a: WindowAction) {
        guard let (window, app) = frontWindow(), let current = WindowAX.frame(window), let scr = screen(for: current) else { return }
        let key = Int(CFHash(window)), gap = Self.gap
        switch a {
        case .restore:
            if let old = before.removeValue(forKey: key) { WindowAX.setFrame(window, old) }
            snapped[key] = nil
            return
        case .nextDisplay, .previousDisplay:
            let screens = NSScreen.screens
            guard screens.count > 1, let i = screens.firstIndex(of: scr) else { return }
            let next = screens[(i + (a == .nextDisplay ? 1 : screens.count - 1)) % screens.count]
            let from = usable(scr), to = usable(next)
            // Same place and size relative to the screen, kept inside it.
            let sx = to.width / from.width, sy = to.height / from.height
            let r = CGRect(x: to.minX + (current.minX - from.minX) * sx, y: to.minY + (current.minY - from.minY) * sy,
                           width: current.width * sx, height: current.height * sy).integral
            remember(key, current); WindowAX.setFrame(window, r)
            return
        case .tileAll:
            let area = usable(scr)
            let windows = WindowAX.visibleWindows(on: area).filter { !Self.ignored.contains($0.app) }
            for (w, r) in zip(windows, WindowGeometry.tiles(count: windows.count, in: area, gap: gap)) {
                if let f = WindowAX.frame(w.element) { remember(Int(CFHash(w.element)), f) }
                WindowAX.setFrame(w.element, r)
            }
            return
        case .cascadeApp:
            let area = usable(scr)
            let size = CGSize(width: area.width * 0.6, height: area.height * 0.7)
            for (i, w) in WindowAX.windows(of: app.processIdentifier).enumerated() {
                WindowAX.setFrame(w, CGRect(x: area.minX + 40 + CGFloat(i) * 28, y: area.minY + 20 + CGFloat(i) * 28, width: size.width, height: size.height))
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            }
            return
        default: break
        }
        let area = usable(scr)
        var action = a, rect: CGRect
        // The same shortcut again on the same window, untouched since: the next size.
        var step = 0
        if Self.flag(Keys.cycle), let l = last, l.window == key, l.frame.equalTo(current), WindowGeometry.cycled(a, step: 0).action == WindowGeometry.cycled(l.action, step: 0).action || l.action == a {
            step = l.step + 1
        }
        let c = WindowGeometry.cycled(a, step: step)
        action = c.action
        if let f = c.fraction, f != 0.5 { rect = WindowGeometry.half(action, fraction: f, in: area, gap: gap) }
        else { rect = WindowGeometry.rect(action, in: area, current: current, gap: gap) }
        remember(key, current)
        WindowAX.setFrame(window, rect)
        let landed = WindowAX.frame(window) ?? rect
        snapped[key] = landed
        last = (a, key, landed, step)
    }

    private func remember(_ key: Int, _ frame: CGRect) { if snapped[key] == nil || before[key] == nil { before[key] = frame } }

    // MARK: Drag to snap

    private func mouseDown(_ e: NSEvent) {
        drag = nil
        guard !Self.ignored.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""),
              let (w, _) = frontWindow(), let f = WindowAX.frame(w) else { return }
        let p = topLeft(NSEvent.mouseLocation)
        // Only a press in the window's title area starts a window drag.
        guard f.contains(p), p.y - f.minY < 40 else { return }
        drag = (w, Int(CFHash(w)), f, false)
    }

    private func mouseDragged(_ e: NSEvent) {
        guard var d = drag, let now = WindowAX.frame(d.window) else { return }
        let moved = abs(now.minX - d.start.minX) + abs(now.minY - d.start.minY) > 3 && abs(now.width - d.start.width) < 2
        guard moved else { return }
        if !d.moved {
            d.moved = true
            drag = d
            // A snapped window dragged away goes back to its size from before.
            if Self.flag(Keys.restoreOnDrag), let old = before[d.key], snapped[d.key] != nil {
                snapped[d.key] = nil
                let p = topLeft(NSEvent.mouseLocation)
                let ratio = (p.x - now.minX) / max(now.width, 1)
                WindowAX.setFrame(d.window, CGRect(x: p.x - old.width * ratio, y: now.minY, width: old.width, height: old.height))
                before[d.key] = nil
            }
        }
        let p = topLeft(NSEvent.mouseLocation)
        guard let scr = NSScreen.screens.first(where: { whole($0).contains(p) }) else { hideFootprint(); return }
        let shift = NSEvent.modifierFlags.contains(.shift)
        if let a = WindowGeometry.snap(at: p, screen: whole(scr), shift: shift) {
            let area = usable(scr)
            let r = WindowGeometry.rect(a, in: area, current: now, gap: Self.gap)
            if target?.rect != r { showFootprint(r) }
            target = (a, r, area)
        } else { target = nil; hideFootprint() }
    }

    private func mouseUp(_ e: NSEvent) {
        defer { drag = nil; target = nil; hideFootprint() }
        guard let d = drag, d.moved, let t = target else { return }
        remember(d.key, d.start)
        // Let the drag finish first, then place the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            WindowAX.setFrame(d.window, t.rect)
            MainActor.assumeIsolated { WindowManager.shared.snapped[d.key] = t.rect }
        }
    }

    private func topLeft(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    private func showFootprint(_ r: CGRect) {
        let p = footprint ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating; p.isOpaque = false; p.backgroundColor = .clear; p.ignoresMouseEvents = true; p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let v = NSVisualEffectView()
            v.material = .selection; v.state = .active; v.blendingMode = .behindWindow; v.wantsLayer = true
            v.layer?.cornerRadius = 12; v.layer?.borderWidth = 2
            v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            v.alphaValue = 0.55
            p.contentView = v
            return p
        }()
        footprint = p
        // Back to Cocoa's bottom-left coordinates.
        let frame = NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        p.setFrame(frame, display: true, animate: p.isVisible)
        p.orderFrontRegardless()
    }

    private func hideFootprint() { footprint?.orderOut(nil) }

    // MARK: Workspaces

    /// Saves where every visible window of every app is.
    func saveWorkspace(_ slot: Int, name: String) {
        var places: [WindowWorkspace.Place] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
            guard let id = app.bundleIdentifier else { continue }
            for (i, w) in WindowAX.windows(of: app.processIdentifier).enumerated() {
                guard let f = WindowAX.frame(w), !WindowAX.bool(w, kAXMinimizedAttribute) else { continue }
                places.append(.init(app: id, index: i, title: WindowAX.string(w, kAXTitleAttribute) ?? "", frame: f))
            }
        }
        var list = workspaces
        while list.count <= slot { list.append(WindowWorkspace(name: "Layout \(list.count + 1)", places: [])) }
        list[slot] = WindowWorkspace(name: name, places: places)
        workspaces = list
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: Keys.workspaces) }
        message = "Saved “\(name)”: \(places.count) window\(places.count == 1 ? "" : "s")."
    }

    /// Puts windows back where a saved layout had them (by app and title, then order).
    func restoreWorkspace(_ slot: Int) {
        guard workspaces.indices.contains(slot), !workspaces[slot].places.isEmpty, AXIsProcessTrusted() else { return }
        let w = workspaces[slot]
        var moved = 0
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            let places = w.places.filter { $0.app == id }
            guard !places.isEmpty else { continue }
            var windows = WindowAX.windows(of: app.processIdentifier)
            for place in places {
                let match = windows.firstIndex { !place.title.isEmpty && WindowAX.string($0, kAXTitleAttribute) == place.title }
                    ?? (windows.indices.contains(place.index) ? place.index : windows.indices.first)
                guard let i = match else { break }
                WindowAX.setFrame(windows[i], place.frame)
                windows.remove(at: i)
                moved += 1
            }
        }
        QuitReminder.show("“\(w.name)”: \(moved) window\(moved == 1 ? "" : "s") put back", plain: true)
    }

    func deleteWorkspace(_ slot: Int) {
        guard workspaces.indices.contains(slot) else { return }
        workspaces[slot].places = []
        if let d = try? JSONEncoder().encode(workspaces) { UserDefaults.standard.set(d, forKey: Keys.workspaces) }
    }
}

/// Reading and moving windows through Accessibility.
@MainActor
enum WindowAX {
    static func frame(_ w: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        var point = r.origin, size = r.size
        // Size, move, size again: some apps clamp the size to the old screen until moved.
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s) }
        if let p = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s) }
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        var list: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &list)
        return ((list as? [AXUIElement]) ?? []).filter { string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String }
    }

    /// Standard, not minimized windows of visible apps that sit mostly on `area`, front to back.
    static func visibleWindows(on area: CGRect) -> [(element: AXUIElement, app: String)] {
        var out: [(AXUIElement, String)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
            for w in windows(of: app.processIdentifier) where !bool(w, kAXMinimizedAttribute) {
                if let f = frame(w), f.intersection(area).area > f.area / 2 { out.append((w, app.bundleIdentifier ?? "")) }
            }
        }
        return out
    }

    static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v as? String : nil
    }

    static func bool(_ e: AXUIElement, _ attr: String) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? (v as? Bool ?? false) : false
    }
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

/// Every position at once (⌃⌥Space, or the chosen keys + Space): a small
/// picture of each, with a key to press or a click. The window in front
/// stays in front, so the choice goes to it.
@MainActor
final class WindowThrow {
    static let shared = WindowThrow()
    private var panel: NSPanel?
    private var keys: Any?

    /// The keys shown on the choices, in order. Pure: tested.
    nonisolated static let keyLabels = Array("1234567890QWERTYUIOPASDFGHJKLZXCVBNM").map(String.init)
    nonisolated static var choices: [WindowAction] { WindowAction.allCases.filter { $0 != .restore } + [.restore] }

    func toggle() { panel?.isVisible == true ? close() : show() }

    func show() {
        let p = panel ?? {
            let p = KeyablePanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
            p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true; p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: WindowThrowView { a in WindowThrow.shared.pick(a) })
            return p
        }()
        panel = p
        let size = NSSize(width: 660, height: 620)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let f = screen?.visibleFrame ?? .zero
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless(); p.makeKey()
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated {
                guard e.window === WindowThrow.shared.panel else { return e }
                if e.keyCode == 53 { WindowThrow.shared.close(); return nil }
                let ch = (e.charactersIgnoringModifiers ?? "").uppercased()
                if let i = Self.keyLabels.firstIndex(of: ch), Self.choices.indices.contains(i) { WindowThrow.shared.pick(Self.choices[i]); return nil }
                return e
            }
        }
    }

    func pick(_ a: WindowAction) { close(); WindowManager.shared.perform(a) }

    func close() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        panel?.orderOut(nil)
    }
}

private struct WindowThrowView: View {
    var pick: (WindowAction) -> Void
    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Put the window…").font(.headline)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(WindowThrow.choices.enumerated()), id: \.element) { i, a in
                        Button { pick(a) } label: {
                            VStack(spacing: 4) {
                                ZStack(alignment: .topLeading) {
                                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 64, height: 40)
                                    let r = WindowGeometry.rect(a, in: CGRect(x: 0, y: 0, width: 64, height: 40),
                                                                current: CGRect(x: 16, y: 10, width: 32, height: 20), gap: 1.5)
                                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.85))
                                        .frame(width: max(4, r.width), height: max(4, r.height)).offset(x: r.minX, y: r.minY)
                                }
                                .frame(width: 64, height: 40)
                                Text(a.title).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                                if WindowThrow.keyLabels.indices.contains(i) {
                                    Text(WindowThrow.keyLabels[i]).font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 92, height: 92)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("Press the key under a position, or click it. Esc closes.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}
