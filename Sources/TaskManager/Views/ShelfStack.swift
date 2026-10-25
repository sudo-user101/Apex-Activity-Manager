import AppKit
import SwiftUI

/// The shelf's files as one stack: a fanned pile of up to three previews and
/// the count. Drag the stack to take every file at once; click it to see them
/// as a list; right-click for actions on all of them.
struct ShelfStackView: View {
    let items: [ShelfItem]
    var onShowList: () -> Void
    var menu: () -> NSMenu?

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
        .overlay(MultiFileDragSource(urls: items.filter(\.exists).map(\.url), onClick: onShowList, menu: menu))
        .help("Drag to take all \(items.count) out · click to see them as a list")
    }

    /// The top file sits straight; the ones under it fan out a little. Pure.
    static func angle(_ i: Int, count: Int) -> Double {
        guard count > 1, i > 0 else { return 0 }
        return i == 1 ? -7 : 6
    }
}

/// An invisible AppKit view over the stack: dragging starts one drag with
/// every file (which SwiftUI's own drag can't do), a click shows the list,
/// and a right-click offers the stack's menu.
struct MultiFileDragSource: NSViewRepresentable {
    let urls: [URL]
    var onClick: () -> Void
    var menu: () -> NSMenu?

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) { v.urls = urls; v.onClick = onClick; v.menuBuilder = menu }

    final class DragView: NSView, NSDraggingSource {
        var urls: [URL] = []
        var onClick: () -> Void = {}
        var menuBuilder: () -> NSMenu? = { nil }
        private var downAt: NSPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.draggingFormation = .pile
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .generic] : .copy
        }
        override func menu(for event: NSEvent) -> NSMenu? { menuBuilder() }
    }
}
