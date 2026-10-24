// apex-fanhelper — Apex's privileged fan helper (runs as a root LaunchDaemon).
//
// Scope is intentionally tiny and auditable:
//   * reads ONE settings file (FanControl.configPath); takes no other input,
//     no network, no commands;
//   * only writes the SMC fan keys (mode / target), always clamped to each
//     fan's own min/max reported by the SMC;
//   * returns every fan to automatic when the settings are stale (Apex quit),
//     invalid, all-automatic, or when the helper is stopped.
// Fan control on Apple Silicon is undocumented and varies by chip: M3/M4 may
// need the Ftst unlock key, M5 uses lowercase F<n>md. macOS can reclaim the
// fans after sleep, so targets are re-applied every cycle.
import Foundation
import IOKit
import IOKit.pwr_mgt
import FanControlCore

// MARK: SMC (read + write)

final class SMC {
    private var conn: io_connect_t = 0
    private struct KeyData {
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        // Must match the C SMCKeyData_keyInfo_t (12 bytes incl. padding), or every SMC call fails.
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
        var key: UInt32 = 0; var vers = Vers(); var pLimit = PLimit(); var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0; var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ input: inout KeyData) -> KeyData? {
        var out = KeyData(); var size = MemoryLayout<KeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &out, &size)
        return r == kIOReturnSuccess && out.result == 0 ? out : nil
    }

    private func info(_ key: String) -> KeyData.KeyInfo? {
        var i = KeyData(); i.key = Self.code(key); i.data8 = 9
        return call(&i)?.keyInfo
    }

    private func type(_ ki: KeyData.KeyInfo) -> String {
        String(bytes: withUnsafeBytes(of: ki.dataType.bigEndian) { Array($0) }, encoding: .ascii) ?? ""
    }

    func exists(_ key: String) -> Bool { info(key) != nil }

    /// Writes raw bytes (used for the charging keys, whose encodings vary).
    @discardableResult
    func writeBytes(_ key: String, _ value: [UInt8]) -> Bool {
        guard let ki = info(key), Int(ki.dataSize) == value.count else { return false }
        var w = KeyData(); w.key = Self.code(key); w.keyInfo = ki; w.data8 = 6
        withUnsafeMutableBytes(of: &w.bytes) { raw in for (i, b) in value.enumerated() { raw[i] = b } }
        return call(&w) != nil
    }

    func readBytes(_ key: String) -> [UInt8]? {
        guard let ki = info(key) else { return nil }
        var r = KeyData(); r.key = Self.code(key); r.keyInfo = ki; r.data8 = 5
        guard let o = call(&r) else { return nil }
        return withUnsafeBytes(of: o.bytes) { Array($0.prefix(Int(ki.dataSize))) }
    }

    func read(_ key: String) -> Double? {
        guard let ki = info(key) else { return nil }
        var r = KeyData(); r.key = Self.code(key); r.keyInfo = ki; r.data8 = 5
        guard let o = call(&r) else { return nil }
        let b = withUnsafeBytes(of: o.bytes) { Array($0.prefix(Int(ki.dataSize))) }
        switch type(ki) {
        case "flt ": return b.count >= 4 ? Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }) : nil
        case "fpe2": return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4 : nil
        case "ui8 ": return b.first.map(Double.init)
        case "ui16": return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        default: return nil
        }
    }

    @discardableResult
    func write(_ key: String, _ value: Double) -> Bool {
        guard let ki = info(key) else { return false }
        var bytes = [UInt8](repeating: 0, count: 32)
        switch type(ki) {
        case "flt ": withUnsafeBytes(of: Float32(value)) { for i in 0..<4 { bytes[i] = $0[i] } }
        case "fpe2": let v = UInt16(max(0, min(16383, value * 4))); bytes[0] = UInt8(v >> 8); bytes[1] = UInt8(v & 0xff)
        case "ui8 ": bytes[0] = UInt8(max(0, min(255, value)))
        case "ui16": let v = UInt16(max(0, min(65535, value))); bytes[0] = UInt8(v >> 8); bytes[1] = UInt8(v & 0xff)
        default: return false
        }
        var w = KeyData(); w.key = Self.code(key); w.keyInfo = ki; w.data8 = 6
        withUnsafeMutableBytes(of: &w.bytes) { raw in for i in 0..<min(32, Int(ki.dataSize)) { raw[i] = bytes[i] } }
        return call(&w) != nil
    }
}

// MARK: Temperatures (Apple Silicon HID sensors, same source the app uses)

final class Temperatures {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopySvcFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvtFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double
    private var client: AnyObject?
    private var services: [(String, AnyObject)] = []
    private var copyEvt: CopyEvtFn?, getFloat: GetFloatFn?

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let c = dlsym(h, "IOHIDEventSystemClientCreate"), let m = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let cs = dlsym(h, "IOHIDEventSystemClientCopyServices"), let cp = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let ce = dlsym(h, "IOHIDServiceClientCopyEvent"), let gf = dlsym(h, "IOHIDEventGetFloatValue") else { return }
        copyEvt = unsafeBitCast(ce, to: CopyEvtFn.self)
        getFloat = unsafeBitCast(gf, to: GetFloatFn.self)
        guard let cl = unsafeBitCast(c, to: CreateFn.self)(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        _ = unsafeBitCast(m, to: SetMatchFn.self)(cl, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let list = (unsafeBitCast(cs, to: CopySvcFn.self)(cl)?.takeRetainedValue() as? [AnyObject]) ?? []
        let prop = unsafeBitCast(cp, to: CopyPropFn.self)
        services = list.compactMap { s in (prop(s, "Product" as CFString)?.takeRetainedValue() as? String).map { ($0, s) } }
        client = cl
    }

    func read() -> FanControl.Temps {
        var cpu: [Double] = [], gpu: [Double] = [], all: [Double] = []
        guard let copyEvt, let getFloat else { return .init(cpu: nil, gpu: nil, hottest: nil) }
        for (name, s) in services {
            guard let e = copyEvt(s, 15, 0, 0)?.takeRetainedValue() else { continue }
            let v = getFloat(e, 15 << 16)
            guard v > 0, v < 130 else { continue }
            all.append(v)
            let l = name.lowercased()
            if (l.hasPrefix("pmu") && l.contains("tdie")) || l.contains("pacc") || l.contains("eacc") { cpu.append(v) }
            if l.contains("gpu") { gpu.append(v) }
        }
        func avg(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        return .init(cpu: avg(cpu), gpu: avg(gpu), hottest: all.max())
    }
}

// MARK: Battery charge limit

/// How this Mac's firmware lets us stop charging (probed once).
enum ChargeMethod {
    case pauseCH0B, pauseCHTE, holdCHIE
    var name: String { self == .holdCHIE ? "hold" : "pause" }
}

final class ChargeLimiter {
    let smc: SMC
    let method: ChargeMethod?
    private(set) var blocked = false

    init(smc: SMC) {
        self.smc = smc
        if smc.exists("CH0B") && smc.exists("CH0C") { method = .pauseCH0B }
        else if smc.exists("CHTE") { method = .pauseCHTE }
        else if smc.exists("CHIE") { method = .holdCHIE }
        else { method = nil }
    }

    static func batteryPercent() -> Int? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        func int(_ k: String) -> Int? {
            (IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        guard let cur = int("CurrentCapacity"), let max = int("MaxCapacity"), max > 0 else { return nil }
        return max == 100 ? cur : cur * 100 / max
    }

    private func writes(_ want: Bool) -> [(String, [UInt8])] {
        switch method {
        case .pauseCH0B?: return [("CH0B", [want ? 0x02 : 0x00]), ("CH0C", [want ? 0x02 : 0x00])]
        case .pauseCHTE?: return [("CHTE", want ? [1, 0, 0, 0] : [0, 0, 0, 0])]
        case .holdCHIE?: return [("CHIE", [want ? 0x08 : 0x00])]
        case nil: return []
        }
    }

    /// Writes the keys and reads them back, so "blocked" is only reported when
    /// the firmware really took it.
    @discardableResult
    func set(blocked want: Bool) -> Bool {
        guard method != nil else { return false }
        var ok = true
        for (k, v) in writes(want) {
            smc.writeBytes(k, v)
            if smc.readBytes(k) != v { ok = false }
        }
        if ok { blocked = want }
        return ok
    }

    /// True if the firmware still holds our "blocked" values (macOS can reset
    /// them, e.g. after sleep or a battery reconnect).
    var firmwareBlocked: Bool {
        let w = writes(true)
        return !w.isEmpty && w.allSatisfy { smc.readBytes($0.0) == $0.1 }
    }

    /// Charging back to normal (on exit, limit off, override, or any doubt).
    func release() { if method != nil { set(blocked: false) }; blocked = false }
}

func writeStatus(_ status: FanControl.Status) {
    let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
    guard let data = try? e.encode(status) else { return }
    try? data.write(to: URL(fileURLWithPath: FanControl.statusPath), options: .atomic)
    chmod(FanControl.statusPath, 0o644)
}

// MARK: Control loop

guard getuid() == 0 else { FileHandle.standardError.write("apex-fanhelper must run as root\n".data(using: .utf8)!); exit(1) }
guard let smc = SMC() else { FileHandle.standardError.write("AppleSMC unavailable\n".data(using: .utf8)!); exit(1) }
let temps = Temperatures()
let charger = ChargeLimiter(smc: smc)
// A previous run may have been killed while holding: always start from normal charging.
charger.release()
var tick = 0
var chargeMessage: String?
var lastGoodConfig: FanControl.Config?
var consumedOverride: Date?
var asleep = false

/// System sleep: in "hold" mode the charger is disconnected, so a sleeping Mac
/// would drain while plugged in. Hand charging back before sleep, re-check on
/// wake. Exception: during night charging the hold stays on, and the Mac is
/// woken briefly every 30 minutes (and at top-up time) to re-check.
var scheduledWake: Date?
func scheduleNightWake() {
    if let old = scheduledWake {
        IOPMCancelScheduledPowerEvent(old as CFDate, "com.apex.fanhelper" as CFString, kIOPMAutoWake as CFString)
        scheduledWake = nil
    }
    guard let next = FanControl.nextNightCheck(lastGoodConfig?.nightCharging, now: Date()) else { return }
    if IOPMSchedulePowerEvent(next as CFDate, "com.apex.fanhelper" as CFString, kIOPMAutoWake as CFString) == kIOReturnSuccess {
        scheduledWake = next
    }
}
func nightHoldActive() -> Bool {
    guard let n = lastGoodConfig?.nightCharging else { return false }
    if case .hold = FanControl.nightPlan(n, now: Date()).phase { return charger.blocked }
    return false
}
var rootPort: io_connect_t = 0
var notifyPort: IONotificationPortRef?
var notifier: io_object_t = 0
rootPort = IORegisterForSystemPower(nil, &notifyPort, { _, _, type, arg in
    let msg = type & 0xFFFFFFFF
    switch UInt32(msg) {
    case 0xE0000270: // kIOMessageCanSystemSleep
        IOAllowPowerChange(rootPort, Int(bitPattern: arg))
    case 0xE0000280: // kIOMessageSystemWillSleep
        asleep = true
        if charger.method == .holdCHIE && !nightHoldActive() { charger.release() }
        scheduleNightWake()
        IOAllowPowerChange(rootPort, Int(bitPattern: arg))
    case 0xE0000300: // kIOMessageSystemHasPoweredOn
        asleep = false
        tick = 0   // re-evaluate the limit right away
    default: break
    }
}, &notifier)
if let notifyPort { IONotificationPortSetDispatchQueue(notifyPort, .main) }
let fanCount = Int(smc.read("FNum") ?? 0)
var manual = Set<Int>()          // fans we've taken control of
var unlocked = false             // Ftst set by us
var lastTarget: [Int: Double] = [:]
var lastWrite = Date.distantPast

func modeKey(_ i: Int) -> String { smc.exists("F\(i)Md") ? "F\(i)Md" : "F\(i)md" }

func takeControl(_ i: Int) -> Bool {
    if manual.contains(i) { return true }
    if smc.write(modeKey(i), 1), smc.read(modeKey(i)) == 1 { manual.insert(i); return true }
    // M3/M4: unlock first, give thermalmonitord a moment, retry.
    if smc.exists("Ftst"), !unlocked { smc.write("Ftst", 1); unlocked = true; Thread.sleep(forTimeInterval: 3) }
    if smc.write(modeKey(i), 1) { manual.insert(i); return true }
    return false
}

func releaseAll() {
    for i in manual { smc.write(modeKey(i), 0) }
    manual.removeAll(); lastTarget.removeAll()
    if unlocked { smc.write("Ftst", 0); unlocked = false }
}

for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { releaseAll(); charger.release(); exit(0) }
    src.resume()
    _ = Unmanaged.passRetained(src as AnyObject)
}

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(300))
timer.setEventHandler {
    // Missing file = helper being removed. Unreadable/half-written = keep the last good settings.
    let raw: FanControl.Config?
    if let data = FileManager.default.contents(atPath: FanControl.configPath) {
        if let c = FanControl.decode(data) { lastGoodConfig = c }
        raw = lastGoodConfig
    } else { lastGoodConfig = nil; raw = nil }

    // Battery limit: enforced whether or not Apex is open (checked every 10 s).
    if tick % 5 == 0 && !asleep {
        let percent = ChargeLimiter.batteryPercent()
        // "Charge to 100% now" ends once the battery is full.
        let override = FanControl.overrideActive(until: raw?.chargeOverrideUntil, consumed: consumedOverride)
        if let o = override, (percent ?? 0) >= 100 { consumedOverride = o }
        let overrideNow = FanControl.overrideActive(until: raw?.chargeOverrideUntil, consumed: consumedOverride)
        // Schedules can raise (full charge) or set the limit for a window.
        var limit = raw.flatMap { FanControl.effectiveLimit($0, overrideActive: overrideNow != nil).limit }
        if let l = limit, !FanControl.chargeLimitRange.contains(l) { limit = nil }
        let want = FanControl.shouldBlockCharging(percent: percent, limit: limit, overrideUntil: overrideNow,
                                                  currentlyBlocked: charger.blocked)
        if charger.method == nil {
            chargeMessage = limit == nil ? nil : "This Mac’s firmware doesn’t allow charge control."
        } else if want != charger.blocked || (want && !charger.firmwareBlocked) {
            // Also re-asserts if macOS quietly reset the keys.
            if charger.set(blocked: want) { chargeMessage = nil }
            else { chargeMessage = "macOS refused the charging change on this Mac."; charger.release() }
        }
        writeStatus(.init(updated: Date(), fanTargets: lastTarget, chargeMethod: charger.method?.name,
                          chargingBlocked: charger.blocked, batteryPercent: percent, message: chargeMessage))
    }
    tick &+= 1

    // Fans: only while Apex is running (fresh heartbeat).
    guard fanCount > 0, let raw, FanControl.isFresh(raw) else { releaseAll(); return }
    let cfg = FanControl.sanitized(raw)
    if cfg.allAutomatic { releaseAll(); return }
    let t = temps.read()
    let reapply = Date().timeIntervalSince(lastWrite) > 30      // macOS may reclaim after sleep
    for f in cfg.fans where f.index < fanCount {
        let minR = smc.read("F\(f.index)Mn") ?? 0, maxR = smc.read("F\(f.index)Mx") ?? 0
        guard let target = FanControl.target(f, minRPM: minR, maxRPM: maxR, temps: t) else {
            if manual.contains(f.index) { smc.write(modeKey(f.index), 0); manual.remove(f.index); lastTarget[f.index] = nil }
            continue
        }
        guard takeControl(f.index) else { continue }
        if reapply || abs((lastTarget[f.index] ?? -1) - target) >= 50 {
            smc.write(modeKey(f.index), 1)
            smc.write("F\(f.index)Tg", target)
            lastTarget[f.index] = target
        }
    }
    if reapply { lastWrite = Date() }
}
timer.resume()
dispatchMain()
