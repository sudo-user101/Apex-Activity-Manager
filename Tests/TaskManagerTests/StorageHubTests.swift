import XCTest
@testable import TaskManager

final class StorageHubTests: XCTestCase {
    func testMeasuresFoldersOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("analyze-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_000_000).write(to: dir.appendingPathComponent("a/big.bin"))
        try Data(repeating: 2, count: 300_000).write(to: dir.appendingPathComponent("a/b/small.bin"))
        try Data(repeating: 3, count: 10).write(to: dir.appendingPathComponent("tiny.txt"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let (size, partial) = DiskAnalyzer.measure(dir.path)
        XCTAssertFalse(partial)
        XCTAssertGreaterThanOrEqual(size, 1_300_000, "allocated size is at least the data")
        XCTAssertLessThan(size, 1_500_000)
        let kids = DiskAnalyzer.children(of: dir.path)
        XCTAssertEqual(Set(kids.map(\.name)), ["a", "tiny.txt"])
        XCTAssertEqual(kids.first { $0.name == "a" }?.isDirectory, true)
        XCTAssertEqual(DiskAnalyzer.measure(dir.appendingPathComponent("missing").path).1, true)
    }

    func testOverviewStartsWithTheBigLocations() {
        let names = DiskAnalyzer.roots().map(\.name)
        XCTAssertEqual(Array(names.prefix(5)), ["Home", "User Library", "Applications", "System Library", "Old Downloads (90 days+)"])
    }

    func testEveryOptimizeTaskIsExplained() {
        XCTAssertEqual(Set(OptimizeTask.all.map(\.id)), Set(OptimizeTask.ID.allCases))
        for t in OptimizeTask.all { XCTAssertFalse(t.detail.isEmpty); XCTAssertFalse(t.title.isEmpty) }
        XCTAssertTrue(OptimizeTask.all.first { $0.id == .dns }!.needsAdmin)
        XCTAssertFalse(OptimizeTask.all.first { $0.id == .fileCache }!.defaultOn, "purge is opt-in")
        XCTAssertFalse(OptimizeTask.all.first { $0.id == .quarantine }!.defaultOn)
    }
}
