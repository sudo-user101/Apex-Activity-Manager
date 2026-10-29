import XCTest
@testable import TaskManager

final class AppSwitcherTests: XCTestCase {
    func item(_ pid: pid_t, _ win: CGWindowID, _ i: Int = 0, minimized: Bool = false) -> SwitcherItem {
        SwitcherItem(pid: pid, windowID: win, index: i, appName: "App \(pid)", title: "w\(win)", minimized: minimized, bundleURL: nil, element: nil)
    }

    func testOrderFollowsTheScreenFrontToBack() {
        let items = [item(1, 10), item(2, 20), item(1, 11, 1), item(3, 30, minimized: true), item(4, 0)]
        let z: [CGWindowID] = [20, 11, 10]
        let o = SwitcherRules.ordered(items, zOrder: z, appOrder: [2, 1, 4], onePerApp: false, minimizedLast: true)
        XCTAssertEqual(o.map(\.windowID), [20, 11, 10, 0, 30], "front to back, then windowless apps, minimized last")
        XCTAssertEqual(SwitcherRules.ordered(items, zOrder: z, appOrder: [2, 1, 4], onePerApp: true, minimizedLast: true).map(\.pid), [2, 1, 4, 3],
                       "one entry per app, in the same order")
    }

    func testSelection() {
        XCTAssertEqual(SwitcherRules.start(count: 5), 1, "a quick press goes back to the last window")
        XCTAssertEqual(SwitcherRules.start(count: 1), 0)
        XCTAssertEqual(SwitcherRules.step(4, by: 1, count: 5), 0, "round to the start")
        XCTAssertEqual(SwitcherRules.step(0, by: -1, count: 5), 4, "and back round to the end")
        XCTAssertEqual(SwitcherRules.step(0, by: 1, count: 0), 0)
    }

    func testOnlyPermissionsThatDontWorkAreCleared() {
        let working: [Permission: Bool] = [.accessibility: false, .automation: true, .screenRecording: false, .fullDisk: true]
        XCTAssertEqual(PermissionCenter.staleToClear(changed: true, working: working), [.accessibility, .screenRecording])
        XCTAssertEqual(PermissionCenter.staleToClear(changed: false, working: working), [], "same copy of Apex: nothing touched")
    }

    func testOnlyAReplacedCopyClearsSwitches() {
        let app = "/Applications/Apex Activity Manager.app", dev = "/Users/me/native/dist/Apex Activity Manager.app"
        XCTAssertTrue(PermissionCenter.replacedInPlace(lastID: "a", lastPath: app, id: "b", path: app), "updated in place")
        XCTAssertFalse(PermissionCenter.replacedInPlace(lastID: "a", lastPath: dev, id: "b", path: app), "another copy opened: its switch isn't ours to clear")
        XCTAssertFalse(PermissionCenter.replacedInPlace(lastID: "a", lastPath: nil, id: "b", path: app), "where the last copy was isn't known")
        XCTAssertFalse(PermissionCenter.replacedInPlace(lastID: "a", lastPath: app, id: "a", path: app), "same build")
        XCTAssertFalse(PermissionCenter.replacedInPlace(lastID: nil, lastPath: nil, id: "a", path: app), "first run")
    }
}
