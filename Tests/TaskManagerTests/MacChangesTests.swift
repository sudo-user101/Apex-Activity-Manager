import XCTest
@testable import TaskManager

final class MacChangesTests: XCTestCase {
    func testCatalogIsSound() {
        let ids = MacChanges.switches.map(\.id) + MacChanges.choices.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicate ids")
        for c in MacChanges.switches {
            XCTAssertTrue(MacChanges.groups.contains(c.group), c.id)
            XCTAssertFalse(c.prefs.isEmpty, c.id)
            XCTAssertFalse(c.title.isEmpty, c.id)
        }
        let prefIDs = MacChanges.switches.flatMap(\.prefs).map(\.id)
        XCTAssertEqual(Set(prefIDs).count, prefIDs.count, "two switches never fight over one setting")
        for c in MacChanges.choices {
            XCTAssertTrue(MacChanges.groups.contains(c.group), c.id)
            XCTAssertNil(c.options.first?.value, "the first option is always macOS's default: \(c.id)")
        }
        XCTAssertTrue(MacChanges.groups.allSatisfy { g in MacChanges.switches.contains { $0.group == g } || MacChanges.choices.contains { $0.group == g }
            || MacBehaviours.all.contains { $0.group == g } }, "every group has something in it")
        let behaviourIDs = MacBehaviours.all.map(\.id)
        XCTAssertEqual(Set(behaviourIDs).count, behaviourIDs.count)
        for b in MacBehaviours.all { XCTAssertTrue(MacChanges.groups.contains(b.group), b.id); XCTAssertFalse(b.detail.isEmpty, b.id) }
    }

    func testValuesMatchWhatMacOSReturns() {
        XCTAssertTrue(PrefValue.bool(false).matches(NSNumber(value: false)))
        XCTAssertTrue(PrefValue.bool(true).matches(NSNumber(value: 1)), "booleans can come back as 1")
        XCTAssertTrue(PrefValue.bool(true).matches("YES"), "or as text, when written with defaults -string")
        XCTAssertFalse(PrefValue.bool(true).matches(nil), "not set is not on")
        XCTAssertTrue(PrefValue.int(2).matches(NSNumber(value: 2.0)))
        XCTAssertTrue(PrefValue.double(0.25).matches(NSNumber(value: Float(0.25))))
        XCTAssertFalse(PrefValue.double(0).matches(NSNumber(value: 0.5)))
        XCTAssertTrue(PrefValue.string("SCcf").matches("SCcf"))
        XCTAssertFalse(PrefValue.string("SCcf").matches(NSNumber(value: 1)))
        XCTAssertEqual(PrefValue.from(NSNumber(value: true)), .bool(true))
        XCTAssertEqual(PrefValue.from(NSNumber(value: 15)), .int(15))
        XCTAssertEqual(PrefValue.from(NSNumber(value: 0.5)), .double(0.5))
        XCTAssertEqual(PrefValue.from("Always"), .string("Always"))
        XCTAssertNil(PrefValue.from(nil))
    }

    func testOffPutsBackWhatWasThereBefore() {
        let a = Pref(domain: "x", key: "a", value: .bool(true)), b = Pref(domain: "x", key: "b", value: .int(2))
        var before = MacChanges.remembering([:], [a, b]) { $0.key == "a" ? NSNumber(value: false) : nil }
        XCTAssertEqual(MacChanges.restored(before, a), .bool(false), "it was set to false")
        XCTAssertNil(MacChanges.restored(before, b), "it wasn't set: removed, so macOS's default applies")
        // A second change doesn't overwrite what was there before the first one.
        before = MacChanges.remembering(before, [a]) { _ in NSNumber(value: true) }
        XCTAssertEqual(MacChanges.restored(before, a), .bool(false))
    }

    /// Real CFPreferences round trip on a throwaway domain (never the Dock or Finder).
    func testRoundTripThroughMacOSPreferences() {
        let domain = "com.apex.tests.macchanges"
        defer { MacChanges.write(domain, "flag", nil); MacChanges.write(domain, "speed", nil) }
        MacChanges.write(domain, "flag", .bool(true))
        MacChanges.write(domain, "speed", .double(0.25))
        XCTAssertTrue(PrefValue.bool(true).matches(MacChanges.read(domain, "flag")))
        XCTAssertTrue(PrefValue.double(0.25).matches(MacChanges.read(domain, "speed")))
        MacChanges.write(domain, "flag", nil)
        XCTAssertNil(MacChanges.read(domain, "flag"), "removed")
    }
}
