import XCTest
@testable import TaskManager

final class TerminalEmulatorTests: XCTestCase {
    func testTextWrapAndNewlines() {
        let t = TerminalEmulator(cols: 10, rows: 3)
        t.feed("hello\r\nworld 12345678")
        XCTAssertEqual(t.line(0), "hello")
        XCTAssertEqual(t.line(1), "world 1234")
        XCTAssertEqual(t.line(2), "5678", "wraps at the edge")
        t.feed("\r\nnext")
        XCTAssertEqual(t.line(2), "next", "scrolled")
        XCTAssertEqual(t.scrollback.count, 1)
    }

    func testCursorMovesAndErasing() {
        let t = TerminalEmulator(cols: 20, rows: 5)
        t.feed("abcdefghij\u{1B}[1;4H\u{1B}[K")
        XCTAssertEqual(t.line(0), "abc", "erase to end of line")
        t.feed("\u{1B}[3;5Hx\u{1B}[2D\u{1B}[1Ay")
        XCTAssertEqual(t.line(2), "    x")
        XCTAssertEqual(t.line(1), "   y")
        t.feed("\u{1B}[2J")
        XCTAssertEqual(t.text.trimmingCharacters(in: .whitespacesAndNewlines), "", "clear screen")
        t.feed("\u{1B}[H12345\u{1B}[1;2H\u{1B}[2P")
        XCTAssertEqual(t.line(0), "145", "delete characters")
        t.feed("\u{1B}[1;2H\u{1B}[2@")
        XCTAssertEqual(t.line(0), "1  45", "insert blanks")
    }

    func testColoursAndStyles() {
        let t = TerminalEmulator(cols: 20, rows: 2)
        t.feed("\u{1B}[1;31mR\u{1B}[0m\u{1B}[38;5;208mO\u{1B}[38;2;10;20;30mT\u{1B}[7;44mI\u{1B}[m.")
        let row = t.grid[0]
        XCTAssertEqual(row[0].style.fg, 1); XCTAssertTrue(row[0].style.bold)
        XCTAssertEqual(row[1].style.fg, 208); XCTAssertFalse(row[1].style.bold)
        XCTAssertEqual(row[2].style.fg, 0x1000000 | 10 << 16 | 20 << 8 | 30)
        XCTAssertTrue(row[3].style.inverse); XCTAssertEqual(row[3].style.bg, 4)
        XCTAssertEqual(row[4].style, TerminalEmulator.Style())
    }

    func testAlternateScreenAndScrollRegion() {
        let t = TerminalEmulator(cols: 10, rows: 4)
        t.feed("shell$ ")
        t.feed("\u{1B}[?1049h\u{1B}[H\u{1B}[2Jtop bar\u{1B}[2;3r\u{1B}[2;1Ha\r\nb\r\nc")
        XCTAssertTrue(t.altScreen)
        XCTAssertEqual(t.line(0), "top bar", "outside the region: stays")
        XCTAssertEqual(t.line(1), "b"); XCTAssertEqual(t.line(2), "c", "scrolled inside the region")
        t.feed("\u{1B}[r\u{1B}[?1049l")
        XCTAssertFalse(t.altScreen)
        XCTAssertEqual(t.line(0), "shell$", "the shell's screen comes back")
        XCTAssertEqual(t.scrollback.count, 0, "the full-screen program left nothing in scrollback")
    }

    func testUnicodeWideAndLineDrawing() {
        let t = TerminalEmulator(cols: 10, rows: 2)
        t.feed("é日本\u{1B}(0lqk\u{1B}(B")
        XCTAssertEqual(t.line(0), "é日本┌─┐")
        XCTAssertTrue(t.grid[0][1].wide); XCTAssertTrue(t.grid[0][2].cont)
        XCTAssertEqual(t.cursorX, 8)
        let split = TerminalEmulator(cols: 10, rows: 2)
        split.feed(Data([0xE2, 0x82])); split.feed(Data([0xAC]))     // € in two reads
        XCTAssertEqual(split.line(0), "€")
    }

    func testAnswersAndKeys() {
        let t = TerminalEmulator(cols: 20, rows: 5)
        var sent = ""
        t.respond = { sent += String(decoding: $0, as: UTF8.self) }
        t.feed("\u{1B}[3;7H\u{1B}[6n\u{1B}[c")
        XCTAssertEqual(sent, "\u{1B}[3;7R\u{1B}[?1;2c")
        XCTAssertEqual(String(decoding: t.bytes(for: .up), as: UTF8.self), "\u{1B}[A")
        t.feed("\u{1B}[?1h\u{1B}[?2004h")
        XCTAssertEqual(String(decoding: t.bytes(for: .up), as: UTF8.self), "\u{1B}OA", "application cursor keys (vim, less)")
        XCTAssertEqual(String(decoding: t.paste("a\nb"), as: UTF8.self), "\u{1B}[200~a\rb\u{1B}[201~")
        t.feed("\u{1B}]0;root@web: ~\u{07}")
        XCTAssertEqual(t.title, "root@web: ~")
    }

    func testResizeKeepsTheCursorLine() {
        let t = TerminalEmulator(cols: 10, rows: 4)
        t.feed("1\r\n2\r\n3\r\n4")
        t.resize(cols: 6, rows: 2)
        XCTAssertEqual(t.line(1), "4", "the line being typed stays on screen")
        XCTAssertEqual(t.cursorY, 1)
        XCTAssertEqual(t.grid[0].count, 6)
    }
}
