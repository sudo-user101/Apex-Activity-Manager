import Foundation
import IOBluetooth
import IOKit
import IOUSBHost

/// Stop and resume accessories without unplugging them, where macOS allows it:
///  * USB drives: unmount (the drive stays attached, goes idle, stops reading
///    and writing) and mount again; a drive that was *ejected* is brought back
///    by re-detecting it on USB (like unplugging and plugging it in);
///  * Bluetooth devices: disconnect and reconnect (they stay paired).
/// Other USB devices (keyboards, webcams, hubs) can't be paused by apps, and
/// no Mac lets apps cut a USB port's power.
enum AccessoryControl {
    // MARK: Drives

    /// Unmounts every volume on the drive; it stays connected. nil on success.
    static func stopDrive(_ disk: String) -> String? {
        let r = Shell.run("/usr/sbin/diskutil", ["unmountDisk", "/dev/" + disk])
        if r.status == 0 { return nil }
        let msg = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.localizedCaseInsensitiveContains("in use") || msg.localizedCaseInsensitiveContains("dissented")
            ? "Something is still using the drive. Close files or apps using it, then try again."
            : "Couldn’t stop the drive: " + String(msg.suffix(200))
    }

    /// Mounts the drive's volumes again. nil on success.
    static func resumeDrive(_ disk: String) -> String? {
        let r = Shell.run("/usr/sbin/diskutil", ["mountDisk", "/dev/" + disk])
        if r.status == 0 { return nil }
        let msg = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return "Couldn’t resume the drive: " + String(msg.suffix(200))
    }

    /// USB serial numbers of devices that are drives (a mass-storage interface).
    static func massStorageSerials() -> Set<String> {
        var out = Set<String>()
        IOKitUtil.forEach(matching: "IOUSBHostDevice") { dev in
            guard let sn = IOKitUtil.property(dev, "USB Serial Number") as? String, !sn.isEmpty else { return }
            var it: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(dev, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(it) }
            while case let child = IOIteratorNext(it), child != 0 {
                defer { IOObjectRelease(child) }
                if (IOKitUtil.property(child, "bInterfaceClass") as? NSNumber)?.intValue == 8 { out.insert(sn); break }
            }
        }
        return out
    }

    /// Re-detects a USB device (as if it were unplugged and plugged back in),
    /// which brings back an ejected drive. No admin rights needed. nil on success.
    static func reconnect(serial: String) -> String? {
        var target: io_service_t = 0
        IOKitUtil.forEach(matching: "IOUSBHostDevice") { dev in
            if target == 0, IOKitUtil.property(dev, "USB Serial Number") as? String == serial { IOObjectRetain(dev); target = dev }
        }
        guard target != 0 else { return "The device isn’t connected any more." }
        defer { IOObjectRelease(target) }
        do {
            let dev = try IOUSBHostDevice(__ioService: target, options: [], queue: nil, interestHandler: nil)
            defer { dev.destroy() }
            try dev.reset()
            return nil
        } catch {
            return "Couldn’t reconnect it: \(error.localizedDescription). Unplug it and plug it back in."
        }
    }

    // MARK: Bluetooth

    struct BluetoothDevice: Identifiable, Hashable, Sendable {
        var id: String { address }
        let address: String
        let name: String
        let connected: Bool
        let kind: String        // "Audio", "Keyboard", "Mouse"…
    }

    /// Paired devices and whether each is connected right now.
    static func bluetoothDevices() -> [BluetoothDevice] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.map { d in
            BluetoothDevice(address: d.addressString ?? "", name: d.name ?? d.addressString ?? "Bluetooth device",
                            connected: d.isConnected(), kind: kind(major: d.deviceClassMajor, minor: d.deviceClassMinor))
        }
        .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }

    /// Disconnects (on = false) or reconnects a paired device. nil on success.
    static func setBluetooth(_ on: Bool, address: String) -> String? {
        guard let d = IOBluetoothDevice(addressString: address) else { return "That device isn’t paired any more." }
        let r = on ? d.openConnection() : d.closeConnection()
        if r == kIOReturnSuccess { return nil }
        return on ? "Couldn’t connect. Make sure the device is switched on and nearby."
                  : "Couldn’t disconnect it (error \(r))."
    }

    private static func kind(major: BluetoothDeviceClassMajor, minor: BluetoothDeviceClassMinor) -> String {
        switch Int(major) {
        case kBluetoothDeviceClassMajorAudio: return "Audio"
        case kBluetoothDeviceClassMajorPeripheral:
            if minor & 0x10 != 0 && minor & 0x20 == 0 { return "Keyboard" }
            if minor & 0x20 != 0 { return "Mouse or trackpad" }
            return "Input device"
        case kBluetoothDeviceClassMajorPhone: return "Phone"
        case kBluetoothDeviceClassMajorComputer: return "Computer"
        case kBluetoothDeviceClassMajorWearable: return "Wearable"
        default: return "Device"
        }
    }
}
