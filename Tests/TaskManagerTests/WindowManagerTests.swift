import AppKit
import SwiftUI
import XCTest
@testable import TaskManager

final class WindowManagerTests: XCTestCase {
    let area = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let w = CGRect(x: 300, y: 200, width: 800, height: 600)

    func testPositions() {
        XCTAssertEqual(WindowGeometry.rect(.leftHalf, in: area, current: w), CGRect(x: 0, y: 25, width: 720, height: 875))
        XCTAssertEqual(WindowGeometry.rect(.bottomRight, in: area, current: w), CGRect(x: 720, y: 463, width: 720, height: 437))
        XCTAssertEqual(WindowGeometry.rect(.centerThird, in: area, current: w), CGRect(x: 480, y: 25, width: 480, height: 875))
        XCTAssertEqual(WindowGeometry.rect(.lastTwoThirds, in: area, current: w).width, 960)
        XCTAssertEqual(WindowGeometry.rect(.secondFourth, in: area, current: w).minX, 360)
        XCTAssertEqual(WindowGeometry.rect(.bottomCenterSixth, in: area, current: w), CGRect(x: 480, y: 463, width: 480, height: 437))
        XCTAssertEqual(WindowGeometry.rect(.maximize, in: area, current: w), area)
        XCTAssertEqual(WindowGeometry.rect(.center, in: area, current: w), CGRect(x: 320, y: 163, width: 800, height: 600))
        XCTAssertEqual(WindowGeometry.rect(.maximizeHeight, in: area, current: w), CGRect(x: 300, y: 25, width: 800, height: 875))
        let bigger = WindowGeometry.rect(.larger, in: area, current: w)
        XCTAssertEqual(bigger.size, CGSize(width: 860, height: 660)); XCTAssertEqual(bigger.midX, w.midX)
        XCTAssertTrue(area.contains(WindowGeometry.rect(.larger, in: area, current: CGRect(x: 0, y: 25, width: 1440, height: 875))), "never past the screen")
    }

    func testPortraitScreensSplitTopToBottom() {
        let tall = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        XCTAssertEqual(WindowGeometry.rect(.firstThird, in: tall, current: w), CGRect(x: 0, y: 0, width: 1080, height: 640))
    }

    func testGaps() {
        let r = WindowGeometry.rect(.leftHalf, in: area, current: w, gap: 10)
        XCTAssertEqual(r, CGRect(x: 10, y: 35, width: 705, height: 855), "a whole gap at the screen's edges, half where windows meet")
        let right = WindowGeometry.rect(.rightHalf, in: area, current: w, gap: 10)
        XCTAssertEqual(right.minX - r.maxX, 10, "two halves together leave one gap between them")
        XCTAssertEqual(WindowGeometry.rect(.topHalf, in: area, current: w).maxY, WindowGeometry.rect(.bottomHalf, in: area, current: w).minY, "top and bottom meet exactly")
    }

    func testPressingAgainCycles() {
        XCTAssertEqual(WindowGeometry.cycled(.leftHalf, step: 1).fraction, 2.0 / 3)
        XCTAssertEqual(WindowGeometry.cycled(.leftHalf, step: 2).fraction, 1.0 / 3)
        XCTAssertEqual(WindowGeometry.cycled(.leftHalf, step: 3).fraction, 0.5, "and round again")
        XCTAssertEqual(WindowGeometry.cycled(.firstThird, step: 1).action, .centerThird)
        XCTAssertEqual(WindowGeometry.cycled(.lastThird, step: 1).action, .firstThird)
        XCTAssertEqual(WindowGeometry.half(.rightHalf, fraction: 2.0 / 3, in: area, gap: 0), CGRect(x: 480, y: 25, width: 960, height: 875))
    }

    func testSnapZones() {
        let s = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(WindowGeometry.snap(at: CGPoint(x: 0, y: 450), screen: s, shift: false), .leftHalf)
        XCTAssertEqual(WindowGeometry.snap(at: CGPoint(x: 1439, y: 450), screen: s, shift: false), .rightHalf)
        XCTAssertEqual(WindowGeometry.snap(at: CGPoint(x: 700, y: 0), screen: s, shift: false), .maximize)
        XCTAssertEqual(WindowGeometry.snap(at: CGPoint(x: 2, y: 10), screen: s, shift: false), .topLeft)
        XCTAssertEqual(WindowGeometry.snap(at: CGPoint(x: 1420, y: 899), screen: s, shift: false), .bottomRight)
        XCTAssertEqual(WindowGeometry.snap(at: CGPoint(x: 700, y: 899), screen: s, shift: false), .centerThird)
        XCTAssertEqual(WindowGeometry.snap(at: CGPoint(x: 200, y: 899), screen: s, shift: false), .firstThird)
        XCTAssertEqual(WindowGeometry.snap(at: CGPoint(x: 200, y: 899), screen: s, shift: true), .firstTwoThirds)
        XCTAssertNil(WindowGeometry.snap(at: CGPoint(x: 700, y: 450), screen: s, shift: false), "away from the edges: nothing")
    }

    func testTilingAndPicker() {
        let five = WindowGeometry.tiles(count: 5, in: area, gap: 0)
        XCTAssertEqual(five.count, 5)
        XCTAssertEqual(five[0].width, 480, "three across on top")
        XCTAssertEqual(five[3].width, 720, "the last row shares the width")
        XCTAssertTrue(WindowGeometry.tiles(count: 0, in: area, gap: 0).isEmpty)
        XCTAssertGreaterThanOrEqual(WindowThrow.keyLabels.count, WindowThrow.choices.count, "every position has a key in the picker")
        XCTAssertEqual(Set(WindowAction.allCases.compactMap { $0.key.map { "\($0.code)\($0.shift)" } }).count,
                       WindowAction.allCases.compactMap(\.key).count, "no two positions share a shortcut")
    }
}

/// APEX_RENDER_UTILITIES=dir also renders the Window Manager picker.
final class WindowThrowRenderTests: XCTestCase {
    @MainActor func testRender() throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_RENDER_UTILITIES"] else { throw XCTSkip("set APEX_RENDER_UTILITIES") }
        WindowThrow.shared.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let win = NSApp.windows.first { $0 is KeyablePanel && $0.isVisible && $0.frame.width == 660 }
        let host = try XCTUnwrap(win?.contentView)
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/window-throw.png"))
        WindowThrow.shared.close()
    }
}
