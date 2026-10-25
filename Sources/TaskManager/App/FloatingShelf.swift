import AppKit
import SwiftUI

/// Pops the shelf up next to the pointer as soon as a file drag starts
/// anywhere on the Mac, and hides it again if nothing was dropped.
///
/// Detection: a global mouse monitor (no special permission for mouse events)
/// notices a drag, and the system drag pasteboard's change count tells a file
/// drag apart from selecting text or moving a window. The check is one integer
/// comparison per mouse-drag event.
@MainActor
final class FloatingShelf {
    static let shared = FloatingShelf()

    var enabled: Bool = UserDefaults.standard.object(forKey: "floatingShelf") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "floatingShelf"); enabled ? start() : stop() }
    }

    private var monitors: [Any] = []
    private var panel: NSPanel?
    private var baseline = 0
    private var shownForDrag = false
    private var itemsAtShow = 0
    private var fileDrag = false
    private var shakeX = ShakeDetector()
    private var shakeY = ShakeDetector()
    /// Bumped on every show, so a fade-out or delayed hide that started
    /// earlier never hides a shelf that has come back since.
    private var generation = 0
    /// Closed with ×: the new shelf starts once the fade-out is over (or at the
    /// next show, if that comes first), so the closing shelf doesn't flash empty.
    private var pendingNewShelf = false
    /// Apex is moving the panel itself (appearing, gliding, tucking away):
    /// those moves must not count as the user letting go at the edge.
    private var moving = false

    func start() {
        guard enabled, monitors.isEmpty else { return }
        let drag = NSPasteboard(name: .drag)
        baseline = drag.changeCount
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { _ in
            MainActor.assumeIsolated { FloatingShelf.shared.mouseDown() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { e in
            let t = e.timestamp
            MainActor.assumeIsolated { FloatingShelf.shared.dragged(at: t) }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { _ in
            MainActor.assumeIsolated { FloatingShelf.shared.dragEnded() }
        }) { monitors.append(m) }
        updateSideHandle()
        // Test switch: APEX_OPEN=shelf shows the floating shelf at launch (no drag needed).
        if ["shelf", "shelfminimize"].contains(ProcessInfo.processInfo.environment["APEX_OPEN"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let f = NSScreen.main?.visibleFrame ?? .zero
                FloatingShelf.shared.show(near: NSPoint(x: f.midX - 200, y: f.midY))
            }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        handlePanel?.orderOut(nil)
        close()
    }

    private func mouseDown() {
        baseline = NSPasteboard(name: .drag).changeCount
        fileDrag = false
        shakeX.reset(); shakeY.reset()
    }

    private func dragged(at time: TimeInterval) {
        if !fileDrag {
            let pb = NSPasteboard(name: .drag)
            guard pb.changeCount != baseline,
                  pb.types?.contains(.fileURL) == true || pb.types?.contains(.png) == true || pb.types?.contains(.tiff) == true
            else { return }
            fileDrag = true
        }
        let point = NSEvent.mouseLocation
        // Wiggling the file starts a new, empty shelf right here: the old one's
        // items move to Recent shelves, even if it was showing or tucked away.
        let shookX = shakeX.add(point.x, at: time)
        let shookY = shakeY.add(point.y, at: time)
        if shookX || shookY {
            ShelfStore.shared.newShelf()
            shownForDrag = true
            show(near: point)
            return
        }
        guard !shownForDrag else { return }
        // Already up (or tucked at the edge): leave it; dragging onto the handle brings it out.
        if panel?.isVisible == true { return }
        shownForDrag = true
        show(near: point)
    }

    private func dragEnded() {
        fileDrag = false
        guard shownForDrag else { return }
        shownForDrag = false
        baseline = NSPasteboard(name: .drag).changeCount
        // Give the drop a moment to land; keep the shelf up if something did.
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard gen == self.generation, !self.shownForDrag else { return }
            if ShelfStore.shared.shown.items.count == self.itemsAtShow { self.close() }
        }
    }

    private func show(near point: NSPoint) {
        generation += 1
        startPendingShelf()
        itemsAtShow = ShelfStore.shared.shown.items.count
        let p = panel ?? makePanel()
        panel = p
        let wasUp = p.isVisible && p.alphaValue > 0.5      // not while fading out
        state.docked = false
        // Beside the pointer, kept on the screen it's on.
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: point.x + 40, y: point.y - size.height / 2)
        if let f = screen?.visibleFrame {
            if origin.x + size.width > f.maxX { origin.x = point.x - size.width - 40 }
            origin.x = max(f.minX + 8, origin.x)
            origin.y = min(max(f.minY + 8, origin.y), f.maxY - size.height - 8)
        }
        let frame = NSRect(origin: origin, size: size)
        moving = true
        if wasUp {
            // Already showing: glide over to the pointer.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.24
                ctx.timingFunction = Self.settle
                p.animator().setFrame(frame, display: true)
                p.animator().alphaValue = 1
            }, completionHandler: { MainActor.assumeIsolated { FloatingShelf.shared.moving = false } })
        } else {
            // Appearing: fade in while rising into place.
            p.setFrame(frame.offsetBy(dx: 0, dy: -12), display: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
            p.invalidateShadow()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = Self.settle
                p.animator().setFrame(frame, display: true)
                p.animator().alphaValue = 1
            }, completionHandler: { MainActor.assumeIsolated { FloatingShelf.shared.moving = false } })
        }
    }

    /// Quick start, gentle landing (the curve macOS uses for popovers).
    private static let settle = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    private func startPendingShelf() {
        guard pendingNewShelf else { return }
        pendingNewShelf = false
        // Always a fresh shelf next time: the current one's files go to Recent;
        // categories, side and menu bar shelves are kept as they are.
        ShelfStore.shared.newShelf()
        updateSideHandle()
    }

    /// Minimize: fades the shelf away, then puts it to the side or into a
    /// category (`action`), so it doesn't change in front of you.
    func minimize(_ action: @escaping @MainActor () -> Void) {
        guard let p = panel, p.isVisible else { action(); updateSideHandle(); return }
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
            // Slides a little toward the edge handle, where it went.
            if let screen = p.screen { p.animator().setFrameOrigin(NSPoint(x: min(p.frame.minX + 40, screen.frame.maxX - size.width / 2), y: p.frame.minY)) }
        }, completionHandler: {
            MainActor.assumeIsolated {
                action()
                let s = FloatingShelf.shared
                if s.generation == gen { p.orderOut(nil); s.state.docked = false }
                s.updateSideHandle()
                s.handlePulse()
            }
        })
    }

    /// Opens a side shelf or category in the shelf window, by the edge handle.
    func openShelf(_ target: ShelfTarget) {
        startPendingShelf()                 // a close just before mustn't override what's opened now
        ShelfStore.shared.open = target
        let f = (handlePanel?.frame ?? NSScreen.main?.visibleFrame) ?? .zero
        show(near: NSPoint(x: f.minX - 40, y: f.midY))
    }

    // MARK: The edge handle (side shelves and categories)

    private var handlePanel: NSPanel?
    let handleState = ShelfHandleState()

    /// Shows the slim handle at the right edge while anything is to the side
    /// or in a category; hides it when there's nothing.
    func updateSideHandle() {
        let store = ShelfStore.shared
        let needed = enabled && (!store.edgeShelves.isEmpty || store.categories.contains { !$0.items.isEmpty })
        if !needed { handlePanel?.orderOut(nil); return }
        let p = handlePanel ?? makeHandle()
        handlePanel = p
        if let screen = NSScreen.main {
            let size = NSSize(width: 22, height: 96)
            p.setFrame(NSRect(x: screen.frame.maxX - size.width, y: screen.visibleFrame.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        }
    }

    private func handlePulse() {
        handleState.pulse += 1
    }

    private func makeHandle() -> NSPanel {
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 22, height: 96),
                             styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.hasShadow = true
        let host = FirstClickHostingView(rootView: AnyView(ShelfSideHandle(state: handleState).environment(\.colorScheme, .dark)))
        p.contentView = host
        return p
    }

    /// `endShelf`: closed with its × button: the shelf is cleared (its items
    /// move to Recent shelves) and the next drag starts a new one. Hiding after
    /// a drag with nothing dropped keeps the shelf as it is.
    func close(endShelf: Bool = false) {
        if endShelf { pendingNewShelf = true }
        guard let p = panel, p.isVisible else { startPendingShelf(); return }
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                let s = FloatingShelf.shared
                s.startPendingShelf()
                guard s.generation == gen else { return }     // shown again meanwhile: leave it up
                p.orderOut(nil); s.state.docked = false
            }
        })
    }

    // MARK: Tucking away at the right edge

    /// Small by default; the user can drag the corner to resize, and it's remembered.
    static let defaultSize = NSSize(width: 264, height: 250)
    static let minSize = NSSize(width: 220, height: 190)
    static let maxSize = NSSize(width: 640, height: 720)
    var size: NSSize = {
        let d = UserDefaults.standard
        let w = d.double(forKey: "shelfWidth"), h = d.double(forKey: "shelfHeight")
        return w > 0 && h > 0 ? NSSize(width: w, height: h) : FloatingShelf.defaultSize
    }()

    /// Corner grip dragged: grows / shrinks, top-left corner staying put.
    func resize(by delta: CGSize, done: Bool) {
        guard let p = panel, !state.docked else { return }
        if resizeStart == nil { resizeStart = p.frame }
        guard let start = resizeStart else { return }
        let w = min(Self.maxSize.width, max(Self.minSize.width, start.width + delta.width))
        let h = min(Self.maxSize.height, max(Self.minSize.height, start.height + delta.height))
        moving = true
        p.setFrame(NSRect(x: start.minX, y: start.maxY - h, width: w, height: h), display: true)
        size = NSSize(width: w, height: h)
        if done {
            resizeStart = nil; moving = false
            UserDefaults.standard.set(w, forKey: "shelfWidth"); UserDefaults.standard.set(h, forKey: "shelfHeight")
        }
    }
    private var resizeStart: NSRect?
    static let handle: CGFloat = 26
    let state = FloatingShelfState()
    private var moveCheck: DispatchWorkItem?

    /// Called while the panel is dragged around: once it's let go against the
    /// right edge of the screen, it slides away leaving a handle.
    fileprivate func panelMoved() {
        guard let p = panel, !state.docked, !moving else { return }
        moveCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, NSEvent.pressedMouseButtons == 0, let screen = p.screen else { return }
            if p.frame.maxX >= screen.visibleFrame.maxX - 12 { self.dock(true) }
        }
        moveCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check)
    }

    func dock(_ on: Bool) {
        guard let p = panel, let screen = p.screen ?? NSScreen.main else { return }
        state.docked = on
        // Out far enough from the edge that it doesn't count as tucking away again.
        let x = on ? screen.frame.maxX - Self.handle : screen.visibleFrame.maxX - size.width - 24
        moving = true
        moveCheck?.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = Self.settle
            p.animator().setFrameOrigin(NSPoint(x: x, y: p.frame.minY))
        }, completionHandler: { MainActor.assumeIsolated { FloatingShelf.shared.moving = false } })
    }

    private func makePanel() -> NSPanel {
        let size = self.size
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.hasShadow = true
        p.delegate = delegate
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let root = FloatingShelfContent(state: state)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.ultraThinMaterial, in: shape)
            .background(Color.black.opacity(0.35), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .clipShape(shape)
            .environment(\.colorScheme, .dark)
        let host = FirstClickHostingView(rootView: AnyView(root))
        host.wantsLayer = true
        host.layer?.cornerRadius = 22
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        p.contentView = host
        return p
    }

    private let delegate = FloatingShelfDelegate()
}

@MainActor @Observable
final class FloatingShelfState { var docked = false }

@MainActor @Observable
final class ShelfHandleState { var pulse = 0 }

/// Borderless panels can't normally take typing; this one can (naming a new
/// category), still without bringing Apex to the front.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Spots a wiggle along one axis: the pointer changing direction 3 times,
/// each stroke at least 24 pt, within 0.9 s. Small jitters don't count, and
/// a stroke can run on as far as it likes before turning. Pure: tested.
struct ShakeDetector {
    static let minStroke: CGFloat = 24
    static let window: TimeInterval = 0.9
    static let turnsNeeded = 3

    private var extreme: CGFloat?     // farthest point of the current stroke
    private var direction = 0         // +1, -1, 0 = not moving yet
    private var turns: [TimeInterval] = []

    mutating func reset() { extreme = nil; direction = 0; turns = [] }

    /// Adds a pointer position; true once the wiggle is complete (then starts over).
    mutating func add(_ v: CGFloat, at t: TimeInterval) -> Bool {
        guard let e = extreme else { extreme = v; return false }
        let d = v - e
        if direction == 0 {
            if abs(d) >= Self.minStroke { direction = d > 0 ? 1 : -1; extreme = v }
            return false
        }
        if d * CGFloat(direction) > 0 { extreme = v; return false }   // still going the same way
        guard abs(d) >= Self.minStroke else { return false }
        direction = -direction
        extreme = v
        turns.append(t)
        turns.removeAll { t - $0 > Self.window }
        if turns.count >= Self.turnsNeeded { reset(); return true }
        return false
    }
}

private final class FloatingShelfDelegate: NSObject, NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated { FloatingShelf.shared.panelMoved() }
    }
}

/// Clicks work on the first click, without bringing Apex to the front.
final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating shelf, or (tucked away) a handle at the screen edge that
/// brings it back when clicked or when a file is dragged onto it.
private struct FloatingShelfContent: View {
    let state: FloatingShelfState
    @State private var targeted = false

    var body: some View {
        ZStack(alignment: .leading) {
            ShelfTab(onClose: { FloatingShelf.shared.close(endShelf: true) },
                     onMinimize: { action in FloatingShelf.shared.minimize(action) },
                     onOpen: { t in withAnimation(.easeInOut(duration: 0.2)) { ShelfStore.shared.open = t } })
                .padding(11)
                .opacity(state.docked ? 0 : 1)
            if state.docked {
                VStack(spacing: 6) {
                    Image(systemName: "chevron.compact.left").font(.system(size: 18, weight: .semibold))
                    Image(systemName: "tray.full.fill").font(.system(size: 12))
                    Text("\(ShelfStore.shared.shown.items.count)").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .frame(width: FloatingShelf.handle)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { FloatingShelf.shared.dock(false) }
                .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { _ in false }
                .onChange(of: targeted) { _, on in if on { FloatingShelf.shared.dock(false) } }
                .help("Shelf: click, or drag a file here, to bring it back")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !state.docked { ResizeGrip() }
        }
        .animation(.easeInOut(duration: 0.2), value: state.docked)
    }
}

/// The corner to drag to make the shelf bigger or smaller.
private struct ResizeGrip: View {
    @State private var hover = false
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary.opacity(hover ? 1 : 0.5))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { FloatingShelf.shared.resize(by: $0.translation, done: false) }
                .onEnded { FloatingShelf.shared.resize(by: $0.translation, done: true) })
            .padding(4)
            .help("Drag to resize")
    }
}
