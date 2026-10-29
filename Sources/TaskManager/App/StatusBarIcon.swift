import AppKit

/// The menu bar icon: a line sketch of Apex's app icon (the monitor, about
/// 4:3 so it doesn't look squashed, the two chart screens apart on top and
/// cabled into it, with its
/// heartbeat, the two chart screens on top, the base with its drive slot),
/// bold and simple like Apple's own menu bar icons. Drawn in code as a
/// template image, so it's sharp at any scale and macOS colours it for light
/// and dark menu bars.
enum StatusBarIcon {
    /// Drawn on a 20 × 18 grid, shown 13 points tall: the height of the system's
    /// own icons (Focus 12, Time Machine 13, Bluetooth 14, measured in the
    /// menu bar), not taller than them.
    static let scale: CGFloat = 13.0 / 18.0
    static let size = NSSize(width: 20 * scale, height: 18 * scale)
    /// About 0.95 points once scaled: bold like Apple's own menu bar icons,
    /// with the details still apart at this size.
    static let lineWidth: CGFloat = 1.3

    static let image: NSImage = {
        let img = NSImage(size: size, flipped: true) { _ in draw(); return true }
        img.isTemplate = true
        img.accessibilityDescription = "Apex"
        return img
    }()

    private static func draw() {
        NSColor.black.set()
        let t = NSAffineTransform(); t.scale(by: scale); t.concat()
        func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ r: CGFloat) {
            let p = NSBezierPath(roundedRect: NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), xRadius: r, yRadius: r)
            p.lineWidth = lineWidth; p.stroke()
        }
        func line(_ pts: [(CGFloat, CGFloat)]) {
            let p = NSBezierPath()
            p.lineWidth = lineWidth; p.lineCapStyle = .round; p.lineJoinStyle = .round
            for (i, q) in pts.enumerated() { i == 0 ? p.move(to: NSPoint(x: q.0, y: q.1)) : p.line(to: NSPoint(x: q.0, y: q.1)) }
            p.stroke()
        }
        // The two small screens, apart: a rising line chart and two bars.
        box(0.9, 0.6, 8.3, 4.6, 1.0)
        box(11.7, 0.6, 19.1, 4.6, 1.0)
        line([(2.5, 3.5), (4.0, 2.4), (5.1, 3.0), (6.7, 1.8)])
        line([(14.4, 3.6), (14.4, 2.6)])
        line([(16.4, 3.6), (16.4, 1.8)])
        // Cables from each one's outer side, down and into the monitor, as in the app icon.
        func cable(_ x: CGFloat, to edge: CGFloat) {
            let p = NSBezierPath()
            p.lineWidth = lineWidth; p.lineCapStyle = .round
            p.move(to: NSPoint(x: x, y: 4.6))
            p.line(to: NSPoint(x: x, y: 8.0))
            p.curve(to: NSPoint(x: edge, y: 9.7), controlPoint1: NSPoint(x: x, y: 9.3), controlPoint2: NSPoint(x: (x + edge) / 2, y: 9.7))
            p.stroke()
        }
        cable(1.9, to: 5.2)
        cable(18.1, to: 14.8)
        // The monitor, about 4:3, a little below the screens, with one clean heartbeat.
        box(5.2, 6.0, 14.8, 13.4, 1.6)
        line([(6.8, 9.7), (8.4, 9.7), (9.3, 7.9), (10.6, 11.5), (11.6, 9.7), (13.2, 9.7)])
        // The base and its drive slot.
        box(4.0, 14.6, 16.0, 17.4, 0.9)
        line([(10.8, 16.0), (14.0, 16.0)])
    }
}
