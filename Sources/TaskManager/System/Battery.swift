import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

struct BatteryInfo: Sendable {
    var present = false
    var percent = 0
    var isCharging = false
    var onAC = false
    var fullyCharged = false
    var minutesRemaining: Int?       // to empty, or to full when charging
    var cycleCount = 0
    var designCycles = 0
    var designCapacity = 0           // mAh
    var maxCapacity = 0              // mAh (current full charge)
    var temperature: Double?         // °C
    var voltage: Double = 0          // V
    var amperage: Double = 0         // A (negative = discharging)
    var systemPower: Double?         // W, whole Mac (PowerTelemetryData)
    var adapterWatts: Int?
    var adapterName: String?
    var condition = ""

    var health: Double { designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) * 100 : 0 }
    var batteryPower: Double { abs(voltage * amperage) }
}

struct BluetoothBattery: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let percent: Int
}

enum Battery {
    static func read() -> BatteryInfo {
        var b = BatteryInfo()
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return b }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return b }
        func int(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        b.present = (d["BatteryInstalled"] as? Bool) ?? true
        b.isCharging = (d["IsCharging"] as? Bool) ?? false
        b.onAC = (d["ExternalConnected"] as? Bool) ?? false
        b.fullyCharged = (d["FullyCharged"] as? Bool) ?? false
        b.cycleCount = int("CycleCount") ?? 0
        b.designCycles = int("DesignCycleCount9C") ?? 1000
        b.designCapacity = int("DesignCapacity") ?? 0
        b.maxCapacity = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? 0
        let raw = int("AppleRawCurrentCapacity") ?? 0
        b.percent = int("CurrentCapacity").map { $0 <= 100 ? $0 : (b.maxCapacity > 0 ? raw * 100 / b.maxCapacity : 0) } ?? 0
        if let t = int("Temperature") { b.temperature = Double(t) / 100 }
        b.voltage = Double(int("Voltage") ?? 0) / 1000
        b.amperage = Double(int("InstantAmperage") ?? int("Amperage") ?? 0) / 1000
        if let tr = int(b.isCharging ? "AvgTimeToFull" : "AvgTimeToEmpty"), tr > 0, tr < 6000 { b.minutesRemaining = tr }
        if let pt = d["PowerTelemetryData"] as? [String: Any], let load = (pt["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
            b.systemPower = load / 1000
        }
        if let a = d["AdapterDetails"] as? [String: Any] {
            b.adapterWatts = (a["Watts"] as? NSNumber)?.intValue
            b.adapterName = a["Name"] as? String
        }
        // Condition, as System Settings words it.
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                if let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                   let health = desc[kIOPSBatteryHealthKey] as? String {
                    b.condition = health == "Good" ? "Normal" : health
                }
            }
        }
        if b.condition.isEmpty { b.condition = b.health >= 80 ? "Normal" : "Service recommended" }
        return b
    }

    /// Battery levels of connected Bluetooth keyboards, mice and trackpads.
    static func bluetooth() -> [BluetoothBattery] {
        var out: [String: Int] = [:]
        for cls in ["IOHIDDevice", "AppleDeviceManagementHIDEventService"] {
            IOKitUtil.forEach(matching: cls) { s in
                guard let pct = (IOKitUtil.property(s, "BatteryPercent") as? NSNumber)?.intValue,
                      let name = IOKitUtil.property(s, "Product") as? String else { return }
                out[name] = pct
            }
        }
        return out.map { BluetoothBattery(name: $0.key, percent: $0.value) }.sorted { $0.name < $1.name }
    }
}

/// Which processes are keeping the Mac (or its display) awake.
enum SleepAssertions {
    static func byProcess() -> [pid_t: [String]] {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let d = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [:] }
        var out: [pid_t: [String]] = [:]
        for (pid, list) in d {
            let types = list.compactMap { $0["AssertType"] as? String }
                .filter { $0.contains("PreventUserIdle") || $0.contains("NoIdleSleep") || $0.contains("NoDisplaySleep") || $0 == "PreventSystemSleep" }
            if !types.isEmpty { out[pid.int32Value] = types }
        }
        return out
    }
}
