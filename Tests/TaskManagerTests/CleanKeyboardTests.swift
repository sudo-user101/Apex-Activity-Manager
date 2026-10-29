import XCTest
@testable import TaskManager

final class CleanKeyboardTests: XCTestCase {
    func testWhatTheLockHoldsBack() {
        for t: CGEventType in [.keyDown, .keyUp, .flagsChanged, CGEventType(rawValue: 14)!] {
            XCTAssertTrue(CleanKeyboard.blocks(t, lockPointer: false), "keys, modifiers, volume and brightness keys: \(t.rawValue)")
        }
        XCTAssertFalse(CleanKeyboard.blocks(.leftMouseDown, lockPointer: false), "the pointer works, so Done can be clicked")
        XCTAssertFalse(CleanKeyboard.blocks(.mouseMoved, lockPointer: true), "moving the pointer is harmless")
        XCTAssertTrue(CleanKeyboard.blocks(.leftMouseDown, lockPointer: true))
        XCTAssertTrue(CleanKeyboard.blocks(.scrollWheel, lockPointer: true))
    }

    func testClockAndChoices() {
        XCTAssertEqual(CleanKeyboard.clock(45), "0:45")
        XCTAssertEqual(CleanKeyboard.clock(120), "2:00")
        XCTAssertTrue(CleanKeyboard.choices.allSatisfy { $0.seconds > 0 && $0.seconds <= 300 }, "it always unlocks by itself, within 5 minutes")
    }
}
