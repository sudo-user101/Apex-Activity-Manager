import AppKit
import XCTest
@testable import TaskManager

final class StatusBarIconTests: XCTestCase {
    func testMenuBarIconIsATemplateSketchThatDraws() throws {
        let img = StatusBarIcon.image
        XCTAssertTrue(img.isTemplate, "macOS colours it for light and dark menu bars")
        XCTAssertEqual(img.size.height, 13, accuracy: 0.01, "as tall as the system's own menu bar icons")
        XCTAssertEqual(img.size.width, 20 * 13 / 18, accuracy: 0.01)
        // Drawn at Retina size, it has ink (the sketch) and empty space (it's line art, not a block).
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 29, pixelsHigh: 26, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: 29, height: 26))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for x in 0..<29 { for y in 0..<26 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 } }
        XCTAssertGreaterThan(inked, 60)
        XCTAssertLessThan(inked, 29 * 26 * 6 / 10, "line art, not a filled block (small icons are denser)")
    }
}

/// APEX_RENDER_ICON=file.png: the menu bar icon large, on a light and a dark bar, and at real size.
final class StatusBarIconRenderTests: XCTestCase {
    func testRender() throws {
        guard let out = ProcessInfo.processInfo.environment["APEX_RENDER_ICON"] else { throw XCTSkip("set APEX_RENDER_ICON") }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (i, bg, ink) in [(0, NSColor(white: 0.93, alpha: 1), NSColor.black), (1, NSColor(white: 0.12, alpha: 1), NSColor.white)] {
            bg.setFill(); NSRect(x: i * 240, y: 0, width: 240, height: 240).fill()
            for (rect, scale) in [(NSRect(x: i * 240 + 20, y: 60, width: 160, height: 144), 1), (NSRect(x: i * 240 + 190, y: 20, width: 40, height: 36), 2)] {
                _ = scale
                let img = StatusBarIcon.image.copy() as! NSImage
                img.isTemplate = false
                let tinted = NSImage(size: img.size, flipped: false) { r in img.draw(in: r); ink.set(); r.fill(using: .sourceAtop); return true }
                tinted.draw(in: rect)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}
