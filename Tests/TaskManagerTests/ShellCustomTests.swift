import XCTest
@testable import TaskManager

final class ShellCustomTests: XCTestCase {
    func testMakeTidiesAndSudoMeansPassword() {
        let c = ShellCustom.make(title: "  Ping router ", detail: "", template: " ping -c 3 {Host} \n", admin: false, changes: false)
        XCTAssertEqual(c.title, "Ping router")
        XCTAssertEqual(c.template, "ping -c 3 {Host}")
        XCTAssertEqual(c.category, "Custom")
        XCTAssertEqual(c.fields, ["Host"])
        XCTAssertFalse(c.needsAdmin)
        XCTAssertFalse(c.changes)

        let s = ShellCustom.make(title: "Purge", detail: "", template: "sudo purge", admin: false, changes: false)
        XCTAssertEqual(s.template, "purge", "sudo becomes the macOS password prompt")
        XCTAssertTrue(s.needsAdmin)
        XCTAssertTrue(s.changes, "admin commands always ask first")
    }

    func testProblemsInPlainWords() {
        let ok = ShellCustom.make(title: "List", detail: "", template: "ls {Folder}", admin: false, changes: false)
        XCTAssertNil(ShellCustom.problem(ok, existing: []))
        XCTAssertEqual(ShellCustom.problem(ShellCustom.make(title: "", detail: "", template: "ls", admin: false, changes: false), existing: []), "Give it a name.")
        XCTAssertEqual(ShellCustom.problem(ShellCustom.make(title: "x", detail: "", template: "  ", admin: false, changes: false), existing: []), "Type the command.")
        XCTAssertNotNil(ShellCustom.problem(ok, existing: [ok]), "same name twice")
        XCTAssertNotNil(ShellCustom.problem(ShellCustom.make(title: "LIST", detail: "", template: "ls", admin: false, changes: false), existing: [ok]),
                        "names are compared without case")
        XCTAssertNil(ShellCustom.problem(ok, existing: [ok], replacing: "List"), "editing keeps its own name")
        XCTAssertNotNil(ShellCustom.problem(ShellCustom.make(title: "y", detail: "", template: "ls {Folder", admin: false, changes: false), existing: []))
    }

    func testUpsertAddsOrReplacesInPlace() {
        let a = ShellCustom.make(title: "A", detail: "", template: "echo a", admin: false, changes: false)
        let b = ShellCustom.make(title: "B", detail: "", template: "echo b", admin: false, changes: false)
        var list = ShellCustom.upsert(a, into: [], replacing: nil)
        list = ShellCustom.upsert(b, into: list, replacing: nil)
        let a2 = ShellCustom.make(title: "A renamed", detail: "", template: "echo a2", admin: false, changes: false)
        list = ShellCustom.upsert(a2, into: list, replacing: "A")
        XCTAssertEqual(list.map(\.title), ["A renamed", "B"])
    }

    func testSavedAndLoadedAndBlanksStayQuoted() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "apex-shell-custom-\(UUID())"))
        XCTAssertEqual(ShellCustom.load(d), [])
        let c = ShellCustom.make(title: "Ping", detail: "Is it up?", template: "ping -c 3 {Host}", admin: false, changes: false)
        ShellCustom.save([c], d)
        XCTAssertEqual(ShellCustom.load(d), [c])
        XCTAssertEqual(c.command(["Host": "x; rm -rf ~"]), "ping -c 3 'x; rm -rf ~'", "what's typed in a blank is only ever that value")
    }
}
