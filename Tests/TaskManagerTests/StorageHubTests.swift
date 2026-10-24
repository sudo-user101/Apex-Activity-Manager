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

final class FastSizeTests: XCTestCase {
    func testParallelSizeMatchesFileByFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("apex-fs-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for d in ["a/b/c", "d", "e/f"] { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        for (i, f) in ["a/1", "a/b/2", "a/b/c/3", "d/4", "e/f/5", "6"].enumerated() {
            try Data(repeating: 7, count: 10_000 * (i + 1)).write(to: root.appendingPathComponent(f))
        }
        var expected: UInt64 = 0
        for case let u as URL in fm.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])! {
            let v = try u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v.isRegularFile == true { expected += UInt64(v.totalFileAllocatedSize ?? 0) }
        }
        let r = FastSize.allocated(root.path)
        XCTAssertEqual(r.bytes, expected)
        XCTAssertFalse(r.partial)
        XCTAssertEqual(FastSize.allocated([root.appendingPathComponent("d").path, "/nonexistent-apex"]).last, 0)
    }
}
