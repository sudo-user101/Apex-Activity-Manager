import Carbon.HIToolbox
import XCTest
@testable import TaskManager

/// The rules behind MacOSX Change's keyboard and mouse behaviours. Nothing is
/// posted to the screen: the rules take numbers and give numbers back.
final class InputTweaksTests: XCTestCase {
    func testWheelReverseAndLinearOnlyTouchAMouseWheel() {
        XCTAssertEqual(InputRules.wheel(lines: 1, points: 12, continuous: false, reverse: true, linear: false).lines, -1)
        XCTAssertEqual(InputRules.wheel(lines: 1, points: 12, continuous: false, reverse: true, linear: false).points, -12)
        let fast = InputRules.wheel(lines: 9, points: 140, continuous: false, reverse: false, linear: true)
        XCTAssertEqual(fast.lines, 3, "a fast spin scrolls the same as a slow one")
        XCTAssertEqual(InputRules.wheel(lines: -1, points: -10, continuous: false, reverse: false, linear: true).lines, -3, "direction kept")
        XCTAssertEqual(InputRules.wheel(lines: -7, points: -90, continuous: false, reverse: true, linear: true).lines, 3, "both at once")
        let pad = InputRules.wheel(lines: 2, points: 25, continuous: true, reverse: true, linear: true)
        XCTAssertEqual(pad.lines, 2); XCTAssertEqual(pad.points, 25, "trackpad and Magic Mouse scrolling untouched")
        XCTAssertEqual(InputRules.wheel(lines: 0, points: 0, continuous: false, reverse: true, linear: true).lines, 0, "the other axis stays still")
    }

    func testChatterFilters() {
        XCTAssertTrue(InputRules.isChatter(sinceLastUp: 0.012, limit: InputRules.chatterSeconds), "a bounce 12 ms after letting go")
        XCTAssertFalse(InputRules.isChatter(sinceLastUp: 0.09, limit: InputRules.chatterSeconds), "a quick real double-click (90 ms) still works")
        XCTAssertFalse(InputRules.isChatter(sinceLastUp: nil, limit: InputRules.chatterSeconds))
        XCTAssertTrue(InputRules.isChatter(sinceLastUp: 0.02, limit: InputRules.debounceSeconds))
        XCTAssertFalse(InputRules.isChatter(sinceLastUp: 0.07, limit: InputRules.debounceSeconds), "typing “ee” quickly is kept")
    }

    func testSideButtons() {
        XCTAssertEqual(InputRules.sideButton(3, app: "com.apple.finder"), kVK_ANSI_LeftBracket)
        XCTAssertEqual(InputRules.sideButton(4, app: "com.apple.Safari"), kVK_ANSI_RightBracket)
        XCTAssertNil(InputRules.sideButton(3, app: "com.google.Chrome"), "Chrome already goes back; don't go back twice")
        XCTAssertNil(InputRules.sideButton(2, app: "com.apple.finder"), "the middle button is left alone")
    }

    func testFinderKeys() {
        func k(_ code: Int, cmd: Bool = true, mods: Bool = false, editing: Bool = false, pending: Bool = false, image: Bool = false) -> InputRules.FinderKey {
            InputRules.finderKey(code: code, command: cmd, otherMods: mods, editing: editing, cutPending: pending, imageOnly: image,
                                 cutPaste: true, f2: true, pasteImage: true)
        }
        XCTAssertEqual(k(kVK_ANSI_X), .cut)
        XCTAssertEqual(k(kVK_ANSI_V, pending: true), .move, "after ⌘X, ⌘V moves")
        XCTAssertEqual(k(kVK_ANSI_V), .none, "a plain copy pastes as usual")
        XCTAssertEqual(k(kVK_ANSI_V, image: true), .pasteImage)
        XCTAssertEqual(k(kVK_ANSI_X, editing: true), .none, "cutting text while renaming is left alone")
        XCTAssertEqual(k(kVK_F2, cmd: false), .rename)
        XCTAssertEqual(k(kVK_F2, cmd: false, editing: true), .none)
        XCTAssertEqual(k(kVK_ANSI_V, mods: true, pending: true), .none, "⌥⌘V and others are left alone")
        XCTAssertEqual(InputRules.finderKey(code: kVK_ANSI_X, command: true, otherMods: false, editing: false, cutPending: false,
                                            imageOnly: false, cutPaste: false, f2: true, pasteImage: true), .none, "switched off")
    }

    func testQuitTwice() {
        let t = Date()
        XCTAssertFalse(InputRules.quitAllowed(lastPress: nil, lastApp: nil, app: "a", now: t), "the first press only reminds")
        XCTAssertTrue(InputRules.quitAllowed(lastPress: t, lastApp: "a", app: "a", now: t.addingTimeInterval(0.8)))
        XCTAssertFalse(InputRules.quitAllowed(lastPress: t, lastApp: "a", app: "a", now: t.addingTimeInterval(2)), "too late: reminds again")
        XCTAssertFalse(InputRules.quitAllowed(lastPress: t, lastApp: "a", app: "b", now: t.addingTimeInterval(0.5)), "a different app")
    }

    func testCleanLinks() {
        XCTAssertEqual(InputRules.cleanLink("https://shop.example.com/item?id=42&utm_source=news&utm_medium=email&fbclid=abc"),
                       "https://shop.example.com/item?id=42")
        XCTAssertEqual(InputRules.cleanLink("https://youtu.be/xyz?si=TRACK&t=30"), "https://youtu.be/xyz?t=30", "si on YouTube is tracking")
        XCTAssertNil(InputRules.cleanLink("https://example.com/search?si=1&q=x"), "si elsewhere may be real: kept")
        XCTAssertEqual(InputRules.cleanLink("https://example.com/?gclid=1"), "https://example.com/")
        XCTAssertNil(InputRules.cleanLink("https://example.com/page?q=apex"), "nothing to take out")
        XCTAssertNil(InputRules.cleanLink("look at https://x.com/?utm_source=a"), "text with a link inside is left alone")
        XCTAssertNil(InputRules.cleanLink("ftp://x.com/?utm_source=a"))
    }

    func testPastedImageNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-paste-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let first = InputTweaks.pastedImageURL(in: dir, now: when)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("Pasted image 20"))
        XCTAssertTrue(first.lastPathComponent.hasSuffix(".png"))
        try Data().write(to: first)
        XCTAssertTrue(InputTweaks.pastedImageURL(in: dir, now: when).lastPathComponent.hasSuffix(" 2.png"), "never overwrites")
    }
}
