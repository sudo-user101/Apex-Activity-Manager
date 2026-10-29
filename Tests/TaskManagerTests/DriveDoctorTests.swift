import XCTest
@testable import TaskManager

final class DriveDoctorTests: XCTestCase {
    func smart(used: Int = 5, spare: Int = 100, media: UInt64 = 0, critical: Int = 0, temp: Int = 40) -> SMARTHealth {
        SMARTHealth(criticalWarning: critical, temperatureC: temp, availableSpare: spare, spareThreshold: 10,
                    percentageUsed: used, dataReadBytes: 0, dataWrittenBytes: 0, powerCycles: 0, powerOnHours: 0,
                    unsafeShutdowns: 0, mediaErrors: media, errorLogEntries: 0)
    }

    func rec(startup: Bool = true, days: Double = 0) -> DriveRecord {
        var r = DriveRecord(key: "k", name: "Macintosh HD", model: "", connection: "Internal", isStartup: startup,
                            firstSeen: Date().addingTimeInterval(-days * 86400), lastSeen: Date())
        r.secondsConnected = 7200
        return r
    }

    func testHealthyDriveSaysSo() {
        var r = rec(); r.smart = smart(); r.smartFirst = smart()
        let rep = DriveDoctor.diagnose(.init(record: r))
        XCTAssertEqual(rep.findings.map(\.id), ["healthy"])
        XCTAssertEqual(rep.worst, .ok)
    }

    func testCriticalSignsComeFirstAndAreConfirmed() {
        var r = rec(); r.smart = smart(used: 95, spare: 5, media: 3, critical: 1)
        let rep = DriveDoctor.diagnose(.init(record: r))
        XCTAssertEqual(rep.findings.first?.severity, .critical)
        XCTAssertTrue(rep.findings.contains { $0.id == "smart.spare" && $0.confidence == .confirmed })
        XCTAssertTrue(rep.findings.contains { $0.id == "smart.media" })
        XCTAssertTrue(rep.findings.contains { $0.id == "smart.wear" && $0.severity == .warning })
    }

    func testExternalErrorsPointAtTheConnectionFirst() {
        var r = rec(startup: false); r.reportsErrors = true; r.errors = 4
        let rep = DriveDoctor.diagnose(.init(record: r))
        let f = rep.findings.first { $0.id == "io.errors" }
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.causes.first!.contains("cable"))
        XCTAssertTrue(rep.missing.contains { $0.contains("health log") })
    }

    func testUSB2PortAndLowSpace() {
        let rep = DriveDoctor.diagnose(.init(record: rec(startup: false), usb: USBLink(speed: 2, bcdUSB: 0x0320),
                                             capacity: 100, available: 2))
        XCTAssertTrue(rep.findings.contains { $0.id == "usb.slow" })
        XCTAssertTrue(rep.findings.contains { $0.id == "space.low" && $0.severity == .warning })
    }

    func testFailedFirstAidIsAFinding() {
        let rep = DriveDoctor.diagnose(.init(record: rec(), firstAid: [.init(volume: "Data", ok: false, summary: "bad")]))
        XCTAssertTrue(rep.findings.contains { $0.id == "firstaid.Data" })
    }

    func testNoLifespanWithoutWearData() {
        if case .unknown = DriveDoctor.lifespan(rec(startup: false)) {} else { XCTFail("USB drive must not get an estimate") }
        var r = rec(days: 10); r.smart = smart(used: 10); r.smartFirst = smart(used: 8)
        if case .qualitative = DriveDoctor.lifespan(r) {} else { XCTFail("under 30 days must not estimate") }
    }

    func testLifespanEstimateIsARange() {
        // 2 points in 100 days, 90 left: 1–3 points per 100 days => 3000–9000 days.
        var r = rec(days: 100); r.smart = smart(used: 10); r.smartFirst = smart(used: 8)
        guard case .estimate(let lo, let hi, _) = DriveDoctor.lifespan(r) else { return XCTFail() }
        XCTAssertEqual(lo, 3000.0 / 365, accuracy: 0.1)
        XCTAssertEqual(hi!, 9000.0 / 365, accuracy: 0.1)
        // 1 point: the slow bound is unbounded ("or more").
        r.smartFirst = smart(used: 9)
        guard case .estimate(_, let hi2, _) = DriveDoctor.lifespan(r) else { return XCTFail() }
        XCTAssertNil(hi2)
    }
}

final class LocalAddressTests: XCTestCase {
    func testScopes() {
        XCTAssertEqual(LocalAddress.scope(of: "192.168.1.4"), .privateLAN)
        XCTAssertEqual(LocalAddress.scope(of: "172.20.0.1"), .privateLAN)
        XCTAssertEqual(LocalAddress.scope(of: "172.32.0.1"), .publicIP)
        XCTAssertEqual(LocalAddress.scope(of: "10.0.0.20"), .privateLAN)
        XCTAssertEqual(LocalAddress.scope(of: "169.254.3.3"), .linkLocal)
        XCTAssertEqual(LocalAddress.scope(of: "100.100.1.1"), .carrierNAT)
        XCTAssertEqual(LocalAddress.scope(of: "8.8.8.8"), .publicIP)
    }

    func testPrimaryFirstVPNLast() {
        let a = [LocalAddress(interface: "utun3", kind: "VPN", address: "10.8.0.2", isPrimary: false),
                 LocalAddress(interface: "en7", kind: "Ethernet", address: "192.168.1.9", isPrimary: false),
                 LocalAddress(interface: "en0", kind: "Wi-Fi", address: "192.168.1.5", isPrimary: true)]
        XCTAssertEqual(LocalAddresses.sort(a).map(\.interface), ["en0", "en7", "utun3"])
        XCTAssertEqual(LocalAddresses.kind("utun4", nil), "VPN")
    }
}

final class DriveCleanerTests: XCTestCase {
    func testFindsTrashAndHelperFilesOnly() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("apex-dc-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/.Trashes/\(getuid())", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/Photos", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.Spotlight-V100", withIntermediateDirectories: true)
        for f in ["/.Trashes/\(getuid())/old.mov", "/Photos/a.jpg", "/Photos/~_a.jpg", "/~_Photos", "/.Spotlight-V100/~_x"] {
            fm.createFile(atPath: root + f, contents: Data(repeating: 1, count: 100))
        }
        XCTAssertTrue(DriveCleaner.isHelperFile("._a.jpg")); XCTAssertFalse(DriveCleaner.isHelperFile("._"))
        let s = DriveCleaner.scan(volume: root, format: "ExFAT", isHelper: { $0.hasPrefix("~_") })
        XCTAssertEqual(s.trash.map { ($0.path as NSString).lastPathComponent }, ["old.mov"])
        XCTAssertEqual(Set(s.helpers.map { ($0.path as NSString).lastPathComponent }), ["~_a.jpg", "~_Photos"])
        XCTAssertFalse(DriveCleaner.scan(volume: root, format: "APFS").helpersApply)
        _ = DriveCleaner.remove(s.helpers)
        XCTAssertTrue(fm.fileExists(atPath: root + "/Photos/a.jpg"))
        XCTAssertFalse(fm.fileExists(atPath: root + "/Photos/~_a.jpg"))
    }
}

final class AccessoriesTests: XCTestCase {
    func testParsesNestedUSBDevices() {
        let json = """
        {"SPUSBDataType":[{"_name":"USB31Bus","_items":[
          {"_name":" SanDisk 3.2Gen1","bus_power":"900","bus_power_used":"896","extra_current_used":"0",
           "device_speed":"super_speed","location_id":"0x00200000 / 1","vendor_id":"0x0781  (SanDisk Corporation)",
           "_items":[{"_name":"Keyboard","bus_power":500,"bus_power_used":100,"device_speed":"full_speed","location_id":"0x00210000 / 2","manufacturer":"Acme"}]}
        ]},{"_name":"USB31Bus"}]}
        """
        let top = Accessories.parse(Data(json.utf8))
        XCTAssertEqual(top.map(\.name), ["SanDisk 3.2Gen1"])          // the keyboard sits behind it
        XCTAssertTrue(top[0].isHub)
        let a = top.flatMap(\.flattened)
        XCTAssertEqual(a.map(\.name), ["SanDisk 3.2Gen1", "Keyboard"])
        XCTAssertEqual(a[0].vendor, "SanDisk Corporation")
        XCTAssertEqual(a[0].maxWatts, 4.48, accuracy: 0.001)
        XCTAssertEqual(top[0].totalWatts, 4.98, accuracy: 0.001)
        XCTAssertEqual(a[1].vendor, "Acme")
        XCTAssertEqual(a[1].speed, "USB 1.1")
    }
}

final class TransferTests: XCTestCase {
    func testTransfersBelongToTheirDrive() {
        XCTAssertTrue(TransferMonitor.belongs("/Volumes/USB/a.bin", to: ["/Volumes/USB"]))
        XCTAssertFalse(TransferMonitor.belongs("/Volumes/USB2/a.bin", to: ["/Volumes/USB"]))
        XCTAssertTrue(TransferMonitor.belongs("/Users/me/Downloads/a.zip", to: ["/"]))
        XCTAssertFalse(TransferMonitor.belongs("/Volumes/USB/a.bin", to: ["/"]))
    }
}

final class DriveManualTests: XCTestCase {
    func testParsers() {
        let ok = "Started partition map verification on disk0\nChecking prerequisites\nThe partition map appears to be OK\nFinished partition map verification on disk0\n"
        XCTAssertEqual(DriveManual.parseVerify(ok, status: 0).ok, true)
        let bad = DriveManual.parseVerify("Checking volume\nerror: invalid node structure\nThe volume could not be verified completely\n", status: 1)
        XCTAssertFalse(bad.ok)
        XCTAssertTrue(bad.summary.contains("error") || bad.summary.contains("could not"), bad.summary)
        let snaps = DriveManual.parseSnapshots("Snapshots for disk /:\ncom.apple.TimeMachine.2026-09-27-135829.local\ncom.apple.os.update-ABC\n")
        XCTAssertEqual(snaps.count, 2)
        XCTAssertEqual(DriveManual.snapshotDate(snaps[0]), "2026-09-27-135829")
        XCTAssertNil(DriveManual.snapshotDate("com.apple.os.update-ABC"))
        let lines = ["kernel: (apfs) apfs_pagein:15330: disk3s1 ino 1 error 22 (mds_stores)",
                     "kernel: disk3s1: I/O error",
                     "kernel: disk5s1: read error on block 12",
                     "kernel: unrelated error in wifi"]
        XCTAssertEqual(DriveManual.relevantErrors(lines, disks: ["disk3s1", "disk3"]), ["kernel: disk3s1: I/O error"])
        XCTAssertEqual(DriveManual.speed(1e9, 0.5), "2.00 GB/s")
        XCTAssertEqual(DriveManual.speed(2e8, 1), "200 MB/s")
        XCTAssertEqual(DriveManual.parseScanProgress("done 64\nbad 64\ndone 128\n").doneMB, 128)
        XCTAssertEqual(DriveManual.parseScanProgress("done 64\nbad 64\ndone 128\n").badMB, [64])
        let script = DriveManual.scanScript(disk: "disk4", totalMB: 128, progress: "/tmp/p", stop: "/tmp/s")
        XCTAssertTrue(script.contains("if=/dev/rdisk4 of=/dev/null"), "read-only: it only ever writes to /dev/null")
        XCTAssertFalse(script.contains("of=/dev/rdisk"))
    }

    /// The read-only checks on this Mac's startup volume, for real.
    func testReadOnlyChecksOnThisMac() async throws {
        let disks = try XCTUnwrap(DriveManual.disks(of: "/"))
        XCTAssertTrue(disks.physical.hasPrefix("disk"))
        let map = await DriveManual.run(.partitionMap, volumes: [("Macintosh HD", "/")], record: nil)
        XCTAssertTrue(map.ok, map.summary)
        let snaps = await DriveManual.run(.snapshots, volumes: [("Macintosh HD", "/")], record: nil)
        XCTAssertTrue(snaps.ok)
        let w = DriveManual.writeTest(volume: "/", size: 64 << 20)
        XCTAssertTrue(w.ok, w.summary)
        XCTAssertTrue(w.summary.contains("Write") && w.summary.contains("read"))
    }
}
