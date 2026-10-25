import AppKit
import CoreGraphics
import IOKit

/// One connected display.
struct DisplayInfo: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    var name: String
    var isBuiltin: Bool
    var isMain: Bool
    var pointsWide: Int, pointsHigh: Int        // "looks like"
    var pixelsWide: Int, pixelsHigh: Int        // what the panel draws
    var refresh: Double                         // Hz, 0 = unknown
    var diagonalInches: Double?                 // from the reported physical size
    var vendor: UInt32, model: UInt32
    var rotation: Int
    var hdr: Bool                               // can show HDR (extended range) content
    var colorProfile: String
    var mirrored: Bool

    var scale: Double { pointsWide > 0 ? Double(pixelsWide) / Double(pointsWide) : 1 }
    var symbol: String { isBuiltin ? "laptopcomputer" : "display" }
}

/// A resolution the display can be set to.
struct DisplayModeChoice: Identifiable, Hashable {
    let id: Int32                               // CGDisplayMode ioDisplayModeID
    let pointsWide: Int, pointsHigh: Int
    let pixelsWide: Int, pixelsHigh: Int
    let refresh: Double
    let isNative: Bool
    let isCurrent: Bool
    var hiDPI: Bool { pixelsWide > pointsWide }

    var title: String {
        var t = "\(pointsWide) × \(pointsHigh)"
        if refresh > 0 { t += String(format: " · %g Hz", refresh.rounded()) }
        if !hiDPI && pixelsWide > 0 { t += " (low resolution)" }
        return t
    }
}

enum Displays {
    /// Every active display, main first.
    static func all() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let names = Dictionary(NSScreen.screens.compactMap { s -> (CGDirectDisplayID, (String, Bool, String)) in
            let n = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return (n, (s.localizedName, s.maximumPotentialExtendedDynamicRangeColorComponentValue > 1,
                        s.colorSpace?.localizedName ?? ""))
        }, uniquingKeysWith: { a, _ in a })
        return ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            let mm = CGDisplayScreenSize(id)
            let diag = mm.width > 0 ? (mm.width * mm.width + mm.height * mm.height).squareRoot() / 25.4 : nil
            let builtin = CGDisplayIsBuiltin(id) != 0
            let n = names[id]
            return DisplayInfo(
                id: id, name: n?.0 ?? (builtin ? "Built-in Display" : "Display"),
                isBuiltin: builtin, isMain: CGDisplayIsMain(id) != 0,
                pointsWide: mode?.width ?? CGDisplayPixelsWide(id), pointsHigh: mode?.height ?? CGDisplayPixelsHigh(id),
                pixelsWide: mode?.pixelWidth ?? CGDisplayPixelsWide(id), pixelsHigh: mode?.pixelHeight ?? CGDisplayPixelsHigh(id),
                refresh: mode?.refreshRate ?? 0,
                diagonalInches: diag.map { (Double($0) * 10).rounded() / 10 },
                vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                rotation: Int(CGDisplayRotation(id)), hdr: n?.1 ?? false, colorProfile: n?.2 ?? "",
                mirrored: CGDisplayIsInMirrorSet(id) != 0)
        }
        .sorted { ($0.isMain ? 0 : 1, $0.isBuiltin ? 0 : 1, $0.id) < ($1.isMain ? 0 : 1, $1.isBuiltin ? 0 : 1, $1.id) }
    }

    // MARK: Resolution

    /// Resolutions usable for the desktop, largest first; duplicates (same
    /// size, scale and refresh) collapsed.
    static func modes(_ id: CGDirectDisplayID) -> [DisplayModeChoice] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let list = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return [] }
        let current = CGDisplayCopyDisplayMode(id)?.ioDisplayModeID
        var seen = Set<String>()
        var out: [DisplayModeChoice] = []
        for m in list where m.isUsableForDesktopGUI() {
            let key = "\(m.width)x\(m.height)@\(m.pixelWidth)@\(Int(m.refreshRate.rounded()))"
            guard seen.insert(key).inserted || m.ioDisplayModeID == current else { continue }
            out.append(DisplayModeChoice(id: m.ioDisplayModeID, pointsWide: m.width, pointsHigh: m.height,
                                         pixelsWide: m.pixelWidth, pixelsHigh: m.pixelHeight, refresh: m.refreshRate,
                                         isNative: m.ioFlags & UInt32(kDisplayModeNativeFlag) != 0,
                                         isCurrent: m.ioDisplayModeID == current))
        }
        return Self.sortedModes(out)
    }

    static func sortedModes(_ list: [DisplayModeChoice]) -> [DisplayModeChoice] {
        list.sorted { a, b in
            if a.pointsWide != b.pointsWide { return a.pointsWide > b.pointsWide }
            if a.hiDPI != b.hiDPI { return a.hiDPI }
            return a.refresh > b.refresh
        }
    }

    /// Switches resolution (kept after restart, like System Settings). nil on success.
    static func setMode(_ choice: DisplayModeChoice, on id: CGDirectDisplayID) -> String? {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let list = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode],
              let mode = list.first(where: { $0.ioDisplayModeID == choice.id }) else { return "That resolution isn’t available any more." }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return "macOS didn’t allow the change." }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        let r = CGCompleteDisplayConfiguration(config, .permanently)
        return r == .success ? nil : "macOS didn’t allow the change (error \(r.rawValue))."
    }
}

// MARK: - Brightness

/// How Apex can change a display's brightness.
enum BrightnessMethod: Equatable, Sendable {
    case native        // Apple displays: macOS's display-brightness service
    case ddc           // other monitors: DDC/CI over the display link (Apple silicon)
    case software      // dims the picture itself (gamma); lasts while Apex runs
    var note: String {
        switch self {
        case .native: return "Controlled by macOS"
        case .ddc: return "Set on the monitor (DDC/CI), like its own buttons"
        case .software: return "This monitor doesn’t accept brightness commands, so Apex dims the picture instead (while Apex is running)."
        }
    }
}

/// Not thread-safe: call from `DisplayStore`'s serial queue (DDC calls block
/// for ~40 ms, so never on the main thread).
enum Brightness {
    nonisolated(unsafe) private static var dimmed: [CGDirectDisplayID: Double] = [:]

    static func method(for d: DisplayInfo) -> BrightnessMethod {
        if NativeBrightness.canChange(d.id) { return .native }
        if DDC.service(for: d) != nil { return .ddc }
        return .software
    }

    /// 0…1, or nil if it can't be read.
    static func get(_ d: DisplayInfo, _ method: BrightnessMethod) -> Double? {
        switch method {
        case .native: return NativeBrightness.get(d.id)
        case .ddc:
            guard let s = DDC.service(for: d), let v = DDC.read(s, code: DDC.brightness), v.max > 0 else { return nil }
            return Double(v.current) / Double(v.max)
        case .software: return dimmed[d.id] ?? 1
        }
    }

    /// Sets 0…1. nil on success.
    static func set(_ value: Double, on d: DisplayInfo, _ method: BrightnessMethod) -> String? {
        let v = max(0, min(1, value))
        switch method {
        case .native:
            return NativeBrightness.set(d.id, v) ? nil : "macOS didn’t accept the change."
        case .ddc:
            guard let s = DDC.service(for: d) else { return "The monitor stopped answering." }
            let max = DDC.read(s, code: DDC.brightness)?.max ?? 100
            return DDC.write(s, code: DDC.brightness, value: UInt16((Double(max) * v).rounded()))
                ? nil : "The monitor didn’t accept the change."
        case .software:
            // Never fully black: the floor keeps the screen readable.
            let level = 0.15 + 0.85 * v
            dimmed[d.id] = v
            let r = CGSetDisplayTransferByFormula(d.id, 0, Float(level), 1, 0, Float(level), 1, 0, Float(level), 1)
            return r == .success ? nil : "macOS didn’t allow dimming this display."
        }
    }
}

/// Apple displays, through the private DisplayServices framework (loaded at
/// runtime; if it's missing, Apex falls back to the other methods).
enum NativeBrightness {
    private typealias CanFn = @convention(c) (UInt32) -> Bool
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static func fn<T>(_ name: String, _: T.Type) -> T? {
        guard let lib, let p = dlsym(lib, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let canFn = fn("DisplayServicesCanChangeBrightness", CanFn.self)
    private static let getFn = fn("DisplayServicesGetBrightness", GetFn.self)
    private static let setFn = fn("DisplayServicesSetBrightness", SetFn.self)

    static func canChange(_ id: CGDirectDisplayID) -> Bool {
        guard let canFn, getFn != nil, setFn != nil else { return false }
        return canFn(id)
    }
    static func get(_ id: CGDirectDisplayID) -> Double? {
        var v: Float = 0
        guard let getFn, getFn(id, &v) == 0 else { return nil }
        return Double(v)
    }
    static func set(_ id: CGDirectDisplayID, _ v: Double) -> Bool {
        guard let setFn else { return false }
        return setFn(id, Float(v)) == 0
    }
}

/// DDC/CI (VESA Monitor Control Command Set) over the display link on Apple
/// silicon, through IOKit's AV service (functions looked up at runtime).
enum DDC {
    static let brightness: UInt8 = 0x10
    static let contrast: UInt8 = 0x12

    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(p, to: T.self)
    }
    private static let create = sym("IOAVServiceCreateWithService", CreateFn.self)
    private static let readI2C = sym("IOAVServiceReadI2C", I2CFn.self)
    private static let writeI2C = sym("IOAVServiceWriteI2C", I2CFn.self)

    nonisolated(unsafe) private static var cache: [CGDirectDisplayID: CFTypeRef] = [:]
    nonisolated(unsafe) private static var noAnswer = Set<CGDirectDisplayID>()

    /// The AV service for an external display, if it answers DDC.
    static func service(for d: DisplayInfo) -> CFTypeRef? {
        guard !d.isBuiltin, create != nil, readI2C != nil, writeI2C != nil else { return nil }
        if let s = cache[d.id] { return s }
        if noAnswer.contains(d.id) { return nil }
        let candidates = externalServices()
        defer { candidates.forEach { IOObjectRelease($0.service) } }   // the AV service keeps its own reference
        // Match on the vendor / product the display reports; with one external
        // display, that one.
        let match = candidates.first { $0.vendor == d.vendor && $0.product == d.model }
            ?? (candidates.count == 1 ? candidates.first : nil)
        guard let entry = match, let s = create?(kCFAllocatorDefault, entry.service)?.takeRetainedValue(),
              read(s, code: brightness) != nil else {
            noAnswer.insert(d.id)
            return nil
        }
        cache[d.id] = s
        return s
    }

    /// Forget cached services (displays changed).
    static func reset() { cache.removeAll(); noAnswer.removeAll() }

    private struct Candidate { let service: io_service_t; let vendor: UInt32; let product: UInt32 }

    private static func externalServices() -> [Candidate] {
        var out: [Candidate] = []
        IOKitUtil.forEach(matching: "DCPAVServiceProxy") { e in
            guard (IOKitUtil.property(e, "Location") as? String) == "External" else { return }
            var vendor: UInt32 = 0, product: UInt32 = 0
            // The display's identity lives in a "DisplayAttributes" dictionary on a
            // nearby node of the same display pipe: search up to a few levels up.
            var node = e
            IOObjectRetain(node)
            for _ in 0..<4 {
                if let attrs = IORegistryEntrySearchCFProperty(node, kIOServicePlane, "DisplayAttributes" as CFString, nil,
                                                               IOOptionBits(kIORegistryIterateRecursively)) as? [String: Any],
                   let p = attrs["ProductAttributes"] as? [String: Any] {
                    vendor = (p["LegacyManufacturerID"] as? NSNumber)?.uint32Value ?? 0
                    product = (p["ProductID"] as? NSNumber)?.uint32Value ?? 0
                    break
                }
                var parent: io_registry_entry_t = 0
                guard IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
                IOObjectRelease(node)
                node = parent
            }
            IOObjectRelease(node)
            IOObjectRetain(e)
            out.append(Candidate(service: e, vendor: vendor, product: product))
        }
        return out
    }

    // MARK: Protocol

    static let hostAddress: UInt8 = 0x51
    static let displayAddress: UInt32 = 0x37

    /// Checksum: XOR of the destination address (0x6E), the source (0x51) and the payload.
    static func checksum(_ bytes: [UInt8]) -> UInt8 { bytes.reduce(0x6E ^ hostAddress, ^) }

    static func setPacket(code: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(body)]
    }

    static func getPacket(code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code]
        return body + [checksum(body)]
    }

    /// Reply to "get VCP feature": (current, max), or nil if it's not a valid answer.
    static func parseReply(_ r: [UInt8], code: UInt8) -> (current: UInt16, max: UInt16)? {
        guard r.count >= 11, r[2] == 0x02, r[3] == 0x00, r[4] == code else { return nil }
        let max = UInt16(r[6]) << 8 | UInt16(r[7])
        let cur = UInt16(r[8]) << 8 | UInt16(r[9])
        return (cur, max)
    }

    static func write(_ s: CFTypeRef, code: UInt8, value: UInt16) -> Bool {
        guard let writeI2C else { return false }
        var p = setPacket(code: code, value: value)
        // Some monitors miss the first command; sending it twice is the usual practice.
        var ok = false
        for _ in 0..<2 {
            if writeI2C(s, displayAddress, UInt32(hostAddress), &p, UInt32(p.count)) == kIOReturnSuccess { ok = true }
            usleep(10_000)
        }
        return ok
    }

    static func read(_ s: CFTypeRef, code: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let readI2C, let writeI2C else { return nil }
        for _ in 0..<3 {
            var q = getPacket(code: code)
            guard writeI2C(s, displayAddress, UInt32(hostAddress), &q, UInt32(q.count)) == kIOReturnSuccess else { continue }
            usleep(40_000)          // the standard asks for 40 ms before reading the reply
            var r = [UInt8](repeating: 0, count: 12)
            guard readI2C(s, displayAddress, UInt32(hostAddress), &r, UInt32(r.count)) == kIOReturnSuccess else { continue }
            if let v = parseReply(r, code: code) { return v }
        }
        return nil
    }
}
