import AppKit
import SwiftUI

/// The shelf's files as one stack: a fanned pile of up to three previews and
/// the count. Drag the stack to take every file at once; click it to see them
/// as a list; right-click for actions on all of them.
struct ShelfStackView: View {
    let items: [ShelfItem]
    var onShowList: () -> Void
    var menu: () -> NSMenu?
    var shelf: UUID? = nil

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                ForEach(Array(items.prefix(3).enumerated().reversed()), id: \.element.id) { i, item in
                    ShelfThumbnail(url: item.url)
                        .frame(width: 92, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                        .rotationEffect(.degrees(Self.angle(i, count: min(3, items.count))))
                        .offset(x: CGFloat(i) * 7, y: CGFloat(i) * -3)
                }
            }
            .frame(width: 130, height: 100)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: items.map(\.id))
            VStack(spacing: 2) {
                Text(items.count == 1 ? items[0].name : "\(items.count) files")
                    .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(Fmt.diskBytes(items.reduce(0) { $0 + MediaCompressor.fileSize($1.url) }))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .overlay(MultiFileDragSource(urls: items.filter(\.exists).map(\.url), onClick: onShowList, menu: menu, shelf: shelf))
        .help("Drag to take all \(items.count) out · click to see them as a list")
    }

    /// The top file sits straight; the ones under it fan out a little. Pure.
    static func angle(_ i: Int, count: Int) -> Double {
        guard count > 1, i > 0 else { return 0 }
        return i == 1 ? -7 : 6
    }
}

/// Files being dragged out of a shelf right now, and which shelf. Dropping
/// them back on that same shelf does nothing (they're already there).
@MainActor enum ShelfDrag {
    static var from: UUID?
    static var paths: Set<String> = []

    static func began(_ shelf: UUID?, _ urls: [URL]) { from = shelf; paths = Set(urls.map { ShelfStore.canonical($0.path) }) }
    static func ended() { from = nil; paths = [] }

    /// Files dragged out of the floating shelf landed in another app or a
    /// folder: its job is done, so it goes into the menu bar. Not when the
    /// drop was refused or cancelled, or ended on the shelf itself.
    static func tucksAway(after operation: NSDragOperation, window: NSWindow?, at point: NSPoint) -> Bool {
        FloatingShelf.shared.owns(window) && delivered(operation, endedOnShelf: window?.frame.contains(point) ?? false)
    }

    /// Pure: tested.
    nonisolated static func delivered(_ operation: NSDragOperation, endedOnShelf: Bool) -> Bool {
        !operation.isEmpty && !endedOnShelf
    }

    /// A drop of only these files on the shelf they came from. Pure (given the drag): tested.
    static func isBackOnOwnShelf(_ urls: [URL], shelf: UUID) -> Bool {
        from == shelf && !urls.isEmpty && urls.allSatisfy { paths.contains(ShelfStore.canonical($0.path)) }
    }
}

/// An invisible AppKit view over the stack: dragging starts one drag with
/// every file (which SwiftUI's own drag can't do), a click shows the list,
/// and a right-click offers the stack's menu.
struct MultiFileDragSource: NSViewRepresentable {
    let urls: [URL]
    var onClick: () -> Void
    var menu: () -> NSMenu?
    /// The shelf they're on (so dropping them back there does nothing).
    var shelf: UUID? = nil

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) { v.urls = urls; v.onClick = onClick; v.menuBuilder = menu; v.shelf = shelf }

    final class DragView: NSView, NSDraggingSource {
        var urls: [URL] = []
        var onClick: () -> Void = {}
        var menuBuilder: () -> NSMenu? = { nil }
        var shelf: UUID?
        private var downAt: NSPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        // The floating shelf moves when its background is dragged; grabbing
        // the stack must drag the files out instead, never the shelf.
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }
        override func mouseUp(with event: NSEvent) {
            if downAt != nil { onClick() }
            downAt = nil
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = downAt, !urls.isEmpty else { return }
            let p = event.locationInWindow
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            downAt = nil
            let local = convert(event.locationInWindow, from: nil)
            let items = urls.enumerated().map { i, u -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: u as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: u.path)
                item.setDraggingFrame(NSRect(x: local.x - 24 + CGFloat(i) * 4, y: local.y - 24 - CGFloat(i) * 4, width: 48, height: 48), contents: icon)
                return item
            }
            ShelfDrag.began(shelf, urls)
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.draggingFormation = .pile
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .generic] : .copy
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            // After the drop has been handled.
            let tuck = ShelfDrag.tucksAway(after: operation, window: window, at: screenPoint)
            DispatchQueue.main.async { ShelfDrag.ended(); if tuck { FloatingShelf.shared.tuckIntoMenuBar() } }
        }
        override func menu(for event: NSEvent) -> NSMenu? { menuBuilder() }
    }
}

/// An invisible AppKit view over one row of the list: drags that file (or
/// every selected file, when it's one of them) the way the stack does, which
/// SwiftUI's own drag couldn't while the row also takes clicks; click selects
/// (⌘-click adds), double-click opens; right-click is the row's own menu.
struct FileRowDragSource: NSViewRepresentable {
    var urls: () -> [URL]
    var onClick: (_ command: Bool) -> Void
    var onDoubleClick: () -> Void
    var shelf: UUID?

    func makeNSView(context: Context) -> RowView { RowView() }
    func updateNSView(_ v: RowView, context: Context) {
        v.urls = urls; v.onClick = onClick; v.onDoubleClick = onDoubleClick; v.shelf = shelf
    }

    final class RowView: NSView, NSDraggingSource {
        var urls: () -> [URL] = { [] }
        var onClick: (Bool) -> Void = { _ in }
        var onDoubleClick: () -> Void = {}
        var shelf: UUID?
        private var downAt: NSPoint?
        private var command = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        // Dragging a row takes the file, not the floating shelf.
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { downAt = nil; onDoubleClick(); return }
            downAt = event.locationInWindow
            command = event.modifierFlags.contains(.command)
        }
        override func mouseUp(with event: NSEvent) {
            if downAt != nil { onClick(command) }
            downAt = nil
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = downAt else { return }
            let p = event.locationInWindow
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            downAt = nil
            let list = urls().filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !list.isEmpty else { return }
            let local = convert(event.locationInWindow, from: nil)
            let items = list.enumerated().map { i, u -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: u as NSURL)
                item.setDraggingFrame(NSRect(x: local.x - 20 + CGFloat(i) * 4, y: local.y - 20 - CGFloat(i) * 4, width: 40, height: 40),
                                      contents: NSWorkspace.shared.icon(forFile: u.path))
                return item
            }
            ShelfDrag.began(shelf, list)
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.draggingFormation = list.count > 1 ? .pile : .none
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .generic] : .copy
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            let tuck = ShelfDrag.tucksAway(after: operation, window: window, at: screenPoint)
            DispatchQueue.main.async { ShelfDrag.ended(); if tuck { FloatingShelf.shared.tuckIntoMenuBar() } }
        }
        // The row's SwiftUI menu belongs to the views underneath.
        override func menu(for event: NSEvent) -> NSMenu? {
            var v = superview
            while let s = v { if let m = s.menu(for: event) { return m }; v = s.superview }
            return nil
        }
        override func rightMouseDown(with event: NSEvent) { nextResponder?.rightMouseDown(with: event) }
    }
}
