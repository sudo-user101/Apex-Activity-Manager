import XCTest
@testable import TaskManager

final class DriveHealthTests: XCTestCase {
    func rec(connected: Double = 3600, transfers: [Double] = [], startup: Bool = false) -> DriveRecord {
        var r = DriveRecord(key: "k", name: "T7", model: "Samsung T7", connection: "USB", isStartup: startup,
                            firstSeen: Date(), lastSeen: Date())
        r.secondsConnected = connected
        r.transfers = transfers.map { TransferEpisode(date: Date(), seconds: 30, readMBps: $0, writeMBps: 0, megabytes: $0 * 30) }
        r.activeSeconds = Double(transfers.count) * 30
        return r
    }
    func smart(used: Int = 6, spare: Int = 100, threshold: Int = 99, media: UInt64 = 0, warning: Int = 0) -> SMARTHealth {
        SMARTHealth(criticalWarning: warning, temperatureC: 44, availableSpare: spare, spareThreshold: threshold, percentageUsed: used,
                    dataReadBytes: 0, dataWrittenBytes: 0, powerCycles: 0, powerOnHours: 0, unsafeShutdowns: 0, mediaErrors: media, errorLogEntries: 0)
    }

    func testLearnsBeforeJudging() {
        XCTAssertEqual(DriveHealthRules.assess(rec(connected: 120, transfers: [300])).status, .learning)
        XCTAssertEqual(DriveHealthRules.usage(rec(connected: 120)), .unknown)
        XCTAssertEqual(DriveHealthRules.assess(rec(transfers: [300, 310])).status, .good)
    }

    func testSlowingTransfersAreFlagged() {
        let r = rec(transfers: [400, 390, 410, 150, 140, 160])
        let a = DriveHealthRules.assess(r)
        XCTAssertEqual(a.status, .watch)
        XCTAssertTrue(a.reasons.first!.contains("half its best"))
        XCTAssertEqual(DriveHealthRules.assess(rec(transfers: [400, 390, 410, 150, 380, 160])).status, .good, "one fast recent transfer: not a trend")
    }

    func testSMARTDecidesForInternalDrives() {
        var r = rec(connected: 10, startup: true)
        r.smart = smart()
        XCTAssertEqual(DriveHealthRules.assess(r).status, .good, "the drive's own log is enough, no learning period")
        r.smart = smart(used: 75); XCTAssertEqual(DriveHealthRules.assess(r).status, .watch)
        r.smart = smart(used: 95); XCTAssertEqual(DriveHealthRules.assess(r).status, .poor)
        r.smart = smart(spare: 5, threshold: 10); XCTAssertEqual(DriveHealthRules.assess(r).status, .poor)
        r.smart = smart(warning: 1); XCTAssertEqual(DriveHealthRules.assess(r).status, .poor)
        r.smart = smart(media: 3); XCTAssertEqual(DriveHealthRules.assess(r).status, .watch)
        XCTAssertEqual(DriveHealthRules.usage(r), .startup)
    }

    func testErrorsAndResponseTime() {
        var r = rec(transfers: [300, 300])
        r.reportsErrors = true; r.errors = 2
        XCTAssertEqual(DriveHealthRules.assess(r).status, .watch)
        r.errors = 0; r.latencyMs = 9; r.latencyBaselineMs = 0.5; r.activeSeconds = 900
        XCTAssertEqual(DriveHealthRules.assess(r).status, .watch)
        XCTAssertNil(DriveHealthRules.plausibleLatency(435))
        XCTAssertEqual(DriveHealthRules.plausibleLatency(0.17), 0.17)
    }

    func testUsageKinds() {
        var r = rec(transfers: [200, 210])
        XCTAssertEqual(DriveHealthRules.usage(r), .transfers)
        r.appSeconds = 900; r.appNames = ["Logic Pro"]
        XCTAssertEqual(DriveHealthRules.usage(r), .apps(["Logic Pro"]))
        r.isTimeMachine = true
        XCTAssertEqual(DriveHealthRules.usage(r), .backups)
        XCTAssertEqual(DriveHealthRules.usage(rec()), .storage)
    }

    func testParsesNVMeLogPage() {
        var d = [UInt8](repeating: 0, count: 512)
        d[0] = 0; d[1] = 61; d[2] = 1          // 317 K = 44 °C
        d[3] = 100; d[4] = 99; d[5] = 6
        let units: UInt64 = 188_751_653
        for i in 0..<8 { d[48 + i] = UInt8((units >> (8 * UInt64(i))) & 0xFF) }   // units written, little-endian
        d[128] = 0x97; d[129] = 0x06                             // 1687 hours
        d[144] = 30
        let h = SMARTHealth.parse(d)!
        XCTAssertEqual(h.temperatureC, 44)
        XCTAssertEqual(h.percentageUsed, 6)
        XCTAssertEqual(h.availableSpare, 100)
        XCTAssertEqual(h.powerOnHours, 1687)
        XCTAssertEqual(h.unsafeShutdowns, 30)
        XCTAssertEqual(h.dataWrittenBytes, 188_751_653 * 512_000)
        XCTAssertNil(SMARTHealth.parse([0, 1, 2]))
    }

    func testUSBLinkNames() {
        let l = USBLink(speed: 3, bcdUSB: 0x0320)
        XCTAssertEqual(l.connectedAs, "USB 3.2 Gen 1 (5 Gb/s)")
        XCTAssertEqual(l.supports, "USB 3.2")
        XCTAssertFalse(l.slowerThanItCould)
        let slow = USBLink(speed: 2, bcdUSB: 0x0310)
        XCTAssertTrue(slow.slowerThanItCould, "a USB 3 drive on a USB 2 port")
        XCTAssertEqual(slow.connectedAs, "USB 2.0 (480 Mb/s)")
        XCTAssertEqual(USBLink(speed: 2, bcdUSB: 0x0200).supports, "USB 2.0")
    }
}
