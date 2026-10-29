import XCTest
@testable import TaskManager

/// Real archives made and changed with macOS's own tools in a throwaway folder.
final class ArchiveToolsTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-tools-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Photos/sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("Photos/a.txt"))
        try Data((0..<300_000).map { UInt8($0 % 251) }).write(to: dir.appendingPathComponent("Photos/sub/b.bin"))
        try Data("loose".utf8).write(to: dir.appendingPathComponent("notes.txt"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testNamesAndMagic() {
        XCTAssertEqual(ArchiveTools.baseName("photos.tar.gz"), "photos")
        XCTAssertEqual(ArchiveTools.baseName("set.zip.001"), "set")
        XCTAssertEqual(ArchiveTools.baseName("report.v2.zip"), "report.v2")
        XCTAssertEqual(ArchiveTools.unique("a.zip") { ["a.zip", "a 2.zip"].contains($0) }, "a 3.zip")
        XCTAssertEqual(ArchiveTools.unique("Folder") { $0 == "Folder" }, "Folder 2")
        XCTAssertEqual(ArchiveTools.smartName(topLevel: ["Photos"], archiveName: "x.zip").wrap, false, "one folder isn't put in another")
        XCTAssertEqual(ArchiveTools.smartName(topLevel: ["a", "b"], archiveName: "x.tar.gz").name, "x")
        XCTAssertEqual(ArchiveTools.kind(magic: Data([0x50, 0x4B, 0x03, 0x04, 0, 0])), "zip")
        XCTAssertEqual(ArchiveTools.kind(magic: Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])), "7z")
        var tar = Data(count: 300); tar.replaceSubrange(257..<262, with: Array("ustar".utf8))
        XCTAssertEqual(ArchiveTools.kind(magic: tar), "tar")
        XCTAssertNil(ArchiveTools.kind(magic: Data("plain text".utf8)))
    }

    /// Opening one file of a password zip in the preview (synchronous: expected errors stay in the test).
    func testPreviewOpensAPasswordFile() throws {
        let locked = dir.appendingPathComponent("locked.zip")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); p.currentDirectoryURL = dir
        p.arguments = ["--format=zip", "--options", "zip:encryption=aes256", "--passphrase", "s3cret", "-cf", locked.path, "notes.txt"]
        try p.run(); p.waitUntilExit()
        let out = dir.appendingPathComponent("p.txt")
        XCTAssertThrowsError(try ArchiveList.extract(locked, item: "notes.txt", to: out), "without the password: asks")
        XCTAssertThrowsError(try ArchiveList.extract(locked, item: "notes.txt", to: out, password: "nope"))
        try ArchiveList.extract(locked, item: "notes.txt", to: out, password: "s3cret")
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "loose")
    }

    func testCreateExtractEditCheck() async throws {
        let photos = dir.appendingPathComponent("Photos"), notes = dir.appendingPathComponent("notes.txt")
        // One folder → Photos.zip (ditto), extracted back as "Photos 2" beside the original.
        let zip = try await ArchiveTools.create([photos], format: .zip, password: nil, splitMB: nil)
        XCTAssertEqual(zip.lastPathComponent, "Photos.zip")
        let back = try await ArchiveTools.extract(zip, to: dir)
        XCTAssertEqual(back.lastPathComponent, "Photos 2", "never overwrites, never nests the folder in another")
        XCTAssertEqual(try String(contentsOf: back.appendingPathComponent("a.txt"), encoding: .utf8), "hello")
        // A file without an archive name is still recognised by its first bytes.
        let renamed = dir.appendingPathComponent("mystery")
        try FileManager.default.copyItem(at: zip, to: renamed)
        XCTAssertTrue(ArchiveTools.isArchive(renamed))

        // Several items → Archive.7z; extracting wraps them in a folder named after it.
        let seven = try await ArchiveTools.create([photos, notes], format: .sevenZip, password: nil, splitMB: nil)
        XCTAssertEqual(seven.lastPathComponent, "Archive.7z")
        let wrapped = try await ArchiveTools.extract(seven, to: dir)
        XCTAssertEqual(wrapped.lastPathComponent, "Archive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrapped.appendingPathComponent("notes.txt").path))

        // One file out of the archive.
        let one = try await ArchiveTools.extract(zip, items: ["Photos/sub/b.bin"], to: dir)
        XCTAssertEqual(one.lastPathComponent, "b.bin")

        // Password (AES-256): needed, refused when wrong, works when right.
        let locked = try await ArchiveTools.create([notes], format: .zip, password: "s3cret", splitMB: nil, name: "locked")
        do { _ = try await ArchiveTools.extract(locked, to: dir); XCTFail("needs a password") }
        catch let e as ArchiveTools.Failure { XCTAssertEqual(e, .needsPassword) }
        do { _ = try await ArchiveTools.extract(locked, to: dir, password: "nope"); XCTFail("wrong password") }
        catch let e as ArchiveTools.Failure { XCTAssertEqual(e, .wrongPassword) }
        let opened = try await ArchiveTools.extract(locked, to: dir, password: "s3cret")
        XCTAssertEqual(try String(contentsOf: opened, encoding: .utf8), "loose")
        XCTAssertNotNil(ArchiveTools.refusal(format: .sevenZip, password: "x", splitMB: nil), "a 7z password is refused, with why")
        XCTAssertNotNil(ArchiveTools.refusal(format: .sevenZip, password: nil, splitMB: 100))
        XCTAssertNotNil(ArchiveTools.refusal(format: .zip, password: "x", splitMB: 100), "password and split: not both")
        XCTAssertNil(ArchiveTools.refusal(format: .zip, password: "x", splitMB: nil))
        // Split into parts, then extracted from the first part.
        let big = dir.appendingPathComponent("big.bin")
        try Data((0..<2_500_000).map { _ in UInt8.random(in: 0...255) }).write(to: big)
        let split = try await ArchiveTools.create([big], format: .zip, password: nil, splitMB: 1, name: "parts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("parts.z01").path), "split into parts")
        XCTAssertEqual(ArchiveTools.splitParts(split)?.count, 3, "z01, z02 and the .zip")
        let joined = try await ArchiveTools.extract(split, to: dir.appendingPathComponent("Photos"))
        XCTAssertEqual(try Data(contentsOf: joined), try Data(contentsOf: big), "every byte back")
        let single = try await ArchiveTools.create([notes], format: .zip, password: nil, splitMB: nil, name: "one")
        XCTAssertEqual(try ArchiveList.items(single).map(\.path), ["notes.txt"], "a single file isn't put inside its folder's name")

        // Edit the zip: delete a folder, add a file into a folder.
        try await ArchiveTools.delete(["Photos/sub"], from: zip, folders: ["Photos/sub"])
        XCTAssertFalse(try ArchiveList.items(zip).contains { $0.path.hasPrefix("Photos/sub") })
        try await ArchiveTools.add([notes], to: zip, inside: "Photos")
        XCTAssertTrue(try ArchiveList.items(zip).contains { $0.path == "Photos/notes.txt" })

        // Check: healthy, then damaged.
        let healthy = await ArchiveTools.check(zip)
        XCTAssertNil(healthy)
        let bad = dir.appendingPathComponent("bad.zip")
        var bytes = try Data(contentsOf: seven)
        for i in 200..<260 { bytes[i] = 0 }
        try bytes.write(to: bad)
        let damage = await ArchiveTools.check(bad)
        XCTAssertNotNil(damage, "damage is found")
    }
}
