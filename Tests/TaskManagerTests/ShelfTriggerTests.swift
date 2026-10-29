import AppKit
import Carbon.HIToolbox
import XCTest
@testable import TaskManager

/// Issue #7: what the paid shelf apps do that Apex's shelf didn't.
final class ShelfTriggerTests: XCTestCase {
    func testHoldingTheChosenKeyOpensTheShelf() {
        XCTAssertTrue(ShelfTrigger.keyHeld("shift", flags: [.shift]))
        XCTAssertTrue(ShelfTrigger.keyHeld("option", flags: [.option, .capsLock]))
        XCTAssertFalse(ShelfTrigger.keyHeld("option", flags: [.command]))
        XCTAssertFalse(ShelfTrigger.keyHeld("", flags: [.shift, .control, .option, .command]), "no key chosen")
        XCTAssertFalse(ShelfTrigger.keyHeld("command", flags: []))
    }

    func testExcludedApps() {
        XCTAssertTrue(ShelfTrigger.excluded("com.adobe.Photoshop", ["com.adobe.photoshop"]), "bundle ids compared without case")
        XCTAssertFalse(ShelfTrigger.excluded("com.apple.finder", ["com.adobe.Photoshop"]))
        XCTAssertFalse(ShelfTrigger.excluded(nil, ["com.adobe.Photoshop"]))
    }

    func testFreeNameNeverOverwrites() {
        let folder = URL(fileURLWithPath: "/tmp/dest")
        let file = URL(fileURLWithPath: "/x/Report.pdf")
        XCTAssertEqual(ShelfStore.freeName(for: file, in: folder) { _ in false }.lastPathComponent, "Report.pdf")
        let taken: Set<String> = ["/tmp/dest/Report.pdf", "/tmp/dest/Report 2.pdf"]
        XCTAssertEqual(ShelfStore.freeName(for: file, in: folder) { taken.contains($0.path) }.lastPathComponent, "Report 3.pdf")
        XCTAssertEqual(ShelfStore.freeName(for: URL(fileURLWithPath: "/x/Notes"), in: folder) { $0.lastPathComponent == "Notes" }.lastPathComponent,
                       "Notes 2", "no extension")
    }

    func testRecentDestinationsNewestFirstNoRepeatsAtMostFive() {
        XCTAssertEqual(ShelfDestinations.updated([], adding: "/a"), ["/a"])
        XCTAssertEqual(ShelfDestinations.updated(["/a", "/b"], adding: "/b"), ["/b", "/a"])
        XCTAssertEqual(ShelfDestinations.updated(["/1", "/2", "/3", "/4", "/5"], adding: "/6"), ["/6", "/1", "/2", "/3", "/4"])
    }

    func testShortcutCombos() {
        XCTAssertNil(ShelfHotKey.Choice.off.combo)
        XCTAssertEqual(ShelfHotKey.Choice.optionCommandS.combo?.code, UInt32(kVK_ANSI_S))
        XCTAssertEqual(ShelfHotKey.Choice.optionCommandS.combo?.modifiers, UInt32(optionKey | cmdKey))
        XCTAssertEqual(ShelfHotKey.Choice.controlOptionSpace.combo?.code, UInt32(kVK_Space))
        XCTAssertEqual(Set(ShelfHotKey.Choice.allCases.map(\.title)).count, ShelfHotKey.Choice.allCases.count)
    }
}
