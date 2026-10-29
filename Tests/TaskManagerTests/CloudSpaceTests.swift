import AppKit
import SwiftUI
import XCTest
@testable import TaskManager

final class CloudSpaceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func e(_ path: String, _ mb: Double, onMac: Bool = true, daysAgo: Double = 1) -> CloudEntry {
        let b = UInt64(mb * 1_000_000)
        return CloudEntry(path: "/r/" + path, bytes: b, onMac: onMac ? b : 0, lastUsed: now.addingTimeInterval(-daysAgo * 86400))
    }

    func testFolders() {
        var b = CloudSpace.Builder(root: "/r", now: now)
        b.add(e("Photos/a.jpg", 5)); b.add(e("Photos/b.jpg", 3, onMac: false)); b.add(e("top.txt", 0.01))
        let o = b.finish { _, _ in nil }
        XCTAssertEqual(o.folders.map(\.name), ["Photos", "Files at the top level"])
        XCTAssertEqual(o.folders[0].bytes, 8_000_000, "online-only files count")
        XCTAssertEqual(o.totalBytes, 8_010_000)
    }

    func testSuggestions() {
        var b = CloudSpace.Builder(root: "/r", now: now)
        b.add(e("Report.pdf", 4)); b.add(e("Old/Report (1).pdf", 4, onMac: false))          // online-only: same name + size
        b.add(e("a.mov", 9)); b.add(e("b.mov", 9))                                              // same size, compared: differ
        b.add(e("c.bin", 7)); b.add(e("deep/copy-of-c.bin", 7))                                 // compared: same
        b.add(e("Downloads/Tool.dmg", 50, daysAgo: 90)); b.add(e("New.dmg", 50.5, daysAgo: 2))
        b.add(e("Video/2019.mov", 800, daysAgo: 500)); b.add(e("Video/recent.mov", 900, daysAgo: 10))
        let o = b.finish { x, y in
            if x.onlineOnly || y.onlineOnly { return nil }
            return x.name.hasSuffix(".bin") && y.name.hasSuffix(".bin")
        }
        let by = Dictionary(uniqueKeysWithValues: o.suggestions.map { ($0.kind, $0.items.map(\.name)) })
        XCTAssertEqual(Set(by[.duplicates] ?? []), ["Report (1).pdf", "copy-of-c.bin"])
        XCTAssertEqual(by[.installers], ["Tool.dmg"])
        XCTAssertEqual(by[.unused], ["2019.mov"])
        XCTAssertEqual(o.largest.first?.name, "recent.mov")
    }

    func testBaseName() {
        XCTAssertEqual(CloudSpace.baseName("Report (1).PDF"), "report.pdf")
        XCTAssertEqual(CloudSpace.baseName("Report 2.pdf"), "report.pdf")
        XCTAssertEqual(CloudSpace.baseName("Report copy.pdf"), "report.pdf")
        XCTAssertEqual(CloudSpace.baseName("IMG_1234.jpg"), "img_1234.jpg")
    }

    /// A real folder: two identical files, one same-size file with other contents, an old installer.
    func testRealScanAndTrash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-space-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Data((0..<2_000_000).map { UInt8($0 % 251) })
        var b = a; b[1_999_999] ^= 0xFF
        try a.write(to: dir.appendingPathComponent("one.bin"))
        try a.write(to: dir.appendingPathComponent("Sub/one again.bin"))
        try b.write(to: dir.appendingPathComponent("other.bin"))
        let dmg = dir.appendingPathComponent("Setup.dmg")
        try Data(count: 1_500_000).write(to: dmg)
        let old = timeval(tv_sec: Int(Date().addingTimeInterval(-60 * 86400).timeIntervalSince1970), tv_usec: 0)
        var times = [old, old]; XCTAssertEqual(utimes(dmg.path, &times), 0)

        let u = Cloud.scan(dir.path)
        XCTAssertEqual(u.uploadChecked, 0, "a plain folder: no upload state read")
        let o = try XCTUnwrap(u.space)
        let by = Dictionary(uniqueKeysWithValues: o.suggestions.map { ($0.kind, $0) })
        XCTAssertEqual(by[.duplicates]?.items.map(\.name), ["one again.bin"])
        XCTAssertEqual(by[.installers]?.items.map(\.name), ["Setup.dmg"])
        XCTAssertEqual(o.folders.first { $0.name == "Sub" }?.bytes, 2_000_000)

        let r = Cloud.trash(by[.duplicates]!.items)
        XCTAssertEqual(r.moved, 1); XCTAssertTrue(r.failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sub/one again.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("one.bin").path))
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        for f in (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [] where f.hasPrefix("one again") {
            try? FileManager.default.removeItem(at: trash.appendingPathComponent(f))
        }
    }

    /// APEX_RENDER_SPACE=dir: scans each cloud folder on this Mac (read-only),
    /// prints how long it took and what it found, renders the section.
    @MainActor func testRenderReal() async throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_RENDER_SPACE"] else { throw XCTSkip("set APEX_RENDER_SPACE") }
        for s in Cloud.detected() {
            let start = Date()
            let u = await Task.detached { Cloud.scan(s.path) }.value
            print("SCAN \(s.name): \(u.files) files in \(String(format: "%.1f", Date().timeIntervalSince(start))) s · upload state read for \(u.uploadChecked)\(u.uploadCheckLimited ? " (limited)" : "") · not uploaded \(u.notUploaded) · issues \(u.uploadIssues) · untouched \(u.untouched.count) · suggestions \(u.space?.suggestions.map { "\($0.kind.rawValue)=\($0.items.count)" } ?? [])")
            guard let o = u.space else { continue }
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: CloudSpaceSection(service: s, overview: o).frame(width: 720).padding(20)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/space-\(s.name.replacingOccurrences(of: " ", with: ""))-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}

final class CloudSpaceComparerTests: XCTestCase {
    func testBudget() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-cmp-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = Data(count: 1000)
        for n in ["a", "b", "c", "d"] { try d.write(to: dir.appendingPathComponent(n)) }
        func e(_ n: String) -> CloudEntry { CloudEntry(path: dir.appendingPathComponent(n).path, bytes: 1000, onMac: 1000) }
        let c = CloudSpace.Comparer(budget: 3000, maxFile: 10_000)
        XCTAssertEqual(c(e("a"), e("b")), true)
        XCTAssertNil(c(e("c"), e("d")), "budget used up: falls back to name and size")
        XCTAssertNil(CloudSpace.Comparer(budget: 1_000_000, maxFile: 500)(e("a"), e("b")), "too big to compare")
    }
}

final class CloudSpaceInsideTests: XCTestCase {
    func testInsideSomething() {
        XCTAssertTrue(CloudSpace.isInsideSomething("Apps/Tool.app/Contents/MacOS/Tool"))
        XCTAssertTrue(CloudSpace.isInsideSomething("Developer/site/node_modules/x/big.js"))
        XCTAssertTrue(CloudSpace.isInsideSomething("Developer/repo/.git/objects/pack/p.pack"))
        XCTAssertTrue(CloudSpace.isInsideSomething("Pictures/Photos Library.photoslibrary/originals/A/1.heic"))
        XCTAssertFalse(CloudSpace.isInsideSomething("Downloads/Tool.dmg"))
        XCTAssertFalse(CloudSpace.isInsideSomething("Photos/2024/IMG_1.heic"))
        XCTAssertFalse(CloudSpace.isInsideSomething("top.pdf"))
    }
}
