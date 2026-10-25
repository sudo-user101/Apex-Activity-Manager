import XCTest
@testable import DetectionCore

final class DetectionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func app(_ cpu: Double, key: String = "/Applications/Busy.app") -> AppLoad {
        AppLoad(key: key, name: "Busy", cpu: cpu, pids: [42])
    }

    // MARK: Sustained tracker

    func testSustainedToleratesBriefDips() {
        var t = Sustained(grace: 10)
        XCTAssertNil(t.update(active: true, value: 90, at: at(0)))
        XCTAssertNil(t.update(active: false, value: 0, at: at(5)), "a 5 s dip is within grace")
        XCTAssertNil(t.update(active: true, value: 120, at: at(10)))
        XCTAssertEqual(t.current(at: at(10))?.duration, 10)
        XCTAssertNil(t.update(active: false, value: 0, at: at(15)))
        let ep = t.update(active: false, value: 0, at: at(25))
        XCTAssertEqual(ep?.duration, 10, "ends at the last active sample")
        XCTAssertEqual(ep?.peak, 120)
        XCTAssertEqual(ep?.average, 105)
        XCTAssertFalse(t.isActive)
    }

    func testSlowSamplingCountsTheWholeInterval() {
        // Background sampling every 10 s: busy at 10…40 s means busy since ~0 s.
        var t = Sustained(grace: 10)
        _ = t.update(active: false, value: 0, at: at(0))
        for s in stride(from: 10.0, through: 40, by: 10) { _ = t.update(active: true, value: 100, at: at(s)) }
        _ = t.update(active: false, value: 0, at: at(50))
        let ep = t.update(active: false, value: 0, at: at(60))
        XCTAssertEqual(ep?.duration, 40)
        XCTAssertEqual(ep?.start, at(0))
    }

    func testGapAfterSleepIsNotCounted() {
        var t = Sustained(grace: 10)
        _ = t.update(active: false, value: 0, at: at(0))
        _ = t.update(active: true, value: 100, at: at(3600))   // woke an hour later
        XCTAssertEqual(t.current(at: at(3600))?.duration, Sustained.maxStep)
    }

    // MARK: App CPU

    func testAppCPUAlertsOnlyWhenSustained() {
        var e = DetectionEngine()                       // 80 %, 3 min
        var events: [DetectionEvent] = []
        for i in 0...100 { events += e.evaluate(DetectionSample(date: at(Double(i) * 2), apps: [app(150)])) }
        let alerts = events.filter { $0.kind == .sustained }
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.rule, .appCPU)
        XCTAssertEqual(alerts.first?.notify, true)
        XCTAssertEqual(alerts.first?.date, at(180), "fires exactly at the 3-minute mark")
        XCTAssertEqual(alerts.first?.pids, [42])
        XCTAssertTrue(alerts.first!.reason.contains("3m"))
        XCTAssertTrue(alerts.first!.evidence.contains { $0.label == "Peak" })
    }

    func testShortCPUSpikeIsRecordedNotNotified() {
        var e = DetectionEngine()
        var events: [DetectionEvent] = []
        for i in 0..<60 {                               // 60 s over, then calm
            events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(200)]))
        }
        for i in 60..<120 { events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(5)])) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .spike)
        XCTAssertEqual(events.first?.notify, false)
        XCTAssertEqual(events.first?.severity, .info)
    }

    func testTinyBlipsAreIgnoredEntirely() {
        var e = DetectionEngine()
        var events: [DetectionEvent] = []
        for i in 0..<10 { events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(200)])) }
        for i in 10..<40 { events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(1)])) }
        XCTAssertTrue(events.isEmpty, "10 s is under the 30 s minimum for a recorded spike")
    }

    func testNoSpikeAfterAnAlertAlreadyFired() {
        var e = DetectionEngine()
        var events: [DetectionEvent] = []
        for i in 0...100 { events += e.evaluate(DetectionSample(date: at(Double(i) * 2), apps: [app(150)])) }
        for i in 101...130 { events += e.evaluate(DetectionSample(date: at(Double(i) * 2), apps: [app(0)])) }
        XCTAssertEqual(events.map(\.kind), [.sustained])
    }

    func testCooldownStopsRepeatAlerts() {
        var e = DetectionEngine()
        var events: [DetectionEvent] = []
        // Two separate 4-minute burns 10 minutes apart: second is inside the 30 min cooldown.
        for i in 0..<240 { events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(150)])) }
        for i in 240..<840 { events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(0)])) }
        for i in 840..<1080 { events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(150)])) }
        XCTAssertEqual(events.filter { $0.kind == .sustained }.count, 1)
        // After the cooldown it alerts again.
        for i in 1080..<2000 { events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(0)])) }
        for i in 2000..<2240 { events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(150)])) }
        XCTAssertEqual(events.filter { $0.kind == .sustained }.count, 2)
    }

    func testQuitAppEndsItsEpisode() {
        var e = DetectionEngine()
        var events: [DetectionEvent] = []
        for i in 0..<60 { events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(200)])) }
        for i in 60..<90 { events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [])) }   // app gone
        XCTAssertEqual(events.map(\.kind), [.spike])
        XCTAssertEqual(events.first?.subject, "Busy")
    }

    func testThresholdSettingIsRespected() {
        var s = DetectionSettings(); s.cpuThreshold = 300
        var e = DetectionEngine(settings: s)
        var events: [DetectionEvent] = []
        for i in 0..<400 { events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(200)])) }
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: Memory

    func testMemoryCriticalNeeds30Seconds() {
        var e = DetectionEngine()
        var events: [DetectionEvent] = []
        for i in 0..<20 { events += e.evaluate(DetectionSample(date: at(Double(i)), pressure: .critical)) }
        for i in 20..<100 { events += e.evaluate(DetectionSample(date: at(Double(i)), pressure: .normal)) }
        XCTAssertEqual(events.map(\.kind), [.spike], "20 s of red is a spike")
        events = []
        for i in 100..<140 { events += e.evaluate(DetectionSample(date: at(Double(i)), pressure: .critical)) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.severity, .critical)
        XCTAssertEqual(events.first?.date, at(129), "the first red sample covers the second before it")
    }

    func testMemoryWarningIsRecordedQuietly() {
        var e = DetectionEngine()
        var events: [DetectionEvent] = []
        for i in 0...160 { events += e.evaluate(DetectionSample(date: at(Double(i) * 2), pressure: .warning)) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.key, "memory:warning")
        XCTAssertEqual(events.first?.notify, false)
    }

    // MARK: Heat

    func testHeatSpikeVsSustained() {
        var e = DetectionEngine()
        var events: [DetectionEvent] = []
        for i in 0..<10 { events += e.evaluate(DetectionSample(date: at(Double(i)), thermal: .serious)) }
        for i in 10..<30 { events += e.evaluate(DetectionSample(date: at(Double(i)), thermal: .nominal)) }
        XCTAssertEqual(events.map(\.kind), [.spike])
        for i in 100..<140 { events += e.evaluate(DetectionSample(date: at(Double(i)), thermal: .critical)) }
        XCTAssertEqual(events.last?.kind, .sustained)
        XCTAssertEqual(events.last?.severity, .critical)
    }

    // MARK: Disk

    func testLowDiskFiresOncePerDay() {
        var e = DetectionEngine()
        let low = { (d: Date) in DetectionSample(date: d, diskAvailable: 5_000_000_000, diskCapacity: 250_000_000_000) }
        XCTAssertEqual(e.evaluate(low(at(0))).map(\.rule), [.diskSpace])
        XCTAssertTrue(e.evaluate(low(at(3600))).isEmpty)
        XCTAssertEqual(e.evaluate(low(at(90_000))).first?.severity, .warning)
        let veryLow = DetectionSample(date: at(200_000), diskAvailable: 1_000_000_000, diskCapacity: 250_000_000_000)
        XCTAssertEqual(e.evaluate(veryLow).first?.severity, .critical)
    }

    func testDiskFillingFast() {
        var e = DetectionEngine()
        var events: [DetectionEvent] = []
        let start: UInt64 = 100_000_000_000
        // 1 GB a minute for 6 minutes, with Busy writing.
        for m in 0...6 {
            let apps = [AppLoad(key: "w", name: "Writer", cpu: 10, diskWritePerSec: 16_000_000, pids: [7])]
            events += e.evaluate(DetectionSample(date: at(Double(m) * 60), apps: apps,
                                                 diskAvailable: start - UInt64(m) * 1_000_000_000, diskCapacity: 250_000_000_000))
        }
        let filling = events.filter { $0.rule == .diskFilling }
        XCTAssertEqual(filling.count, 1)
        XCTAssertEqual(filling.first?.date, at(300), "5 GB gone after 5 minutes")
        XCTAssertTrue(filling.first!.evidence.contains { $0.value.contains("Writer") })
        XCTAssertEqual(filling.first?.pids, [7])
    }

    func testSlowDiskUseDoesNotCountAsFilling() {
        var e = DetectionEngine()
        var events: [DetectionEvent] = []
        for m in 0...60 {    // 5 GB over an hour
            events += e.evaluate(DetectionSample(date: at(Double(m) * 60),
                                                 diskAvailable: 100_000_000_000 - UInt64(m) * 85_000_000, diskCapacity: 250_000_000_000))
        }
        XCTAssertTrue(events.isEmpty)
    }

    func testHeavyWritesSustainedAndSpike() {
        var e = DetectionEngine()                     // 100 MB/s for 2 min
        var events: [DetectionEvent] = []
        for i in 0..<25 { events += e.evaluate(DetectionSample(date: at(Double(i)), diskWritePerSec: 300_000_000)) }
        for i in 25..<45 { events += e.evaluate(DetectionSample(date: at(Double(i)), diskWritePerSec: 0)) }
        XCTAssertEqual(events.map(\.kind), [.spike])
        for i in 1000..<1130 { events += e.evaluate(DetectionSample(date: at(Double(i)), diskWritePerSec: 300_000_000)) }
        XCTAssertEqual(events.last?.kind, .sustained)
        XCTAssertEqual(events.last?.notify, false)
    }

    func testHeavyNetworkSustainedAndSpike() {
        var e = DetectionEngine()                     // 10 MB/s for 2 min
        var events: [DetectionEvent] = []
        for i in 0..<25 { events += e.evaluate(DetectionSample(date: at(Double(i)), networkPerSec: 40_000_000)) }
        for i in 25..<45 { events += e.evaluate(DetectionSample(date: at(Double(i)), networkPerSec: 0)) }
        XCTAssertEqual(events.map(\.kind), [.spike])
        XCTAssertEqual(events.first?.rule, .network)
        let uploader = AppLoad(key: "/Applications/Sync.app", name: "Sync", cpu: 5, netPerSec: 30_000_000, pids: [7])
        for i in 1000..<1130 {
            events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [uploader], networkPerSec: 30_000_000))
        }
        let last = events.last
        XCTAssertEqual(last?.kind, .sustained)
        XCTAssertEqual(last?.notify, false, "recorded in History only")
        XCTAssertEqual(last?.subject, "Sync")
        XCTAssertEqual(last?.pids, [7])
    }

    func testNetworkBelowThresholdIsQuiet() {
        var e = DetectionEngine()
        var events: [DetectionEvent] = []
        for i in 0..<400 { events += e.evaluate(DetectionSample(date: at(Double(i)), networkPerSec: 9_000_000)) }
        XCTAssertTrue(events.isEmpty)
    }

    func testRulesCanBeTurnedOff() {
        var s = DetectionSettings()
        s.appCPU = false; s.memory = false; s.heat = false; s.disk = false; s.diskWrites = false; s.network = false
        var e = DetectionEngine(settings: s)
        var events: [DetectionEvent] = []
        for i in 0..<400 {
            events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(300)], pressure: .critical, thermal: .critical,
                                                 diskAvailable: 1, diskCapacity: 100, diskWritePerSec: 1e9, networkPerSec: 1e9))
        }
        XCTAssertTrue(events.isEmpty)
    }

    func testSpikeRecordingCanBeTurnedOff() {
        var s = DetectionSettings(); s.recordSpikes = false
        var e = DetectionEngine(settings: s)
        var events: [DetectionEvent] = []
        for i in 0..<60 { events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(200)])) }
        for i in 60..<90 { events += e.evaluate(DetectionSample(date: at(Double(i)), apps: [app(0)])) }
        XCTAssertTrue(events.isEmpty)
    }

    func testEventsRoundTripAsJSON() throws {
        let ev = DetectionEvent(rule: .appCPU, key: "k", date: t0, started: t0, severity: .warning, kind: .sustained,
                                title: "T", summary: "S", reason: "R", evidence: [Evidence("Peak", "200%")], notify: true)
        let d = try JSONEncoder().encode([ev])
        XCTAssertEqual(try JSONDecoder().decode([DetectionEvent].self, from: d), [ev])
    }
}

final class MemoryGrowthTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func app(_ mb: Double, key: String = "/Applications/Leaky.app") -> AppLoad {
        AppLoad(key: key, name: "Leaky", cpu: 1, memory: UInt64(mb * 1_000_000), pids: [9])
    }

    /// One sample every 10 s for `minutes`, memory from `mb(minute)`.
    func feed(_ e: inout DetectionEngine, minutes: Int, from start: Int = 0, pressure: PressureState = .normal,
              swap: (Double) -> UInt64 = { _ in 0 }, _ mb: (Double) -> Double) -> [DetectionEvent] {
        var out: [DetectionEvent] = []
        for i in stride(from: start * 6, to: (start + minutes) * 6, by: 1) {
            let m = Double(i) / 6
            out += e.evaluate(DetectionSample(date: at(Double(i) * 10), apps: [app(mb(m))], pressure: pressure, swapUsed: swap(m)))
        }
        return out
    }

    func testSteadyLeakAlertsAfter30Minutes() {
        var e = DetectionEngine()
        let events = feed(&e, minutes: 45) { 400 + $0 * 30 }        // +30 MB a minute
        let g = events.filter { $0.rule == .memoryGrowth }
        XCTAssertEqual(g.count, 1, "fires once, then cools down")
        let first = g[0]
        XCTAssertGreaterThanOrEqual(first.date.timeIntervalSince(first.started), 1800)
        XCTAssertLessThan(first.date.timeIntervalSince(t0), 1900, "soon after 30 minutes")
        XCTAssertTrue(first.notify)
        XCTAssertEqual(first.pids, [9])
        XCTAssertGreaterThanOrEqual(first.series?.count ?? 0, 30)
        XCTAssertTrue(first.evidence.contains { $0.label == "Rate" })
    }

    func testFlatOrSawtoothMemoryIsNotALeak() {
        var e = DetectionEngine()
        XCTAssertTrue(feed(&e, minutes: 60) { _ in 2000 }.isEmpty, "flat")
        var e2 = DetectionEngine()
        // Caches that fill and empty every 10 minutes.
        XCTAssertTrue(feed(&e2, minutes: 60) { 800 + Double(Int($0) % 10) * 80 }.isEmpty, "sawtooth")
    }

    func testSmallOrProportionallyTinyGrowthIsIgnored() {
        var e = DetectionEngine()
        XCTAssertTrue(feed(&e, minutes: 50) { 300 + $0 * 4 }.isEmpty, "only +200 MB")
        var e2 = DetectionEngine()
        XCTAssertTrue(feed(&e2, minutes: 50) { 6000 + $0 * 12 }.isEmpty, "+600 MB on 6 GB is under half")
    }

    func testOneJumpIsNotSteadyGrowth() {
        var e = DetectionEngine()
        XCTAssertTrue(feed(&e, minutes: 60) { $0 < 30 ? 500 : 1500 }.isEmpty, "a single step up fits a line poorly")
    }

    func testQuittingForgetsTheTrail() {
        var e = DetectionEngine()
        _ = feed(&e, minutes: 25) { 400 + $0 * 30 }
        _ = e.evaluate(DetectionSample(date: at(25 * 60 + 5), apps: []))           // app quit
        let after = feed(&e, minutes: 10, from: 26) { 400 + ($0 - 26) * 30 }    // relaunched
        XCTAssertTrue(after.filter { $0.rule == .memoryGrowth }.isEmpty, "the new instance starts over")
    }

    func testGrowthFit() {
        let pts = (0..<40).map { (t0.addingTimeInterval(Double($0) * 60), 500_000_000 + Double($0) * 25_000_000) }
        let g = DetectionEngine.growth(pts)
        XCTAssertNotNil(g)
        XCTAssertEqual(g!.perHour, 1_500_000_000, accuracy: 1)
        XCTAssertEqual(g!.fit, 1, accuracy: 0.0001)
    }

    func testSwapGrowingUnderPressure() {
        var e = DetectionEngine()
        // +100 MB of swap a minute while pressure is elevated: 1 GB after 10 minutes.
        let events = feed(&e, minutes: 14, pressure: .warning, swap: { UInt64(2_000_000_000 + $0 * 100_000_000) }) { _ in 300 }
        let s = events.filter { $0.rule == .swapGrowth }
        XCTAssertEqual(s.count, 1)
        XCTAssertTrue(s[0].notify)
        XCTAssertTrue(s[0].evidence.contains { $0.label == "Largest app" })
    }

    func testSwapGrowthNeedsPressure() {
        var e = DetectionEngine()
        let events = feed(&e, minutes: 14, pressure: .normal, swap: { UInt64(2_000_000_000 + $0 * 100_000_000) }) { _ in 300 }
        XCTAssertTrue(events.isEmpty, "swap can grow harmlessly when pressure is normal")
    }

    func testElevatedPressureWordingIsNotHigh() {
        var e = DetectionEngine()
        var events: [DetectionEvent] = []
        for i in 0...160 { events += e.evaluate(DetectionSample(date: at(Double(i) * 2), pressure: .warning)) }
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].title.contains("elevated"))
        XCTAssertFalse(events[0].title.lowercased().contains("high"))
    }

    func testOldSettingsStillDecode() throws {
        let old = #"{"appCPU":true,"cpuThreshold":150,"cpuMinutes":5,"memory":true,"heat":false,"disk":true,"diskWrites":true,"writeThreshold":100000000,"writeMinutes":2,"recordSpikes":true}"#
        let s = try JSONDecoder().decode(DetectionSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.cpuThreshold, 150)
        XCTAssertFalse(s.heat)
        XCTAssertTrue(s.memoryGrowth, "new rule defaults on")
        XCTAssertTrue(s.network)
        XCTAssertEqual(s.networkThreshold, 10_000_000)
    }
}
