import CryptoKit
import XCTest
import FanControlCore
@testable import TaskManager

final class FanControlTests: XCTestCase {
    let temps = FanControl.Temps(cpu: 60, gpu: 45, hottest: 70)

    func testAutoMeansHandsOff() {
        XCTAssertNil(FanControl.target(.init(index: 0, mode: .auto), minRPM: 1200, maxRPM: 6000, temps: temps))
    }

    func testFixedIsClampedToFanRange() {
        XCTAssertEqual(FanControl.target(.init(index: 0, mode: .fixed, rpm: 9000), minRPM: 1200, maxRPM: 6000, temps: temps), 6000)
        XCTAssertEqual(FanControl.target(.init(index: 0, mode: .fixed, rpm: 100), minRPM: 1200, maxRPM: 6000, temps: temps), 1200)
    }

    func testCurveRampsLinearly() {
        let s = FanControl.FanSetting(index: 0, mode: .curve, sensor: .cpu, startTemp: 50, fullTemp: 70)
        // 60 °C is halfway between 50 and 70 → halfway between min and max.
        XCTAssertEqual(FanControl.target(s, minRPM: 2000, maxRPM: 6000, temps: temps), 4000)
        XCTAssertEqual(FanControl.target(s, minRPM: 2000, maxRPM: 6000, temps: .init(cpu: 30, gpu: nil, hottest: 30)), 2000)
        XCTAssertEqual(FanControl.target(s, minRPM: 2000, maxRPM: 6000, temps: .init(cpu: 99, gpu: nil, hottest: 99)), 6000)
    }

    func testUnknownTemperatureFallsBackToAutomatic() {
        let s = FanControl.FanSetting(index: 0, mode: .curve, sensor: .gpu)
        XCTAssertNil(FanControl.target(s, minRPM: 2000, maxRPM: 6000, temps: .init(cpu: nil, gpu: nil, hottest: nil)))
        XCTAssertNil(FanControl.target(.init(index: 0, mode: .max), minRPM: 0, maxRPM: 0, temps: temps), "no fan info → hands off")
    }

    func testStaleHeartbeatIsIgnored() {
        let now = Date()
        XCTAssertTrue(FanControl.isFresh(.init(heartbeat: now.addingTimeInterval(-30)), now: now))
        XCTAssertFalse(FanControl.isFresh(.init(heartbeat: now.addingTimeInterval(-600)), now: now))
    }

    func testSanitizeRejectsBadValues() {
        var bad = FanControl.FanSetting(index: 99, mode: .fixed)
        let ok = FanControl.FanSetting(index: 1, mode: .curve, rpm: .nan, startTemp: 500, fullTemp: -4)
        bad.rpm = .infinity
        let c = FanControl.sanitized(.init(fans: [bad, ok]))
        XCTAssertEqual(c.fans.count, 1, "out-of-range fan index dropped")
        XCTAssertEqual(c.fans[0].rpm, 0)
        XCTAssertEqual(c.fans[0].startTemp, 105)
        XCTAssertGreaterThan(c.fans[0].fullTemp, c.fans[0].startTemp)
    }

    func testConfigRoundTrip() {
        let c = FanControl.Config(heartbeat: Date(timeIntervalSince1970: 1_700_000_000),
                                  fans: [.init(index: 0, mode: .curve, sensor: .hottest, startTemp: 45, fullTemp: 80)])
        XCTAssertEqual(FanControl.decode(FanControl.encode(c)!), c)
        XCTAssertNil(FanControl.decode(Data("not json".utf8)))
    }
}

final class ChargeLimitTests: XCTestCase {
    func testOverrideEndsWhenFullOrExpired() {
        let now = Date()
        let until = now.addingTimeInterval(3600)
        XCTAssertEqual(FanControl.overrideActive(until: until, consumed: nil, now: now), until)
        XCTAssertNil(FanControl.overrideActive(until: until, consumed: until, now: now), "already reached 100%")
        XCTAssertNil(FanControl.overrideActive(until: now.addingTimeInterval(-1), consumed: nil, now: now), "expired")
        XCTAssertNil(FanControl.overrideActive(until: nil, consumed: nil, now: now))
        // A new override after a used one works again.
        let later = now.addingTimeInterval(7200)
        XCTAssertEqual(FanControl.overrideActive(until: later, consumed: until, now: now), later)
    }

    func testLimitEndToEnd() {
        // 80% limit: charges to 80, holds, resumes at 77, override lets it reach 100.
        var blocked = false
        for (p, expect) in [(70, false), (79, false), (80, true), (79, true), (78, true), (77, false), (78, false), (80, true)] {
            blocked = FanControl.shouldBlockCharging(percent: p, limit: 80, overrideUntil: nil, currentlyBlocked: blocked)
            XCTAssertEqual(blocked, expect, "at \(p)%")
        }
        XCTAssertFalse(FanControl.shouldBlockCharging(percent: 90, limit: 80, overrideUntil: Date().addingTimeInterval(60), currentlyBlocked: true))
        XCTAssertFalse(FanControl.shouldBlockCharging(percent: 100, limit: 100, overrideUntil: nil, currentlyBlocked: false), "100% means no limit")
        XCTAssertFalse(FanControl.shouldBlockCharging(percent: nil, limit: 80, overrideUntil: nil, currentlyBlocked: true), "unknown level never blocks")
    }

    func testBlocksAtLimitWithHysteresis() {
        XCTAssertFalse(FanControl.shouldBlockCharging(percent: 70, limit: 80, overrideUntil: nil, currentlyBlocked: false))
        XCTAssertTrue(FanControl.shouldBlockCharging(percent: 80, limit: 80, overrideUntil: nil, currentlyBlocked: false))
        // Once blocked, stay blocked until 3 % below the limit.
        XCTAssertTrue(FanControl.shouldBlockCharging(percent: 78, limit: 80, overrideUntil: nil, currentlyBlocked: true))
        XCTAssertFalse(FanControl.shouldBlockCharging(percent: 77, limit: 80, overrideUntil: nil, currentlyBlocked: true))
    }

    func testSafeDefaults() {
        XCTAssertFalse(FanControl.shouldBlockCharging(percent: nil, limit: 80, overrideUntil: nil, currentlyBlocked: true), "unknown level → charge")
        XCTAssertFalse(FanControl.shouldBlockCharging(percent: 95, limit: nil, overrideUntil: nil, currentlyBlocked: true), "off → charge")
        XCTAssertFalse(FanControl.shouldBlockCharging(percent: 95, limit: 100, overrideUntil: nil, currentlyBlocked: false))
        XCTAssertFalse(FanControl.shouldBlockCharging(percent: 95, limit: 10, overrideUntil: nil, currentlyBlocked: false), "out of range → ignored")
    }

    func testOverrideChargesToFull() {
        let now = Date()
        XCTAssertFalse(FanControl.shouldBlockCharging(percent: 90, limit: 80, overrideUntil: now.addingTimeInterval(3600), currentlyBlocked: true, now: now))
        XCTAssertTrue(FanControl.shouldBlockCharging(percent: 90, limit: 80, overrideUntil: now.addingTimeInterval(-1), currentlyBlocked: true, now: now))
    }

    func testOldConfigStillDecodes() {
        let json = #"{"heartbeat": 1700000000, "fans": []}"#
        let c = FanControl.decode(Data(json.utf8))
        XCTAssertNotNil(c)
        XCTAssertNil(c?.chargeLimit)
    }
}

final class ChargeScheduleTests: XCTestCase {
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    /// 2026-10-26 is a Monday (weekday 2).
    func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    func testWindowWithinADay() {
        let s = FanControl.ChargeSchedule(days: [2], start: 6 * 60, end: 8 * 60, action: .fullCharge)
        XCTAssertFalse(s.isActive(at: at(26, 5, 59), calendar: cal))
        XCTAssertTrue(s.isActive(at: at(26, 6), calendar: cal))
        XCTAssertFalse(s.isActive(at: at(26, 8), calendar: cal))
        XCTAssertFalse(s.isActive(at: at(27, 7), calendar: cal))        // Tuesday
    }

    func testWindowPastMidnightBelongsToItsStartDay() {
        let s = FanControl.ChargeSchedule(days: [2], start: 22 * 60, end: 6 * 60, action: .limit(60))
        XCTAssertTrue(s.isActive(at: at(26, 23), calendar: cal))         // Monday night
        XCTAssertTrue(s.isActive(at: at(27, 5), calendar: cal))          // Tuesday early
        XCTAssertFalse(s.isActive(at: at(26, 5), calendar: cal))         // Monday early: Sunday not chosen
        XCTAssertFalse(s.isActive(at: at(27, 23), calendar: cal))
    }

    func testPrecedence() {
        let full = FanControl.ChargeSchedule(days: [2], start: 0, end: 12 * 60, action: .fullCharge)
        let low = FanControl.ChargeSchedule(days: [2], start: 0, end: 12 * 60, action: .limit(60))
        let lower = FanControl.ChargeSchedule(days: [2], start: 0, end: 12 * 60, action: .limit(55))
        var c = FanControl.Config(chargeLimit: 80, chargeSchedules: [low, lower])
        XCTAssertEqual(FanControl.effectiveLimit(c, overrideActive: false, now: at(26, 9), calendar: cal).limit, 55)
        XCTAssertEqual(FanControl.effectiveLimit(c, overrideActive: false, now: at(26, 13), calendar: cal).limit, 80)
        c.chargeSchedules?.append(full)
        XCTAssertNil(FanControl.effectiveLimit(c, overrideActive: false, now: at(26, 9), calendar: cal).limit)
        XCTAssertEqual(FanControl.effectiveLimit(c, overrideActive: true, now: at(26, 9), calendar: cal).source, .override)
        var off = low; off.enabled = false
        XCTAssertEqual(FanControl.effectiveLimit(FanControl.Config(chargeLimit: nil, chargeSchedules: [off]), overrideActive: false,
                                                 now: at(26, 9), calendar: cal).limit, nil)
    }

    func testOldConfigFilesStillDecode() {
        let json = #"{"heartbeat":0,"fans":[],"chargeLimit":80}"#
        let c = FanControl.decode(Data(json.utf8))
        XCTAssertEqual(c?.chargeLimit, 80)
        XCTAssertNil(c?.chargeSchedules)
        let round = FanControl.decode(FanControl.encode(FanControl.Config(chargeSchedules: [.init(days: [1], start: 1, end: 2, action: .limit(70))]))!)
        XCTAssertEqual(round?.chargeSchedules?.first?.action, .limit(70))
    }
}

final class NightChargingTests: XCTestCase {
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))! }
    let night = FanControl.NightCharging(start: 20 * 60, fullBy: 7 * 60, holdAt: 80)   // top-up = 40 + 15 min before 7:00 → 6:05

    func testPhasesThroughTheNight() {
        XCTAssertEqual(FanControl.nightPlan(night, now: at(26, 19), calendar: cal).phase, .off)
        XCTAssertEqual(FanControl.nightPlan(night, now: at(26, 22), calendar: cal).phase, .hold(until: at(27, 6, 5)))
        XCTAssertEqual(FanControl.nightPlan(night, now: at(27, 3), calendar: cal).phase, .hold(until: at(27, 6, 5)))
        XCTAssertEqual(FanControl.nightPlan(night, now: at(27, 6, 30), calendar: cal).phase, .topUp(fullBy: at(27, 7)))
        XCTAssertEqual(FanControl.nightPlan(night, now: at(27, 9), calendar: cal).phase, .keepFull)
        XCTAssertEqual(FanControl.nightPlan(night, now: at(27, 12, 1), calendar: cal).phase, .off)     // noon cut-off
        var opened = night; opened.openedAt = at(27, 8)
        XCTAssertEqual(FanControl.nightPlan(opened, now: at(27, 9), calendar: cal).phase, .off)       // opened after full-by
        opened.openedAt = at(26, 23)                                                                  // opened in the night: still held
        XCTAssertEqual(FanControl.nightPlan(opened, now: at(27, 9), calendar: cal).phase, .keepFull)
    }

    func testLimitAndPrecedence() {
        let c = FanControl.Config(chargeLimit: 90, nightCharging: night)
        XCTAssertEqual(FanControl.effectiveLimit(c, overrideActive: false, now: at(26, 23), calendar: cal).limit, 80)
        XCTAssertNil(FanControl.effectiveLimit(c, overrideActive: false, now: at(27, 6, 30), calendar: cal).limit)
        XCTAssertEqual(FanControl.effectiveLimit(c, overrideActive: false, now: at(27, 15), calendar: cal).limit, 90)
        XCTAssertEqual(FanControl.effectiveLimit(c, overrideActive: true, now: at(26, 23), calendar: cal).source, .override)
        var off = night; off.enabled = false
        XCTAssertEqual(FanControl.effectiveLimit(FanControl.Config(chargeLimit: 90, nightCharging: off), overrideActive: false,
                                                 now: at(26, 23), calendar: cal).limit, 90)
    }

    func testWakeChecks() {
        XCTAssertEqual(FanControl.nextNightCheck(night, now: at(26, 22), calendar: cal), at(26, 22, 30))
        XCTAssertEqual(FanControl.nextNightCheck(night, now: at(27, 5, 50), calendar: cal), at(27, 6, 5))   // exactly at top-up
        XCTAssertEqual(FanControl.nextNightCheck(night, now: at(27, 15), calendar: cal), at(27, 20))        // tonight's start
        XCTAssertNil(FanControl.nextNightCheck(nil, now: at(27, 15), calendar: cal))
    }
}

final class StayAwakeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testHelperOnlyHonoursFreshRenewals() {
        XCTAssertFalse(FanControl.sleepDisabled(until: nil, now: now))
        XCTAssertTrue(FanControl.sleepDisabled(until: now.addingTimeInterval(180), now: now))
        XCTAssertFalse(FanControl.sleepDisabled(until: now.addingTimeInterval(-1), now: now), "lapsed: Apex stopped renewing")
        XCTAssertFalse(FanControl.sleepDisabled(until: now.addingTimeInterval(86400), now: now), "a far-future time is ignored")
    }

    @MainActor func testLidClosedRules() {
        func d(_ enabled: Bool = true, app: Bool = true, ac: Bool, battery: Bool = false, since: Double? = nil, max: Int = 60) -> Bool {
            LidAwake.decide(enabled: enabled, appRunning: app, onAC: ac, allowOnBattery: battery,
                            onBatterySince: since.map { now.addingTimeInterval(-$0) }, batteryMinutes: max, now: now)
        }
        XCTAssertTrue(d(ac: true), "on power with a chosen app open")
        XCTAssertFalse(d(app: false, ac: true), "no chosen app open")
        XCTAssertFalse(d(false, ac: true), "switched off")
        XCTAssertFalse(d(ac: false, since: 60), "battery not allowed")
        XCTAssertTrue(d(ac: false, battery: true, since: 600, max: 30))
        XCTAssertFalse(d(ac: false, battery: true, since: 1900, max: 30), "allowance used up")
        XCTAssertFalse(d(ac: false, battery: true, since: 3700, max: 600), "never more than an hour")
    }

    func testOldConfigWithoutStayAwakeDecodes() {
        let json = #"{"heartbeat": 1800000000, "fans": [], "chargeLimit": 80}"#
        XCTAssertNil(FanControl.decode(Data(json.utf8))?.stayAwakeUntil)
        XCTAssertEqual(FanControl.decode(Data(json.utf8))?.chargeLimit, 80)
    }
}

/// Issue #18: at the limit the power adapter powers the Mac; what happens at shutdown and while off.
final class AdapterPowerTests: XCTestCase {
    func testOnlyPauseStopsChargingUnlessRunningOnBatteryIsAllowed() {
        XCTAssertTrue(FanControl.mayBlock(method: "pause", holdOnBattery: nil))
        XCTAssertTrue(FanControl.mayBlock(method: "pause", holdOnBattery: false))
        XCTAssertFalse(FanControl.mayBlock(method: "hold", holdOnBattery: nil), "hold disconnects the adapter: never by default")
        XCTAssertFalse(FanControl.mayBlock(method: "hold", holdOnBattery: false))
        XCTAssertTrue(FanControl.mayBlock(method: "hold", holdOnBattery: true))
        XCTAssertFalse(FanControl.mayBlock(method: nil, holdOnBattery: true))
    }

    func testBatteryPoweringWhilePluggedIn() {
        XCTAssertTrue(FanControl.drainingOnAdapter(externalConnected: true, amperageMA: -900))
        XCTAssertFalse(FanControl.drainingOnAdapter(externalConnected: true, amperageMA: -40), "a few mA at rest is normal")
        XCTAssertFalse(FanControl.drainingOnAdapter(externalConnected: true, amperageMA: 1200), "charging")
        XCTAssertFalse(FanControl.drainingOnAdapter(externalConnected: false, amperageMA: -900), "unplugged: of course it's the battery")
        XCTAssertFalse(FanControl.drainingOnAdapter(externalConnected: nil, amperageMA: nil))
    }

    func testAdapterIsReconnectedWhilePaused() {
        XCTAssertTrue(FanControl.shouldReconnectAdapter(method: "pause", chie: [0x08]))
        XCTAssertFalse(FanControl.shouldReconnectAdapter(method: "pause", chie: [0x00]))
        XCTAssertFalse(FanControl.shouldReconnectAdapter(method: "pause", chie: nil), "no CHIE key on this Mac")
        XCTAssertFalse(FanControl.shouldReconnectAdapter(method: "hold", chie: [0x08]), "hold mode uses CHIE on purpose")
    }

    func testShutdownLeavesAPausedChargePausedOnlyWhenSafe() {
        XCTAssertTrue(FanControl.keepPausedOnExit(method: "pause", configPresent: true, blocked: true, limit: 80))
        XCTAssertFalse(FanControl.keepPausedOnExit(method: "pause", configPresent: false, blocked: true, limit: 80), "helper being removed")
        XCTAssertFalse(FanControl.keepPausedOnExit(method: "pause", configPresent: true, blocked: false, limit: 80))
        XCTAssertFalse(FanControl.keepPausedOnExit(method: "pause", configPresent: true, blocked: true, limit: nil))
        XCTAssertFalse(FanControl.keepPausedOnExit(method: "hold", configPresent: true, blocked: true, limit: 80), "never leave the adapter disconnected")
    }

    func testWhatHappenedWhileOff() {
        let r = FanControl.OffRecord(percent: 80, at: Date(), limit: 80, paused: true)
        let charged = FanControl.whileOffNote(r, nowPercent: 100)
        XCTAssertTrue(charged?.hasPrefix("While this Mac was off it charged from 80% to 100%, past your 80% limit.") == true)
        XCTAssertEqual(FanControl.whileOffNote(r, nowPercent: 80), "Stayed at 80% while this Mac was off.")
        XCTAssertEqual(FanControl.whileOffNote(r, nowPercent: 79), "Stayed at 79% while this Mac was off.")
        XCTAssertNil(FanControl.whileOffNote(FanControl.OffRecord(percent: 60, at: Date(), limit: 80, paused: false), nowPercent: 75),
                     "charging up to the limit is fine")
        XCTAssertNil(FanControl.whileOffNote(FanControl.OffRecord(percent: 80, at: Date(), limit: nil, paused: false), nowPercent: 100), "no limit")
        XCTAssertNil(FanControl.whileOffNote(nil, nowPercent: 100))
    }

    func testSettingRoundTripsAndOldFilesStillDecode() throws {
        let c = FanControl.Config(chargeLimit: 80, holdOnBattery: true)
        XCTAssertEqual(FanControl.decode(FanControl.encode(c)!)?.holdOnBattery, true)
        XCTAssertNil(FanControl.decode(FanControl.encode(FanControl.Config(chargeLimit: 80))!)?.holdOnBattery)
        // A status file from an older helper (none of the new fields).
        let old = #"{"updated": 1700000000, "fanTargets": {}, "chargeMethod": "pause", "chargingBlocked": true, "batteryPercent": 80}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let s = try dec.decode(FanControl.Status.self, from: Data(old.utf8))
        XCTAssertNil(s.onAdapter)
        XCTAssertNil(s.limitNotHeld)
        XCTAssertNil(s.whileOff)
    }
}

/// The helper is updated (with the password) only when `FanControl.helperVersion` goes up.
final class HelperVersionTests: XCTestCase {
    /// SHA-256 of the helper's code (Sources/ApexFanHelper + Sources/FanControlCore, files
    /// in path order) for each helper version. Changed the helper's code? If it behaves
    /// differently, raise `FanControl.helperVersion` and add a line to `helperNews`; either
    /// way, put the new hash here (the failure message prints it).
    static let recorded: [Int: String] = [
        2: "359cf8865cbaf8419082619b20a84862b7965759227edcf1f7549294e79f3de3",
    ]

    func testHelperCodeChangesComeWithAVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var paths: [String] = []
        for dir in ["Sources/ApexFanHelper", "Sources/FanControlCore"] {
            let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)
            paths += names.filter { $0.hasSuffix(".swift") }.map { dir + "/" + $0 }
        }
        var data = Data()
        for p in paths.sorted() { data += try Data(contentsOf: root.appendingPathComponent(p)) }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(Self.recorded[FanControl.helperVersion], hash,
                       "The helper's code changed. If it behaves differently, raise FanControl.helperVersion (and add to helperNews); then record this hash for that version: \(hash)")
    }

    func testOnlyAnOlderRunningHelperNeedsUpdating() {
        XCTAssertTrue(FanControl.helperNeedsUpdate(running: nil, statusKnown: true), "a helper from before versions")
        XCTAssertTrue(FanControl.helperNeedsUpdate(running: FanControl.helperVersion - 1, statusKnown: true))
        XCTAssertFalse(FanControl.helperNeedsUpdate(running: FanControl.helperVersion, statusKnown: true), "a new build of Apex alone never asks")
        XCTAssertFalse(FanControl.helperNeedsUpdate(running: nil, statusKnown: false), "not running yet: can't tell, don't nag")
        XCTAssertEqual(FanControl.helperNewsSince(FanControl.helperVersion), [])
        XCTAssertEqual(FanControl.helperNewsSince(nil).count, FanControl.helperVersion - 1, "news for every version")
    }
}
