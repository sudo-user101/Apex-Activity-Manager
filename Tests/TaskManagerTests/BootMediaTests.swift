import XCTest
@testable import TaskManager

final class BootMediaTests: XCTestCase {
    let wimXML = """
    <WIM><IMAGE INDEX="1"><WINDOWS><ARCH>9</ARCH><LANGUAGES><LANGUAGE>en-US</LANGUAGE></LANGUAGES>\
    <VERSION><MAJOR>10</MAJOR><BUILD>22631</BUILD></VERSION></WINDOWS><NAME>Windows 11 Home</NAME>\
    <DISPLAYNAME>Windows 11 Home</DISPLAYNAME></IMAGE><IMAGE INDEX="2"><WINDOWS><ARCH>9</ARCH>\
    <VERSION><BUILD>22631</BUILD></VERSION></WINDOWS><NAME>Windows 11 Pro</NAME></IMAGE></WIM>
    """

    func testParsesWindowsEditions() {
        let info = WindowsImage.parse(wimXML)
        XCTAssertEqual(info.editions.map(\.name), ["Windows 11 Home", "Windows 11 Pro"])
        XCTAssertEqual(info.arch, .amd64)
        XCTAssertTrue(info.isWindows11)
        XCTAssertEqual(info.editions[0].languages, ["en-US"])
        XCTAssertFalse(WindowsImage.parse(wimXML.replacingOccurrences(of: "22631", with: "19041")).isWindows11)
    }

    func testReadsTheRealWindowsISOIfPresent() throws {
        // Point APEX_WINDOWS_ISO at a Windows 10 21H1 x64 ISO to run this.
        let iso = ProcessInfo.processInfo.environment["APEX_WINDOWS_ISO"] ?? ""
        try XCTSkipUnless(FileManager.default.fileExists(atPath: iso), "set APEX_WINDOWS_ISO")
        let img = BootMedia.inspect(URL(fileURLWithPath: iso))
        XCTAssertEqual(img.kind, .windows(splitNeeded: true))
        XCTAssertEqual(img.windows?.build, 19041)
        XCTAssertEqual(img.windows?.arch, .amd64)
        XCTAssertTrue(img.windows?.editions.contains { $0.name == "Windows 10 Pro" } ?? false)
        XCTAssertFalse(img.supportsHardwareBypass)       // Windows 10 has no such checks
    }

    func testNoOptionsWritesNoAnswerFile() {
        XCTAssertNil(Autounattend.xml(WindowsSetupOptions(), arch: .amd64))
    }

    func testAnswerFileContentsAndWellFormed() throws {
        var o = WindowsSetupOptions()
        o.skipTPM = true; o.skipSecureBoot = true; o.skipRAM = true
        o.allowOfflineAccount = true
        o.localAccount = "Alex <&>"
        o.locale = "en-ZA"; o.minimalPrivacy = true
        o.apps = ["Mozilla.Firefox", "bad;id&rm"]
        let xml = try XCTUnwrap(Autounattend.xml(o, arch: .arm64, imageLanguage: "en-US"))
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
        for key in ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassNRO", "<ProtectYourPC>3</ProtectYourPC>",
                    "<UserLocale>en-ZA</UserLocale>", "<UILanguage>en-US</UILanguage>", "processorArchitecture=\"arm64\"",
                    "Mozilla.Firefox", "/logonpasswordchg:yes"] {
            XCTAssertTrue(xml.contains(key), key)
        }
        XCTAssertFalse(xml.contains("amd64"))
        XCTAssertFalse(xml.contains("bad;id"))                     // only plain package IDs reach the command line
        XCTAssertTrue(xml.contains("<Name>Alex &amp;</Name>"))  // < > removed by the name rules, & escaped
    }

    func testOnlyChosenPassesAppear() throws {
        var o = WindowsSetupOptions(); o.minimalPrivacy = true
        let xml = try XCTUnwrap(Autounattend.xml(o, arch: .unknown))
        XCTAssertFalse(xml.contains("windowsPE"))
        XCTAssertFalse(xml.contains("specialize"))
        XCTAssertTrue(xml.contains("processorArchitecture=\"amd64\"") && xml.contains("processorArchitecture=\"arm64\""))
        XCTAssertEqual(Autounattend.cleanAccountName("  a/b\\c:d*e?f\"g<h>i|j@k  "), "abcdefghijk")
        XCTAssertEqual(Autounattend.cleanAccountName(String(repeating: "x", count: 30)).count, 20)
    }

    // MARK: Whole job on a temporary disk image (APEX_DISK_TESTS=1)

    func testCreatorWritesAnswerFileAndVerifies() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APEX_DISK_TESTS"] == "1", "set APEX_DISK_TESTS=1")
        let fm = FileManager.default
        let img = fm.temporaryDirectory.appendingPathComponent("apex-bmc-\(UUID().uuidString).sparseimage")
        XCTAssertEqual(Shell.run("/usr/bin/hdiutil", ["create", "-size", "9g", "-layout", "NONE", "-type", "SPARSE", "-fs", "ExFAT", img.path]).status, 0)
        let r = Shell.run("/usr/bin/hdiutil", ["attach", "-nomount", img.path])
        let disk = r.stdout.split(separator: "\n").first.map { String($0.split(separator: " ")[0]).replacingOccurrences(of: "/dev/", with: "") } ?? ""
        defer { _ = Shell.run("/usr/bin/hdiutil", ["detach", "/dev/" + disk, "-force"]); try? fm.removeItem(at: img) }
        XCTAssertTrue(disk.hasPrefix("disk"))

        let tree = fm.temporaryDirectory.appendingPathComponent("winiso-\(UUID().uuidString)")
        try fm.createDirectory(at: tree.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2_000_000).write(to: tree.appendingPathComponent("sources/install.wim"))
        try Data(count: 1000).write(to: tree.appendingPathComponent("bootmgr"))
        let iso = fm.temporaryDirectory.appendingPathComponent("win-\(UUID().uuidString).iso")
        defer { try? fm.removeItem(at: tree); try? fm.removeItem(at: iso) }
        XCTAssertEqual(Shell.run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-o", iso.path, tree.path]).status, 0)

        let image = BootMedia.inspect(iso)
        XCTAssertEqual(image.kind, .windows(splitNeeded: false))
        let target = StorageDevice(id: disk, name: "Test", model: "Test", connection: "USB", isInternal: false, ejectable: true,
                                   size: 9_663_676_416, volumes: [], registryID: 1)
        var job = BootMedia.Job(image: image, device: target)
        job.options.allowOfflineAccount = true
        job.fullVerify = true
        let lock = NSLock(); var steps: [String] = []
        let err = BootMedia.run(job, cancel: .init()) { _, s in lock.withLock { steps.append(s) } }
        XCTAssertNil(err)
        XCTAssertTrue(steps.contains("Verified byte for byte"), "\(steps.suffix(5))")

        _ = Shell.run("/usr/bin/hdiutil", ["detach", "/dev/" + disk, "-force"])
        let m = Shell.run("/usr/bin/hdiutil", ["attach", img.path]).stdout.split(separator: "\n")
            .compactMap { $0.split(separator: "\t").last.map(String.init) }.first { $0.hasPrefix("/Volumes/") }
        let mount = try XCTUnwrap(m)
        defer { _ = Shell.run("/usr/bin/hdiutil", ["detach", mount, "-force"]) }
        let answer = try String(contentsOfFile: mount + "/autounattend.xml", encoding: .utf8)
        XCTAssertTrue(answer.contains("BypassNRO"))
    }
}

final class SetupOptionsTests: XCTestCase {
    func testNameTimeZoneAndEncryptionGoInSpecialize() throws {
        var o = WindowsSetupOptions()
        o.computerName = "Office PC #1"
        o.timeZone = "South Africa Standard Time"
        o.noAutoEncryption = true
        let xml = try XCTUnwrap(Autounattend.xml(o, arch: .amd64))
        XCTAssertNoThrow(try XMLDocument(xmlString: xml), "well-formed")
        XCTAssertTrue(xml.contains("<settings pass=\"specialize\">"))
        XCTAssertTrue(xml.contains("<ComputerName>OfficePC1</ComputerName>"))
        XCTAssertTrue(xml.contains("<TimeZone>South Africa Standard Time</TimeZone>"))
        XCTAssertTrue(xml.contains("PreventDeviceEncryption"))
    }

    func testComputerNameRules() {
        XCTAssertEqual(Autounattend.cleanComputerName("my-very-long-computer-name"), "my-very-long-co", "15 characters at most")
        XCTAssertEqual(Autounattend.cleanComputerName("12345"), "", "all digits isn't allowed")
        XCTAssertEqual(Autounattend.cleanComputerName("Zoë's PC"), "ZosPC", "letters A–Z, digits and hyphens only")
    }

    func testTimeZoneFromMac() {
        XCTAssertEqual(Autounattend.windowsTimeZone(TimeZone(identifier: "Africa/Johannesburg")!), "South Africa Standard Time")
        XCTAssertEqual(Autounattend.windowsTimeZone(TimeZone(identifier: "Pacific/Fiji")!), "", "unknown: Windows asks")
    }

    func testDriversFolderNameIsTheOneSetupLooksFor() {
        XCTAssertEqual(BootMedia.driversFolder, "$WinPEDriver$")
    }
}
