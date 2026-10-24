import XCTest
@testable import TaskManager

final class DriveToolsTests: XCTestCase {
    func device(_ id: String, connection: String = "USB", size: UInt64 = 64_000_000_000, isInt: Bool = false, ejectable: Bool = true) -> StorageDevice {
        StorageDevice(id: id, name: "Stick", model: "SanDisk", connection: connection, isInternal: isInt, ejectable: ejectable,
                      size: size, volumes: [], registryID: 1)
    }

    func testOnlySafeDrivesAreEligible() {
        let ok = device("disk6")
        let image = device("disk7", connection: "Disk image")
        let fixedInternal = device("disk8", connection: "Internal", isInt: true, ejectable: false)
        var startup = device("disk9"); startup.volumes = [VolumeInfo(name: "Mac", path: "/", capacity: 1, available: 1, format: "APFS")]
        XCTAssertEqual(DriveTools.eligible([ok, image, fixedInternal, startup]).map(\.id), ["disk6"])
    }

    func testLabels() {
        XCTAssertEqual(DriveTools.cleanLabel("my stick 2024!", for: .fat32), "MY STICK 20")
        XCTAssertEqual(DriveTools.cleanLabel("", for: .fat32), "UNTITLED")
        XCTAssertEqual(DriveTools.cleanLabel("Backups/Photos", for: .exfat), "BackupsPhotos")
        XCTAssertEqual(DriveTools.cleanLabel("Untitled 1", for: .apfs), "Untitled 1")
    }

    func testProgressParsing() {
        let dd = "  10485760 bytes (10 MB, 10 MiB) transferred 1.002s, 10 MB/s\r  52428800 bytes (52 MB, 50 MiB) transferred 2.004s, 26 MB/s"
        XCTAssertEqual(DriveTools.ddBytes(dd), 52_428_800)
        XCTAssertNil(DriveTools.ddBytes(""))
        XCTAssertEqual(DriveTools.lastPercent("Erasing disk: 0%... 10%... 20%... 100%...\nCopying to disk: 0%... 40%..."), 0.4)
    }

    func testPreflightCatchesProblemsBeforeErasing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let img = dir.appendingPathComponent("big.img")
        FileManager.default.createFile(atPath: img.path, contents: nil)
        let h = try FileHandle(forWritingTo: img); try h.truncate(atOffset: 2_000_000_000); try h.close()
        let small = device("disk6", size: 1_000_000_000)
        XCTAssertNotNil(DriveTools.preflight(DriveToolsPlan(device: small, boot: .image(img, .raw), scheme: .mbr, fileSystem: .exfat, label: "")),
                        "image bigger than the drive")
        XCTAssertNil(DriveTools.preflight(DriveToolsPlan(device: device("disk6"), boot: .image(img, .raw), scheme: .mbr, fileSystem: .exfat, label: "")))
        XCTAssertNotNil(DriveTools.preflight(DriveToolsPlan(device: device("disk7", connection: "Disk image"), boot: .nonBootable, scheme: .gpt, fileSystem: .exfat, label: "")))
        if DriveTools.wimlib == nil {
            XCTAssertNotNil(DriveTools.preflight(DriveToolsPlan(device: device("disk6"), boot: .image(img, .windows(splitNeeded: true)), scheme: .gpt, fileSystem: .fat32, label: "")),
                            "can't split a 4 GB+ install.wim without wimlib")
        }
        XCTAssertEqual(DriveTools.inspect(dir.appendingPathComponent("notes.txt")), .unsupported("Choose an .iso or .img file, or a macOS installer app."))
    }

    func testBootSignature() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".img")
        var d = Data(count: 1024); d[510] = 0x55; d[511] = 0xAA
        try d.write(to: f); defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertTrue(DriveTools.hasBootSignature(f))
        try Data(count: 1024).write(to: f)
        XCTAssertFalse(DriveTools.hasBootSignature(f))
    }

    // MARK: Real disks (temporary disk images). Run with APEX_DISK_TESTS=1.

    private func attachBlank(_ mb: Int) throws -> (disk: String, image: URL) {
        let img = FileManager.default.temporaryDirectory.appendingPathComponent("apex-test-\(UUID().uuidString).dmg")
        XCTAssertEqual(Shell.run("/usr/bin/hdiutil", ["create", "-size", "\(mb)m", "-layout", "NONE", "-type", "UDIF", "-fs", "ExFAT", img.path]).status, 0)
        let r = Shell.run("/usr/bin/hdiutil", ["attach", "-nomount", img.path])
        let disk = r.stdout.split(separator: "\n").first.map { String($0.split(separator: " ")[0]).replacingOccurrences(of: "/dev/", with: "") } ?? ""
        XCTAssertTrue(disk.hasPrefix("disk"))
        return (disk, img)
    }

    func testFormatAndWindowsCopyOnRealDisk() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APEX_DISK_TESTS"] == "1", "set APEX_DISK_TESTS=1")
        let (disk, img) = try attachBlank(400)
        defer { _ = Shell.run("/usr/bin/hdiutil", ["detach", "/dev/" + disk, "-force"]); try? FileManager.default.removeItem(at: img) }
        let target = device(disk, size: 400_000_000)

        // 1. Non bootable: exFAT, then FAT32.
        for fs in [DriveFileSystem.exfat, .fat32] {
            let err = DriveTools.run(DriveToolsPlan(device: target, boot: .nonBootable, scheme: .gpt, fileSystem: fs, label: "Apex Test"),
                                     cancel: .init()) { _, _ in }
            XCTAssertNil(err, "format \(fs.rawValue)")
            let mp = DriveTools.mountPoint(of: "/dev/" + disk)
            XCTAssertNotNil(mp)
            let info = Shell.run("/usr/sbin/diskutil", ["info", mp ?? ""]).stdout
            XCTAssertTrue(info.contains(fs == .exfat ? "ExFAT" : "MS-DOS FAT32"), info)
        }

        // 2. A tiny Windows-style ISO: detected as Windows and copied to FAT32.
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("winiso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try Data(count: 3_000_000).write(to: tree.appendingPathComponent("sources/install.wim"))
        try Data(count: 1000).write(to: tree.appendingPathComponent("bootmgr"))
        try Data(count: 2_000_000).write(to: tree.appendingPathComponent("setup.exe"))
        let iso = FileManager.default.temporaryDirectory.appendingPathComponent("win-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: tree); try? FileManager.default.removeItem(at: iso) }
        XCTAssertEqual(Shell.run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-o", iso.path, tree.path]).status, 0)
        let kind = DriveTools.inspect(iso)
        XCTAssertEqual(kind, .windows(splitNeeded: false))
        var steps: [String] = []
        let lock = NSLock()
        let err = DriveTools.run(DriveToolsPlan(device: target, boot: .image(iso, kind), scheme: .gpt, fileSystem: .exfat, label: "WINUSB"),
                                 cancel: .init()) { _, s in lock.withLock { steps.append(s) } }
        XCTAssertNil(err)
        XCTAssertTrue(steps.contains { $0.hasPrefix("Copying files") })
        // The drive was ejected at the end; mount it again to check the files.
        _ = Shell.run("/usr/bin/hdiutil", ["detach", "/dev/" + disk, "-force"])
        let r = Shell.run("/usr/bin/hdiutil", ["attach", img.path])
        XCTAssertEqual(r.status, 0)
        let mount = r.stdout.split(separator: "\n").compactMap { line in line.split(separator: "\t").last.map(String.init) }.first { $0.hasPrefix("/Volumes/") }
        XCTAssertNotNil(mount)
        if let m = mount {
            XCTAssertTrue(FileManager.default.fileExists(atPath: m + "/sources/install.wim"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: m + "/bootmgr"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: m + "/setup.exe"))
            XCTAssertTrue(Shell.run("/usr/sbin/diskutil", ["info", m]).stdout.contains("MS-DOS FAT32"))
            _ = Shell.run("/usr/bin/hdiutil", ["detach", m, "-force"])
        }
    }
}
