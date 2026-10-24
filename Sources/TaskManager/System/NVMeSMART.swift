import Foundation
import IOKit

/// The NVMe health log (SMART / log page 2) of internal SSDs, through Apple's
/// NVMe SMART user client. No admin rights needed. USB drives don't expose it.
struct SMARTHealth: Sendable, Codable, Equatable {
    var criticalWarning: Int        // bit flags; 0 = none
    var temperatureC: Int
    var availableSpare: Int         // %
    var spareThreshold: Int         // %
    var percentageUsed: Int         // % of rated lifespan used (can exceed 100)
    var dataReadBytes: UInt64
    var dataWrittenBytes: UInt64
    var powerCycles: UInt64
    var powerOnHours: UInt64
    var unsafeShutdowns: UInt64
    var mediaErrors: UInt64
    var errorLogEntries: UInt64

    /// Parses the 512-byte log page (NVMe spec layout, little-endian).
    static func parse(_ d: [UInt8]) -> SMARTHealth? {
        guard d.count >= 192 else { return nil }
        func u64(_ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(d[o + $1]) << (8 * UInt64($1)) } }
        let kelvin = Int(d[1]) | Int(d[2]) << 8
        let unit: UInt64 = 512_000   // NVMe "data unit" = 1000 × 512 bytes
        return SMARTHealth(criticalWarning: Int(d[0]), temperatureC: kelvin > 0 ? kelvin - 273 : 0,
                           availableSpare: Int(d[3]), spareThreshold: Int(d[4]), percentageUsed: Int(d[5]),
                           dataReadBytes: u64(32).multipliedReportingOverflow(by: unit).partialValue,
                           dataWrittenBytes: u64(48).multipliedReportingOverflow(by: unit).partialValue,
                           powerCycles: u64(112), powerOnHours: u64(128), unsafeShutdowns: u64(144),
                           mediaErrors: u64(160), errorLogEntries: u64(176))
    }
}

enum NVMeSMART {
    private typealias QueryInterface = @convention(c) (UnsafeMutableRawPointer?, CFUUIDBytes, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> HRESULT
    private typealias Release = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    private typealias ReadData = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn

    /// IUnknown header shared by every CFPlugIn interface.
    private struct UnknownVTable {
        var reserved: UnsafeMutableRawPointer?
        var queryInterface: QueryInterface?
        var addRef: Release?
        var release: Release?
    }
    /// IONVMeSMARTInterface (NVMeSMARTLibExternal.h), first entries only.
    private struct SMARTVTable {
        var reserved: UnsafeMutableRawPointer?
        var queryInterface: QueryInterface?
        var addRef: Release?
        var release: Release?
        var version: UInt16
        var revision: UInt16
        var smartReadData: ReadData?
    }

    // kIONVMeSMARTUserClientTypeID, kIONVMeSMARTInterfaceID, kIOCFPlugInInterfaceID
    private static let userClientType = CFUUIDGetConstantUUIDWithBytes(nil, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    private static let smartInterface = CFUUIDGetConstantUUIDWithBytes(nil, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    private static let plugInInterface = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)

    /// The first internal NVMe drive's health log, or nil if unavailable.
    static func readInternal() -> SMARTHealth? {
        guard let userClientType, let smartInterface, let plugInInterface else { return nil }
        var it: io_iterator_t = 0
        let match = [kIOPropertyMatchKey: ["NVMe SMART Capable": true]] as CFDictionary
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
            var score: Int32 = 0
            guard IOCreatePlugInInterfaceForService(svc, userClientType, plugInInterface, &plugin, &score) == KERN_SUCCESS,
                  let plugin else { continue }
            let pluginRaw = UnsafeMutableRawPointer(plugin)
            let unknown = pluginRaw.assumingMemoryBound(to: UnsafeMutablePointer<UnknownVTable>.self).pointee.pointee
            defer { _ = unknown.release?(pluginRaw) }
            var iface: UnsafeMutableRawPointer?
            guard unknown.queryInterface?(pluginRaw, CFUUIDGetUUIDBytes(smartInterface), &iface) == 0, let iface else { continue }
            let vt = iface.assumingMemoryBound(to: UnsafeMutablePointer<SMARTVTable>.self).pointee.pointee
            defer { _ = vt.release?(iface) }
            var data = [UInt8](repeating: 0, count: 512)
            let r = data.withUnsafeMutableBytes { vt.smartReadData?(iface, $0.baseAddress) ?? kIOReturnUnsupported }
            if r == kIOReturnSuccess, let h = SMARTHealth.parse(data) { return h }
        }
        return nil
    }
}
