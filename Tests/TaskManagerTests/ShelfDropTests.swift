import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import TaskManager

/// Every kind of drop a shelf takes, and every way one can go wrong, on a real
/// pasteboard through the same function the shelf, its chips and the menu bar
/// icons call (`ShelfDrop.receive`), then onto a real store.
@MainActor final class ShelfDropTests: XCTestCase {
    private var dir: URL!
    private var pb: NSPasteboard!
    private var store: ShelfStore!
    private var own: URL { store.ownFolder(store.shown.id) }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-drop-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ShelfStore(folder: dir.appendingPathComponent("store"))
        pb = NSPasteboard(name: .init("apex-drop-test-\(UUID())"))
        pb.clearContents()
    }
    override func tearDown() async throws {
        pb.releaseGlobally()
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("locked.txt").path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, _ text: String = "hello") throws -> URL {
        let u = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: u)
        return u
    }

    /// Drops what's on the test pasteboard; waits for promised files.
    private func drop() async -> ShelfDrop.Outcome {
        await withCheckedContinuation { c in
            var resumed = false
            ShelfDrop.receive(pb, into: own, source: "Photos") { out in
                guard !resumed else { return }
                resumed = true
                c.resume(returning: out)
            }
        }
    }

    /// Drop, then add to the store like the shelf does; the message it would show.
    private func dropOnShelf() async -> (ShelfDrop.Outcome, String?) {
        var out = await drop()
        let added = store.add(out.files)
        out.duplicates = out.files.count - added
        return (out, out.message(added: added))
    }

    // MARK: Files

    func testFilesAndFoldersGoOnAsTheyAre() async throws {
        let a = try file("Report.pdf")
        let folder = dir.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pb.writeObjects([a as NSURL, folder as NSURL])
        XCTAssertTrue(ShelfDrop.canAccept(pb))
        let (out, message) = await dropOnShelf()
        XCTAssertEqual(out.files.map(\.lastPathComponent), ["Report.pdf", "Project"])
        XCTAssertNil(message, "everything went on: nothing to say")
        XCTAssertEqual(store.shown.items.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path), "the user's files aren't copied")
    }

    func testMissingAndUnreadableFilesAreSaid() async throws {
        let good = try file("Good.txt")
        let gone = try file("Gone.pdf")
        try FileManager.default.removeItem(at: gone)
        let locked = try file("locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        pb.writeObjects([good as NSURL, gone as NSURL, locked as NSURL])
        let (out, message) = await dropOnShelf()
        XCTAssertEqual(out.files, [good])
        XCTAssertEqual(out.missing, ["Gone.pdf"])
        XCTAssertEqual(out.unreadable, ["locked.txt"])
        XCTAssertEqual(message, "Added 1. “Gone.pdf” isn’t on the disk any more. Apex isn’t allowed to open “locked.txt”.")
        XCTAssertEqual(store.shown.items.map(\.name), ["Good.txt"], "only the good one went on")
    }

    func testDuplicatesAreSaid() async throws {
        let a = try file("a.png"), b = try file("b.png"), c = try file("c.png")
        store.add([a, b])
        pb.writeObjects([a as NSURL])
        var (out, message) = await dropOnShelf()
        XCTAssertEqual(message, "Already on this shelf.")
        pb.clearContents(); pb.writeObjects([a as NSURL, b as NSURL])
        (out, message) = await dropOnShelf()
        XCTAssertEqual(message, "All 2 are already on this shelf.")
        pb.clearContents(); pb.writeObjects([a as NSURL, c as NSURL])
        (out, message) = await dropOnShelf()
        XCTAssertEqual(message, "Added 1. 1 was already on this shelf.")
        XCTAssertEqual(out.duplicates, 1)
        XCTAssertEqual(store.shown.items.count, 3)
    }

    func testAFilePathAsTextIsThatFile() async throws {
        let a = try file("Notes.md")
        pb.setString(a.path, forType: .string)
        let (out, message) = await dropOnShelf()
        XCTAssertEqual(out.files, [a], "the file itself, not a text copy of its path")
        XCTAssertNil(message)
    }

    // MARK: Pictures, links and text with no file

    func testPNGKeepsItsBytes() async throws {
        let png = try pictureData(.png)
        pb.setData(png, forType: .png)
        XCTAssertTrue(ShelfDrop.canAccept(pb))
        let out = await drop()
        let u = try XCTUnwrap(out.files.first)
        XCTAssertTrue(u.lastPathComponent.hasPrefix("Image "))
        XCTAssertEqual(u.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: u), png, "not re-encoded")
        XCTAssertEqual(u.deletingLastPathComponent().standardizedFileURL, own.standardizedFileURL, "kept in the shelf's own folder")
    }

    func testJPEGKeepsItsBytes() async throws {
        let jpeg = try pictureData(.jpeg)
        pb.setData(jpeg, forType: .init(UTType.jpeg.identifier))
        let out = await drop()
        let u = try XCTUnwrap(out.files.first)
        XCTAssertEqual(u.pathExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: u), jpeg)
    }

    func testTIFFBecomesAPNG() async throws {
        pb.setData(try pictureData(.tiff), forType: .tiff)
        let out = await drop()
        let u = try XCTUnwrap(out.files.first)
        XCTAssertEqual(u.pathExtension, "png")
        XCTAssertNotNil(NSImage(contentsOf: u))
    }

    func testLinksBecomeWeblocsNamedAfterThePage() async throws {
        let item = NSPasteboardItem()
        item.setString("https://www.apple.com/mac/", forType: .URL)
        item.setString("Mac - Apple", forType: .init("public.url-name"))
        let bare = NSPasteboardItem()
        bare.setString("https://example.com/a/b", forType: .URL)
        pb.writeObjects([item, bare])
        let out = await drop()
        XCTAssertEqual(out.files.map(\.lastPathComponent), ["Mac - Apple.webloc", "example.com.webloc"])
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: out.files[0]), format: nil) as? [String: String]
        XCTAssertEqual(plist?["URL"], "https://www.apple.com/mac/")
        // The same page again: a second file, nothing overwritten.
        let same = NSPasteboardItem()
        same.setString("https://www.apple.com/mac/", forType: .URL)
        same.setString("Mac - Apple", forType: .init("public.url-name"))
        pb.clearContents(); pb.writeObjects([same])
        let again = await drop()
        XCTAssertEqual(again.files.map(\.lastPathComponent), ["Mac - Apple 2.webloc"])
    }

    func testAnAddressTypedAsTextIsALink() async throws {
        pb.setString("https://example.com", forType: .string)
        let out = await drop()
        XCTAssertEqual(out.files.map(\.pathExtension), ["webloc"])
    }

    func testTextIsSavedNamedAfterItsFirstLine() async throws {
        let text = "Meeting notes for Monday\nBring the timetable"
        pb.setString(text, forType: .string)
        let out = await drop()
        let u = try XCTUnwrap(out.files.first)
        XCTAssertEqual(u.lastPathComponent, "Meeting notes for Monday.txt")
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), text)
        let long = ShelfDrop.title(forText: String(repeating: "word ", count: 20))
        XCTAssertTrue(long.hasSuffix("word…") && long.count <= 41, "at most 40 characters and …: \(long)")
        XCTAssertTrue(ShelfDrop.title(forText: "\n\n").hasPrefix("Text "))
    }

    func testNamesAreSafeOnAMac() {
        XCTAssertEqual(ShelfDrop.safeName("a/b:c"), "a-b-c")
        XCTAssertEqual(ShelfDrop.safeName("..hidden"), "hidden", "a leading dot would hide the file")
        XCTAssertEqual(ShelfDrop.safeName("   "), "Dropped")
        XCTAssertLessThanOrEqual(ShelfDrop.safeName(String(repeating: "é", count: 300)).utf8.count, 255)
    }

    // MARK: Things a shelf can't keep

    func testSomethingAShelfCantKeepIsSaid() async throws {
        XCTAssertFalse(ShelfDrop.canAccept(pb), "empty pasteboard")
        pb.setData(Data([1, 2, 3]), forType: .init("com.example.private-drag"))
        XCTAssertFalse(ShelfDrop.canAccept(pb))
        let (out, message) = await dropOnShelf()
        XCTAssertTrue(out.unsupported)
        XCTAssertEqual(message, "That can’t go on a shelf. Drop files, pictures, links or text.")
    }

    func testTheStoreNeverTakesAWebAddressForAFile() {
        XCTAssertEqual(store.add([URL(string: "https://example.com/report.pdf")!]), 0)
        XCTAssertTrue(store.shown.items.isEmpty)
    }

    func testFilesMovedAwayCanBeTidiedOff() throws {
        let a = try file("a.txt"), b = try file("b.txt")
        store.add([a, b])
        try FileManager.default.removeItem(at: b)
        store.removeMissing()
        XCTAssertEqual(store.shown.items.map(\.name), ["a.txt"])
    }

    // MARK: Files an app hands over only on drop (Photos, Mail…)

    // Handing over a promised file needs a real drag between two apps (the
    // system's drag server); inside a test the app's side is never asked to
    // write. What can be checked here: the shelf takes the drag, and a file
    // that doesn't come is reported instead of silently missing.
    func testAPromiseDragIsTaken() {
        let w = PromiseWriter(name: "IMG_0001.jpg", mode: .never)
        pb.writeObjects([NSFilePromiseProvider(fileType: UTType.jpeg.identifier, delegate: w)])
        XCTAssertTrue(ShelfDrop.canAccept(pb), "Photos / Mail drags light the shelf up")
        withExtendedLifetime(w) {}
    }

    func testAPromiseThatNeverArrivesTimesOut() async throws {
        ShelfDrop.promiseTimeout = 0.5
        defer { ShelfDrop.promiseTimeout = 120 }
        let w = PromiseWriter(name: "Never.mov", mode: .never)
        pb.writeObjects([NSFilePromiseProvider(fileType: UTType.quickTimeMovie.identifier, delegate: w)])
        let (out, message) = await dropOnShelf()
        XCTAssertEqual(out.notDelivered, 1)
        XCTAssertEqual(message, "Photos didn’t hand over the file. Try again, or save it to a folder first.")
        XCTAssertTrue(store.shown.items.isEmpty)
        withExtendedLifetime(w) {}
    }

    func testEveryDropIsCountedSoTheFloatingShelfStaysUp() async throws {
        let before = ShelfDrop.drops
        pb.setData(Data([1]), forType: .init("com.example.private-drag"))
        _ = await drop()
        XCTAssertEqual(ShelfDrop.drops, before + 1, "even a drop that didn't work")
    }

    func testMessages() {
        var o = ShelfDrop.Outcome(source: nil)
        XCTAssertNil(o.message(added: 3))
        o.notDelivered = 2
        XCTAssertEqual(o.message(added: 0), "The app didn’t hand over 2 files. Try again, or save it to a folder first.")
        o = ShelfDrop.Outcome(missing: ["a", "b"], unreadable: ["c", "d", "e"])
        XCTAssertEqual(o.message(added: 0), "2 files aren’t on the disk any more. Apex isn’t allowed to open 3 files.")
        o = ShelfDrop.Outcome(duplicates: 3)
        XCTAssertEqual(o.message(added: 2), "Added 2. 3 were already on this shelf.")
        XCTAssertEqual(ShelfDrop.waitingMessage(1, source: "Photos"), "Getting the file from Photos…")
        XCTAssertEqual(ShelfDrop.waitingMessage(3, source: nil), "Getting 3 files from the app…")
    }

    // MARK: Dragging files out of the floating shelf

    /// The floating shelf moves when its background is dragged. The stack and
    /// the list rows must not count as background, or grabbing them moves the
    /// shelf instead of dragging the photo out (owner's bug, 2026-10-26).
    func testGrabbingTheStackOrARowDragsFilesNotTheShelf() {
        XCTAssertFalse(MultiFileDragSource.DragView().mouseDownCanMoveWindow)
        XCTAssertFalse(FileRowDragSource.RowView().mouseDownCanMoveWindow)
        XCTAssertTrue(NSView().mouseDownCanMoveWindow, "a plain see-through view would move the window")
    }

    // MARK: Helpers

    private func pictureData(_ type: NSBitmapImageRep.FileType) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<40 { for y in 0..<30 { rep.setColor(NSColor(red: CGFloat(x) / 40, green: CGFloat(y) / 30, blue: 0.5, alpha: 1), atX: x, y: y) } }
        return try XCTUnwrap(rep.representation(using: type, properties: [:]))
    }
}

/// Plays the app on the other end of a file promise.
final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    enum Mode { case write(Data), empty, fail, never }
    let name: String
    let mode: Mode
    init(name: String, mode: Mode) { self.name = name; self.mode = mode }

    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }

    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        switch mode {
        case .write(let d):
            do { try d.write(to: url); completionHandler(nil) } catch { completionHandler(error) }
        case .empty:
            FileManager.default.createFile(atPath: url.path, contents: Data())
            completionHandler(nil)
        case .fail:
            completionHandler(CocoaError(.fileWriteUnknown))
        case .never:
            break
        }
    }
}
