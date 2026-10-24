import AppKit
import DiskArbitration
import Foundation
import IOKit
import SystemConfiguration

// Storage and network devices that come and go (USB / Thunderbolt drives,
// SD cards, second internal drives, USB / Thunderbolt network adapters,
// iPhone tethering). Each one gets its own Performance page.
//
// Topology (which devices exist, their names and volumes) is rescanned only
// when IOKit or the workspace says something changed, plus a slow fallback.
// Counters are read every tick from the same IOKit / sysctl sources as the
// whole-Mac numbers, so there is no extra polling.

struct VolumeInfo: Sendable, Hashable {
    var name: String
    var path: String
    var capacity: UInt64
    var available: UInt64
    var format: String
}

/// The USB standard a device supports and the speed it's actually running at.
struct USBLink: Sendable, Hashable {
    var speed: Int          // IOUSBHostDevice "Device Speed": 0 low … 3 SuperSpeed, 4 SuperSpeed+ 10G, 5 20G
    var bcdUSB: Int         // the USB version the device declares, e.g. 0x0320

    /// The standard it's connected at, e.g. "USB 3.2 Gen 1 (5 Gb/s)".
    var connectedAs: String {
        switch speed {
        case 0: return "USB 1.0 (1.5 Mb/s)"
        case 1: return "USB 1.1 (12 Mb/s)"
        case 2: return "USB 2.0 (480 Mb/s)"
        case 3: return "USB 3.2 Gen 1 (5 Gb/s)"
        case 4: return "USB 3.2 Gen 2 (10 Gb/s)"
        case 5: return "USB 3.2 Gen 2×2 (20 Gb/s)"
        default: return "USB 4 or newer"
        }
    }
    var short: String {
        switch speed {
        case 0, 1: return "USB 1.1"
        case 2: return "USB 2.0"
        case 3: return "USB 3.2 Gen 1"
        case 4: return "USB 3.2 Gen 2"
        case 5: return "USB 3.2 Gen 2×2"
        default: return "USB 4"
        }
    }
    /// The version the device itself supports, from bcdUSB (BCD: 0x0320 = 3.2).
    var supports: String {
        let major = (bcdUSB >> 8) & 0xFF, minor = (bcdUSB >> 4) & 0xF
        guard major > 0 else { return "" }
        if major >= 4 { return "USB4" }
        return minor == 0 ? "USB \(major).0" : "USB \(major).\(minor)"
    }
    /// A USB 3 device running at USB 2 speed (wrong port, hub or cable).
    var slowerThanItCould: Bool { bcdUSB >= 0x0300 && speed <= 2 }

    /// Finds the USB device above an IOKit entry, if any.
    static func above(_ entry: io_registry_entry_t) -> USBLink? {
        var e = entry
        IOObjectRetain(e)
        defer { if e != 0 { IOObjectRelease(e) } }
        for _ in 0..<40 {
            if IOObjectConformsTo(e, "IOUSBHostDevice") != 0 || IOObjectConformsTo(e, "IOUSBDevice") != 0 {
                let speed = (IOKitUtil.property(e, "Device Speed") as? NSNumber)?.intValue ?? -1
                let bcd = (IOKitUtil.property(e, "bcdUSB") as? NSNumber)?.intValue ?? 0
                return speed >= 0 ? USBLink(speed: speed, bcdUSB: bcd) : nil
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(e, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(e)
            e = parent
        }
        return nil
    }
}

/// Raw cumulative driver counters used for health (response time, errors).
/// Not every driver reports time and errors; USB sticks usually don't.
struct DriveIO: Sendable, Hashable {
    var readOps: UInt64 = 0, writeOps: UInt64 = 0
    var readTimeNs: UInt64 = 0, writeTimeNs: UInt64 = 0
    var errors: UInt64 = 0, retries: UInt64 = 0
    var hasTiming = false
    var hasErrors = false
}

struct StorageDevice: Sendable, Identifiable, Hashable {
    var id: String               // whole-disk BSD name, e.g. "disk6"
    var name: String             // first volume's name, else the model
    var model: String
    var connection: String       // "USB", "Thunderbolt", "SD card", "Internal"…
    var isInternal: Bool
    var ejectable: Bool
    var size: UInt64
    var volumes: [VolumeInfo]
    var registryID: UInt64
    var usb: USBLink? = nil
    // Live values (filled per tick)
    var readPerSec: Double = 0
    var writePerSec: Double = 0
    var readOpsPerSec: Double = 0
    var writeOpsPerSec: Double = 0
    var totalRead: UInt64 = 0
    var totalWritten: UInt64 = 0
    var totalReadOps: UInt64 = 0
    var totalWriteOps: UInt64 = 0
    var io = DriveIO()
    var serial = ""
    var capacity: UInt64 { volumes.reduce(0) { $0 + $1.capacity } }
    var available: UInt64 { volumes.reduce(0) { $0 + $1.available } }
}

struct NetworkDevice: Sendable, Identifiable, Hashable {
    var id: String               // BSD name, e.g. "en7"
    var name: String             // "USB 10/100/1000 LAN", "iPhone USB"
    var connection: String       // "USB" / "Thunderbolt"
    var kind: String             // "Ethernet", "Wi-Fi"…
    var hardwareAddress: String
    var usb: USBLink? = nil
    // Live values
    var inPerSec: Double = 0
    var outPerSec: Double = 0
    var totalIn: UInt64 = 0
    var totalOut: UInt64 = 0
    var linkSpeed: UInt64 = 0    // bits/s, 0 = unknown
    var isUp = false
    var address = ""
}

/// Bumps a generation counter whenever a drive, volume or network interface
/// appears or disappears, so the sampler knows to rescan.
final class DeviceWatcher: @unchecked Sendable {
    static let shared = DeviceWatcher()
    private let lock = NSLock()
    private var gen = 1
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var observers: [NSObjectProtocol] = []

    var generation: Int { lock.lock(); defer { lock.unlock() }; return gen }
    func bump() { lock.lock(); gen &+= 1; lock.unlock() }

    @MainActor func start() {
        guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        IONotificationPortSetDispatchQueue(p, .main)
        let callback: IOServiceMatchingCallback = { _, it in
            while case let o = IOIteratorNext(it), o != 0 { IOObjectRelease(o) }   // drain to re-arm
            DeviceWatcher.shared.bump()
            // Volumes mount a moment after the drive appears; check again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { DeviceWatcher.shared.bump() }
        }
        for cls in ["IOBlockStorageDriver", "IOMedia", "IONetworkInterface"] {
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var it: io_iterator_t = 0
                if IOServiceAddMatchingNotification(p, type, IOServiceMatching(cls), callback, nil, &it) == KERN_SUCCESS {
                    while case let o = IOIteratorNext(it), o != 0 { IOObjectRelease(o) }
                    iterators.append(it)
                }
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { _ in DeviceWatcher.shared.bump() })
        }
    }
}

/// Finds devices and reads their counters. Owned by the sampler's queue.
final class DeviceScanner {
    private let session = DASessionCreate(kCFAllocatorDefault)
    private var seenGeneration = 0
    private var ticksSinceScan = 0
    private(set) var bootDriverID: UInt64 = 0
    private var storage: [StorageDevice] = []
    private var network: [NetworkDevice] = []
    private var previousDisk: [UInt64: (r: UInt64, w: UInt64, ro: UInt64, wo: UInt64)] = [:]
    private var previousNet: [String: (rx: UInt64, tx: UInt64)] = [:]

    /// Rescans topology if anything changed (or every 30 ticks as a fallback).
    func refreshIfNeeded() {
        let g = DeviceWatcher.shared.generation
        ticksSinceScan += 1
        guard g != seenGeneration || ticksSinceScan >= 30 else { return }
        seenGeneration = g
        ticksSinceScan = 0
        scanStorage()
        scanNetwork()
    }

    // MARK: Storage

    private func scanStorage() {
        guard let session else { return }
        // Which driver holds the startup volume ("Disk" page).
        bootDriverID = driverID(forVolume: URL(fileURLWithPath: "/")) ?? 0

        var found: [UInt64: StorageDevice] = [:]
        IOKitUtil.forEach(matching: "IOBlockStorageDriver") { drv in
            let rid = Self.registryID(drv)
            guard rid != bootDriverID, let bsd = Self.wholeMediaBSDName(drv),
                  let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
                  let d = DADiskCopyDescription(disk) as? [String: Any] else { return }
            let proto = d[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
            let model = (d[kDADiskDescriptionDeviceModelKey as String] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let vendor = (d[kDADiskDescriptionDeviceVendorKey as String] as? String ?? "").trimmingCharacters(in: .whitespaces)
            // Disk images (.dmg, simulator runtimes) live on another drive: not a device.
            let isImage = proto == "Virtual Interface" || proto == "Disk Image" || model == "Disk Image"
            // APEX_SHOW_DISK_IMAGES=1 lists them anyway (for testing device pages without hardware).
            if isImage && !Self.showImages { return }
            let isInt = d[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? false
            let ejectable = (d[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false)
                || (d[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false)
            let size = (d[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0
            found[rid] = StorageDevice(
                id: bsd, name: "", model: [vendor, model].filter { !$0.isEmpty }.joined(separator: " "),
                connection: isImage ? "Disk image" : Self.connectionName(proto, internal: isInt), isInternal: isInt, ejectable: ejectable,
                size: size, volumes: [], registryID: rid, usb: USBLink.above(drv),
                serial: Self.usbSerial(above: drv) ?? "")
        }
        // Attach mounted volumes to their drive.
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeLocalizedFormatDescriptionKey]
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard let rid = driverID(forVolume: url), found[rid] != nil,
                  let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            found[rid]!.volumes.append(VolumeInfo(
                name: v.volumeLocalizedName ?? url.lastPathComponent, path: url.path,
                capacity: UInt64(v.volumeTotalCapacity ?? 0), available: UInt64(v.volumeAvailableCapacity ?? 0),
                format: v.volumeLocalizedFormatDescription ?? ""))
        }
        storage = found.values.map { d in
            var d = d
            d.volumes.sort { $0.name < $1.name }
            d.name = d.volumes.first?.name ?? (d.model.isEmpty ? "External Drive" : d.model)
            return d
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// The IOBlockStorageDriver under a mounted volume (works through APFS containers).
    private func driverID(forVolume url: URL) -> UInt64? {
        guard let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let b = DADiskGetBSDName(disk) else { return nil }
        var e = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, b))
        var depth = 0
        while e != 0 && depth < 32 {
            if IOObjectConformsTo(e, "IOBlockStorageDriver") != 0 { let id = Self.registryID(e); IOObjectRelease(e); return id }
            var parent: io_registry_entry_t = 0
            let r = IORegistryEntryGetParentEntry(e, kIOServicePlane, &parent)
            IOObjectRelease(e)
            e = r == KERN_SUCCESS ? parent : 0
            depth += 1
        }
        if e != 0 { IOObjectRelease(e) }
        return nil
    }

    static let showImages = ProcessInfo.processInfo.environment["APEX_SHOW_DISK_IMAGES"] == "1"

    static func connectionName(_ proto: String, internal isInt: Bool) -> String {
        switch proto {
        case "USB": return "USB"
        case "Thunderbolt": return "Thunderbolt"
        case "PCI-Express" where !isInt: return "Thunderbolt"
        case "Secure Digital": return "SD card"
        case "SATA": return isInt ? "Internal (SATA)" : "SATA"
        case "FireWire": return "FireWire"
        default: return isInt ? "Internal" : (proto.isEmpty ? "External" : proto)
        }
    }

    /// USB serial number (stable across plug-ins and reformatting), if any.
    static func usbSerial(above entry: io_registry_entry_t) -> String? {
        var e = entry
        IOObjectRetain(e)
        defer { if e != 0 { IOObjectRelease(e) } }
        for _ in 0..<40 {
            if IOObjectConformsTo(e, "IOUSBHostDevice") != 0 {
                return (IOKitUtil.property(e, "kUSBSerialNumberString") ?? IOKitUtil.property(e, "USB Serial Number")) as? String
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(e, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(e); e = parent
        }
        return nil
    }

    private static func registryID(_ e: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0; IORegistryEntryGetRegistryEntryID(e, &id); return id
    }

    private static func wholeMediaBSDName(_ drv: io_registry_entry_t) -> String? {
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(drv, kIOServicePlane, &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var name: String?
        while case let c = IOIteratorNext(it), c != 0 {
            if name == nil, IOObjectConformsTo(c, "IOMedia") != 0, (IOKitUtil.property(c, "Whole") as? Bool) == true {
                name = IOKitUtil.property(c, "BSD Name") as? String
            }
            IOObjectRelease(c)
        }
        return name
    }

    /// One pass over every block storage driver: the startup drive's counters
    /// (for the Disk page) and each device's live rates.
    func readStorage(seconds secs: Double) -> (boot: (r: UInt64, w: UInt64, ro: UInt64, wo: UInt64)?, bootIO: DriveIO, devices: [StorageDevice]) {
        var counters: [UInt64: (r: UInt64, w: UInt64, ro: UInt64, wo: UInt64)] = [:]
        var ios: [UInt64: DriveIO] = [:]
        IOKitUtil.forEach(matching: "IOBlockStorageDriver") { drv in
            guard let st = IOKitUtil.property(drv, "Statistics") as? [String: Any] else { return }
            func v(_ k: String) -> UInt64 { (st[k] as? NSNumber)?.uint64Value ?? 0 }
            let id = Self.registryID(drv)
            counters[id] = (v("Bytes (Read)"), v("Bytes (Write)"), v("Operations (Read)"), v("Operations (Write)"))
            ios[id] = DriveIO(readOps: v("Operations (Read)"), writeOps: v("Operations (Write)"),
                              readTimeNs: v("Total Time (Read)"), writeTimeNs: v("Total Time (Write)"),
                              errors: v("Errors (Read)") &+ v("Errors (Write)"), retries: v("Retries (Read)") &+ v("Retries (Write)"),
                              hasTiming: st["Total Time (Read)"] != nil, hasErrors: st["Errors (Read)"] != nil)
        }
        var out = storage
        for i in out.indices {
            guard let c = counters[out[i].registryID] else { continue }
            out[i].totalRead = c.r; out[i].totalWritten = c.w; out[i].totalReadOps = c.ro; out[i].totalWriteOps = c.wo
            out[i].io = ios[out[i].registryID] ?? DriveIO()
            if let p = previousDisk[out[i].registryID], secs > 0 {
                func r(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) / secs : 0 }
                out[i].readPerSec = r(c.r, p.r); out[i].writePerSec = r(c.w, p.w)
                out[i].readOpsPerSec = r(c.ro, p.ro); out[i].writeOpsPerSec = r(c.wo, p.wo)
            }
        }
        previousDisk = counters
        return (counters[bootDriverID], ios[bootDriverID] ?? DriveIO(), out)
    }

    // MARK: Network

    private func scanNetwork() {
        var names: [String: (name: String, kind: String, mac: String)] = [:]
        for i in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
            names[bsd] = (SCNetworkInterfaceGetLocalizedDisplayName(i) as String? ?? bsd,
                          Self.kindName(SCNetworkInterfaceGetInterfaceType(i) as String?),
                          SCNetworkInterfaceGetHardwareAddressString(i) as String? ?? "")
        }
        var out: [NetworkDevice] = []
        IOKitUtil.forEach(matching: "IONetworkInterface") { nif in
            guard let bsd = IOKitUtil.property(nif, "BSD Name") as? String,
                  let connection = Self.externalConnection(nif) else { return }
            let n = names[bsd]
            out.append(NetworkDevice(id: bsd, name: n?.name ?? bsd, connection: connection,
                                     kind: n?.kind ?? "Network", hardwareAddress: n?.mac ?? "", usb: USBLink.above(nif)))
        }
        network = out.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// "USB" / "Thunderbolt" if the interface hangs off a plugged-in device;
    /// nil for built-in ports and virtual interfaces.
    private static func externalConnection(_ nif: io_registry_entry_t) -> String? {
        var e = nif
        IOObjectRetain(e)
        var depth = 0
        var result: String?
        while e != 0 && depth < 40 {
            if IOObjectConformsTo(e, "IOUSBHostDevice") != 0 || IOObjectConformsTo(e, "IOUSBDevice") != 0 { result = "USB" }
            if (IOKitUtil.property(e, "IOPCITunnelled") as? Bool) == true { result = result ?? "Thunderbolt" }
            var parent: io_registry_entry_t = 0
            let r = IORegistryEntryGetParentEntry(e, kIOServicePlane, &parent)
            IOObjectRelease(e)
            e = r == KERN_SUCCESS ? parent : 0
            depth += 1
        }
        if e != 0 { IOObjectRelease(e) }
        return result
    }

    static func kindName(_ t: String?) -> String {
        switch t {
        case "IEEE80211"?: return "Wi-Fi"
        case "Ethernet"?: return "Ethernet"
        case "Bluetooth"?: return "Bluetooth"
        case "Modem"?, "WWAN"?: return "Cellular"
        default: return "Network"
        }
    }

    /// Live rates for each plugged-in interface from the per-interface counters.
    func readNetwork(_ perInterface: [String: InterfaceCounters], seconds secs: Double) -> [NetworkDevice] {
        var out = network
        var store: SCDynamicStore?
        for i in out.indices {
            guard let c = perInterface[out[i].id] else { continue }
            out[i].totalIn = c.rx; out[i].totalOut = c.tx; out[i].linkSpeed = c.baud; out[i].isUp = c.up
            if let p = previousNet[out[i].id], secs > 0 {
                out[i].inPerSec = c.rx >= p.rx ? Double(c.rx - p.rx) / secs : 0
                out[i].outPerSec = c.tx >= p.tx ? Double(c.tx - p.tx) / secs : 0
            }
            if store == nil { store = SCDynamicStoreCreate(nil, "Apex" as CFString, nil, nil) }
            if let store, let a = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(out[i].id)/IPv4" as CFString) as? [String: Any] {
                out[i].address = (a["Addresses"] as? [String])?.first ?? ""
            }
        }
        previousNet = perInterface.mapValues { ($0.rx, $0.tx) }
        return out
    }
}

struct InterfaceCounters { var rx: UInt64; var tx: UInt64; var baud: UInt64; var up: Bool }

/// Ejecting a drive (all its volumes).
enum DeviceActions {
    @MainActor static func eject(_ d: StorageDevice) -> String? {
        guard let v = d.volumes.first else { return "Nothing on this drive is mounted." }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: v.path))
            DeviceWatcher.shared.bump()
            return nil
        } catch {
            return "Couldn’t eject “\(d.name)”: \(error.localizedDescription) Quit apps that are using it and try again."
        }
    }
}
