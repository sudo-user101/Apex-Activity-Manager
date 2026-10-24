import Foundation
import IOKit

struct SensorReading: Identifiable, Sendable, Hashable {
    var id: String { name }
    let name: String
    let group: String       // "CPU", "GPU", "System chip", "Storage", "Battery", "Other"
    let celsius: Double
}

struct FanReading: Identifiable, Sendable, Hashable {
    var id: Int { index }
    let index: Int
    let rpm: Double
    let minRPM: Double
    let maxRPM: Double
}

struct SensorSnapshot: Sendable {
    var temperatures: [SensorReading] = []
    var fans: [FanReading] = []
    var cpuTemp: Double? { average("CPU") }
    var gpuTemp: Double? { average("GPU") }
    var hottest: SensorReading? { temperatures.max { $0.celsius < $1.celsius } }

    func average(_ group: String) -> Double? {
        let v = temperatures.filter { $0.group == group }.map(\.celsius)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
}

/// Temperatures (Apple Silicon HID sensors) and fans (SMC). No admin rights.
/// The HID client is created once; a read of all sensors takes a few ms.
/// Only sampled while the Sensors page or a temperature alert needs it.
final class Sensors: @unchecked Sendable {
    static let shared = Sensors()
    private let lock = NSLock()

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopySvcFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvtFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private var services: [(name: String, group: String, ref: AnyObject)]?
    private var copyEvt: CopyEvtFn?
    private var getFloat: GetFloatFn?
    private let smc = SMC()

    func read() -> SensorSnapshot {
        lock.lock(); defer { lock.unlock() }
        var snap = SensorSnapshot()
        if services == nil { setUpHID() }
        if let services, let copyEvt, let getFloat {
            var seen = [String: Int]()
            for s in services {
                guard let e = copyEvt(s.ref, 15, 0, 0)?.takeRetainedValue() else { continue }
                let c = getFloat(e, 15 << 16)
                guard c > 0, c < 130 else { continue }     // unused channels report nonsense
                seen[s.name, default: 0] += 1
                let name = seen[s.name]! > 1 ? "\(s.name) #\(seen[s.name]!)" : s.name
                snap.temperatures.append(SensorReading(name: name, group: s.group, celsius: c))
            }
        }
        snap.fans = smc.fans()
        return snap
    }

    private func setUpHID() {
        services = []
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let c = dlsym(h, "IOHIDEventSystemClientCreate"), let m = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let cs = dlsym(h, "IOHIDEventSystemClientCopyServices"), let cp = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let ce = dlsym(h, "IOHIDServiceClientCopyEvent"), let gf = dlsym(h, "IOHIDEventGetFloatValue") else { return }
        let create = unsafeBitCast(c, to: CreateFn.self)
        let setMatch = unsafeBitCast(m, to: SetMatchFn.self)
        let copySvc = unsafeBitCast(cs, to: CopySvcFn.self)
        let copyProp = unsafeBitCast(cp, to: CopyPropFn.self)
        copyEvt = unsafeBitCast(ce, to: CopyEvtFn.self)
        getFloat = unsafeBitCast(gf, to: GetFloatFn.self)
        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        _ = setMatch(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let list = (copySvc(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        services = list.compactMap { s in
            guard let name = copyProp(s, "Product" as CFString)?.takeRetainedValue() as? String else { return nil }
            return (name, Self.group(name), s)
        }.sorted { $0.name < $1.name }
        objc_setAssociatedObject(self, &Self.clientKey, client, .OBJC_ASSOCIATION_RETAIN)
    }
    private static var clientKey = 0

    private static func group(_ n: String) -> String {
        let l = n.lowercased()
        if l.hasPrefix("pmu") && l.contains("tdie") { return "CPU" }
        if l.contains("pacc") || l.contains("eacc") || l.contains("cpu") { return "CPU" }
        if l.contains("gpu") { return "GPU" }
        if l.contains("nand") || l.contains("ssd") { return "Storage" }
        if l.contains("battery") || l.contains("gas gauge") { return "Battery" }
        if l.contains("soc") || l.contains("pmgr") || l.contains("ane") || l.contains("isp") { return "System chip" }
        return "Other"
    }
}

/// Minimal read-only SMC client (fan speeds). Apple Silicon and Intel.
final class SMC {
    private var conn: io_connect_t = 0

    private struct KeyData {
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        // Must match the C SMCKeyData_keyInfo_t (12 bytes incl. padding), or every SMC call fails.
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        IOServiceOpen(svc, mach_task_self_, 0, &conn)
        IOObjectRelease(svc)
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outSize = MemoryLayout<KeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &output, &outSize)
        return r == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    /// Value of a numeric key, or nil.
    func value(_ key: String) -> Double? {
        guard conn != 0 else { return nil }
        var info = KeyData(); info.key = Self.code(key); info.data8 = 9   // get key info
        guard let i = call(&info) else { return nil }
        var read = KeyData(); read.key = Self.code(key); read.keyInfo = i.keyInfo; read.data8 = 5   // read
        guard let o = call(&read) else { return nil }
        let b = withUnsafeBytes(of: o.bytes) { Array($0.prefix(Int(i.keyInfo.dataSize))) }
        let type = String(bytes: withUnsafeBytes(of: i.keyInfo.dataType.bigEndian) { Array($0) }, encoding: .ascii) ?? ""
        switch type {
        case "flt ": return b.count >= 4 ? Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }) : nil
        case "fpe2": return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4 : nil
        case "ui8 ": return b.first.map(Double.init)
        case "ui16": return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        case "ui32": return b.count >= 4 ? Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) : nil
        default: return nil
        }
    }

    func fans() -> [FanReading] {
        guard let n = value("FNum"), n > 0 else { return [] }
        return (0..<Int(n)).compactMap { i in
            guard let rpm = value("F\(i)Ac") else { return nil }
            return FanReading(index: i, rpm: rpm, minRPM: value("F\(i)Mn") ?? 0, maxRPM: value("F\(i)Mx") ?? 0)
        }
    }
}
