import Darwin
import Foundation

/// Thin wrappers over sysctl / mach for values read on the sampling thread.
enum Sysctl {
    static func int(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        switch size {
        case 4:
            var v: Int32 = 0
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
        case 8:
            var v: Int64 = 0
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
        default:
            return nil
        }
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6)
    }

    static func swapUsage() -> (used: UInt64, total: UInt64) {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 else { return (0, 0) }
        return (xsw.xsu_used, xsw.xsu_total)
    }
}

/// Converts Mach absolute time units to nanoseconds. On Apple Silicon the
/// per-task CPU times from libproc are in Mach units (timebase 125/3), on Intel
/// the ratio is 1/1, so this is always safe to apply.
enum MachTime {
    static let ratio: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return tb.denom == 0 ? 1 : Double(tb.numer) / Double(tb.denom)
    }()

    @inline(__always) static func ns(_ ticks: UInt64) -> Double { Double(ticks) * ratio }
}

extension String {
    /// Builds a String from a fixed-size C char tuple (e.g. `pbi_comm`, `ut_user`).
    init<T>(cTuple: T) {
        self = withUnsafeBytes(of: cTuple) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }
}
