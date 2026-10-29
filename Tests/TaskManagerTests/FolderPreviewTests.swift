import AppKit
import SwiftUI
import Carbon.HIToolbox
import XCTest
@testable import TaskManager

final class FolderPreviewTests: XCTestCase {
    func e(_ name: String, _ size: UInt64?, folder: Bool = false) -> FolderEntry {
        FolderEntry(name: name, path: "/x/" + name, isFolder: folder, size: size, modified: nil)
    }

    func testBiggestFirstThenUnmeasuredFoldersByName() {
        let s = FolderPreview.sorted([e("b", nil, folder: true), e("small.txt", 10), e("a", nil, folder: true), e("big.mov", 900), e("Same 2", 10)])
        XCTAssertEqual(s.map(\.name), ["big.mov", "Same 2", "small.txt", "a", "b"], "equal sizes by name; folders still measuring last")
    }

    func testKindsAndCounts() {
        let list = [e("Photos", 500, folder: true), e("a.jpg", 300), e("b.HEIC", 100), e("c.pdf", 50), e("d.zip", 0)]
        XCTAssertEqual(FolderPreview.kinds(list).map(\.kind), ["Folders", "Photos", "Documents"], "empty kinds left out")
        XCTAssertEqual(FolderPreview.kinds(list).first { $0.kind == "Photos" }?.bytes, 400)
        XCTAssertEqual(FolderPreview.counts(list), "1 folder, 4 files")
        XCTAssertEqual(FolderPreview.counts([e("a", 1, folder: true), e("b", 1, folder: true)]), "2 folders")
        XCTAssertEqual(FolderPreview.counts([]), "Empty")
    }

    func testListsTheFolderItselfAndCountsHiddenItems() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-preview-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub/Deeper"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 1, count: 50_000).write(to: dir.appendingPathComponent("file.bin"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))
        let r = FolderPreview.list(dir)
        XCTAssertEqual(Set(r.entries.map(\.name)), ["file.bin", "Sub"], "only the folder's own items")
        XCTAssertEqual(r.hidden, 1)
        XCTAssertNil(r.entries.first { $0.name == "Sub" }?.size, "folders are measured afterwards")
        XCTAssertGreaterThanOrEqual(r.entries.first { $0.name == "file.bin" }?.size ?? 0, 50_000)
        XCTAssertEqual(FolderPreview.folder(for: dir.appendingPathComponent("file.bin")).standardizedFileURL, dir.standardizedFileURL,
                       "a selected file previews the folder it's in")
        XCTAssertEqual(FolderPreview.folder(for: dir.appendingPathComponent("Sub")).lastPathComponent, "Sub")
    }

    func testShortcuts() {
        XCTAssertEqual(FolderPreview.Choice.optionCommandP.combo.code, UInt32(kVK_ANSI_P))
        XCTAssertEqual(FolderPreview.Choice.optionCommandP.combo.modifiers, UInt32(optionKey | cmdKey))
        XCTAssertEqual(Set(FolderPreview.Choice.allCases.map(\.title)).count, FolderPreview.Choice.allCases.count)
        XCTAssertNotEqual(FolderPreview.hotKeyID, ShelfHotKey.id, "each shortcut has its own id")
    }

    // MARK: Archives and options

    /// Real archives made with macOS's own tools, read back without unpacking.
    func testArchivesListWithoutUnpacking() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-arc-\(UUID())")
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hello".utf8).write(to: src.appendingPathComponent("a.txt"))
        try Data(repeating: 7, count: 20_000).write(to: src.appendingPathComponent("sub/b.bin"))
        func run(_ tool: String, _ args: [String]) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args; p.currentDirectoryURL = dir
            try? p.run(); p.waitUntilExit()
        }
        run("/usr/bin/zip", ["-qr", "t.zip", "src"])
        run("/usr/bin/tar", ["czf", "t.tar.gz", "src"])
        run("/usr/bin/tar", ["cJf", "t.tar.xz", "src"])
        run("/usr/bin/tar", ["--format=7zip", "-cf", "t.7z", "src"])
        for name in ["t.zip", "t.tar.gz", "t.tar.xz", "t.7z"] {
            let url = dir.appendingPathComponent(name)
            XCTAssertTrue(ArchiveList.isArchive(url), name)
            let items = try ArchiveList.items(url)
            XCTAssertEqual(Set(items.filter { !$0.isFolder }.map(\.path)), ["src/a.txt", "src/sub/b.bin"], name)
            let top = FolderPreview.entries(archive: url, at: "", items: items)
            XCTAssertEqual(top.map(\.name), ["src"], name)
            XCTAssertEqual(top.first?.size, 20_005, "a folder in an archive adds up everything under it: \(name)")
            XCTAssertTrue(top.first?.isFolder == true && top.first?.archive == url.path)
            let inside = FolderPreview.entries(archive: url, at: "src", items: items)
            XCTAssertEqual(Set(inside.map(\.name)), ["a.txt", "sub"], name)
            XCTAssertEqual(inside.first { $0.name == "sub" }?.size, 20_000)
            let out = dir.appendingPathComponent("out-\(name).txt")
            try ArchiveList.extract(url, item: "src/a.txt", to: out)
            XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "hello", "one file taken out: \(name)")
        }
        XCTAssertThrowsError(try ArchiveList.items(src.appendingPathComponent("a.txt")), "not an archive: says so")
    }

    func testArchiveFoldersImpliedByPaths() {
        // Some zips list only files; their folders still appear, with totals.
        let items = [ArchiveList.Item(path: "x/y/1.txt", size: 10, isFolder: false, modified: nil),
                     ArchiveList.Item(path: "x/2.txt", size: 5, isFolder: false, modified: nil),
                     ArchiveList.Item(path: "top.txt", size: 1, isFolder: false, modified: nil)]
        let top = ArchiveList.children(of: "", in: items)
        XCTAssertEqual(Set(top.map(\.path)), ["x", "top.txt"])
        XCTAssertEqual(top.first { $0.path == "x" }?.size, 15)
        XCTAssertEqual(ArchiveList.children(of: "x", in: items).first { $0.isFolder }?.path, "x/y")
        XCTAssertEqual(ArchiveList.clean("./a/b/"), "a/b")
        XCTAssertEqual(ArchiveList.clean("/abs\\win.txt"), "abs/win.txt")
    }

    func testSortingOptions() {
        let list = [e("b.txt", 5), e("Zed", 100, folder: true), e("a.mov", 50)]
        XCTAssertEqual(FolderPreview.sorted(list, by: .size, foldersOnTop: false).map(\.name), ["Zed", "a.mov", "b.txt"])
        XCTAssertEqual(FolderPreview.sorted(list, by: .name, foldersOnTop: false).map(\.name), ["a.mov", "b.txt", "Zed"])
        XCTAssertEqual(FolderPreview.sorted(list, by: .name, foldersOnTop: true).map(\.name), ["Zed", "a.mov", "b.txt"], "folders on top")
        XCTAssertEqual(FolderPreview.sorted(list, by: .size, ascending: true, foldersOnTop: false).map(\.name), ["b.txt", "a.mov", "Zed"])
        XCTAssertEqual(FolderPreview.skipList("node_modules, .git,,  build "), ["node_modules", ".git", "build"])
    }

    func testHiddenFilesCanBeShown() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-hidden-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent(".env"))
        XCTAssertEqual(FolderPreview.list(dir, showHidden: true).entries.map(\.name), [".env"])
        XCTAssertEqual(FolderPreview.list(dir).hidden, 1)
    }
}

/// APEX_RENDER_PREVIEW=dir renders the Preview-Folder panel (list, icons, inside
/// an archive) for a made-up folder, off screen.
final class FolderPreviewRenderTests: XCTestCase {
    @MainActor func testRender() async throws {
        guard let out = ProcessInfo.processInfo.environment["APEX_RENDER_PREVIEW"] else { throw XCTSkip("set APEX_RENDER_PREVIEW") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Holiday \(UUID().uuidString.prefix(4))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Videos"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, color) in [("beach.png", NSColor.systemTeal), ("sunset.png", .systemOrange), ("forest.png", .systemGreen)] {
            let img = NSImage(size: NSSize(width: 640, height: 480), flipped: false) { r in color.setFill(); r.fill(); return true }
            let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
        }
        try Data(repeating: 1, count: 3_000_000).write(to: dir.appendingPathComponent("Videos/clip.mov"))
        try Data("notes".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); p.currentDirectoryURL = dir
        p.arguments = ["-qr", "photos.zip", "beach.png", "sunset.png", "Videos"]; try p.run(); p.waitUntilExit()

        let d = UserDefaults.standard
        let keys = [FolderPreview.Keys.layout, FolderPreview.Keys.columns]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d.set(v, forKey: k) } }
        d.removeObject(forKey: FolderPreview.Keys.columns)

        let model = FolderPreviewModel()
        func shot(_ name: String, dark: Bool = false) async throws {
            try await Task.sleep(for: .milliseconds(300))
            let host = NSHostingView(rootView: FolderPreviewView(model: model, onClose: {}))
            let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 560, height: 580), styleMask: .borderless, backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.contentView = host
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/preview-\(name).png"))
            w.orderOut(nil)
        }
        d.set("list", forKey: FolderPreview.Keys.layout)
        model.load(dir)
        try await Task.sleep(for: .seconds(1))
        try await shot("list")
        d.set("icons", forKey: FolderPreview.Keys.layout)
        try await shot("icons", dark: true)
        d.set("list", forKey: FolderPreview.Keys.layout)
        model.load(dir.appendingPathComponent("photos.zip"))
        for _ in 0..<50 where model.entries.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(Set(model.entries.map(\.name)), ["beach.png", "sunset.png", "Videos"])
        try await shot("archive")
    }
}
