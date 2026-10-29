import AppKit
import ApplicationServices
import Carbon.HIToolbox
import AudioToolbox
import CoreAudio

/// MacOSX Change behaviours that act on windows, the Dock, the microphone,
/// screen brightness and the volume: started and stopped by `InputTweaks.apply`.
/// Window and Dock work goes through Accessibility; the shortcuts are global
/// hot keys (they work in every app and nothing else gets them).
@MainActor
enum WindowTweaks {
    private static var headphoneTimer: Timer?
    private static var lastOutput: (device: AudioObjectID, headphones: Bool)?

    // MARK: Options

    static var brightnessKeys: String { UserDefaults.standard.string(forKey: MacBehaviours.key("keys.brightness") + ".keys") ?? "optCmd" }
    static var headphonePercent: Int {
        let v = UserDefaults.standard.integer(forKey: MacBehaviours.key("sys.headphoneVolume") + ".percent")
        return v > 0 ? v : 40
    }

    static func apply(_ on: Set<String>) {
        let cmd = UInt32(cmdKey), optCmd = UInt32(optionKey | cmdKey)
        let bMods = brightnessKeys == "cmd" ? cmd : optCmd
        let bright = on.contains("keys.brightness")
        _ = HotKeyCenter.set(id: 21, combo: bright ? (UInt32(kVK_UpArrow), bMods) : nil) { stepBrightness(+1) }
        _ = HotKeyCenter.set(id: 22, combo: bright ? (UInt32(kVK_DownArrow), bMods) : nil) { stepBrightness(-1) }

        _ = HotKeyCenter.set(id: 20, combo: on.contains("sys.micMute") ? (UInt32(kVK_ANSI_M), UInt32(optionKey)) : nil) { toggleMicrophone() }

        headphoneTimer?.invalidate(); headphoneTimer = nil
        if on.contains("sys.headphoneVolume") {
            lastOutput = currentOutput()
            headphoneTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { WindowTweaks.checkHeadphones() }
            }
        }
    }

    // MARK: Dock clicks

    /// A click on the front app's Dock icon: its windows minimize; clicked
    /// again, they come back. True when the click was used (the Dock doesn't get it).
    static func dockClick(at point: CGPoint) -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let front = NSWorkspace.shared.frontmostApplication, let frontURL = front.bundleURL else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let item = hit else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid(item, &pid)
        guard pid == dock.processIdentifier, string(item, kAXSubroleAttribute) == "AXApplicationDockItem" else { return false }
        var url: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &url)
        guard let itemURL = url as? URL, itemURL.standardizedFileURL.path == frontURL.standardizedFileURL.path else { return false }

        let windows = standardWindows(front.processIdentifier)
        guard !windows.isEmpty else { return false }
        let minimized = windows.map { bool($0, kAXMinimizedAttribute) }
        if minimized.contains(false) {
            for w in windows { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        } else {
            for w in windows { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            front.activate()
        }
        return true
    }

    private static func standardWindows(_ pid: pid_t) -> [AXUIElement] {
        var list: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &list)
        return ((list as? [AXUIElement]) ?? []).filter { string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String }
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v as? String : nil
    }

    private static func bool(_ e: AXUIElement, _ attr: String) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? (v as? Bool ?? false) : false
    }

    // MARK: Brightness keys

    /// One step (1/16) up or down on the display under the pointer.
    static func stepBrightness(_ direction: Double) {
        let store = DisplayStore.shared
        if store.displays.isEmpty { store.reload() }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let d = store.displays.first(where: { $0.id == id }) ?? store.displays.first(where: \.isMain) else { return }
        guard let now = store.brightness[d.id] else { store.reload(); return }
        let next = steppedBrightness(now, direction)
        store.setBrightness(next, for: d)
        QuitReminder.show("Brightness \(Int((next * 100).rounded()))%", plain: true)
    }

    /// The next brightness step, kept within 0…1. Pure: tested.
    nonisolated static func steppedBrightness(_ now: Double, _ direction: Double) -> Double {
        let step = 1.0 / 16
        return min(1, max(0, ((now / step).rounded() + direction) * step))
    }

    // MARK: Microphone

    static func toggleMicrophone() {
        let input = CoreAudioQuery.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(kAudioObjectUnknown))
        guard input != kAudioObjectUnknown else { QuitReminder.show("No microphone is connected.", plain: true); return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(input, &addr), AudioObjectIsPropertySettable(input, &addr, &settable) == noErr, settable.boolValue,
           AudioObjectGetPropertyData(input, &addr, 0, nil, &size, &muted) == noErr {
            var next: UInt32 = muted == 0 ? 1 : 0
            AudioObjectSetPropertyData(input, &addr, 0, nil, size, &next)
            QuitReminder.show(next == 1 ? "Microphone muted" : "Microphone on", plain: true)
            return
        }
        // No mute switch on this microphone: its input volume goes to 0 and back.
        var vAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
        var v: Float32 = 0
        var vSize = UInt32(MemoryLayout<Float32>.size)
        guard AudioHardwareServiceGetPropertyData(input, &vAddr, 0, nil, &vSize, &v) == noErr else {
            QuitReminder.show("This microphone can’t be muted by apps.", plain: true); return
        }
        let savedKey = "micMuteSavedVolume"
        var next: Float32
        if v > 0 { UserDefaults.standard.set(Double(v), forKey: savedKey); next = 0 }
        else { next = Float32(UserDefaults.standard.object(forKey: savedKey) as? Double ?? 0.75) }
        AudioHardwareServiceSetPropertyData(input, &vAddr, 0, nil, vSize, &next)
        QuitReminder.show(next == 0 ? "Microphone muted" : "Microphone on", plain: true)
    }

    // MARK: Headphones

    /// Headphones by how they're connected or what they're called. Pure: tested.
    nonisolated static func isHeadphones(transport: UInt32, dataSource: UInt32?, name: String) -> Bool {
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        if transport == kAudioDeviceTransportTypeBuiltIn, dataSource == 0x6864_706E /* 'hdpn' */ { return true }
        let n = name.lowercased()
        return ["headphone", "headset", "airpods", "earpods", "buds", "beats"].contains { n.contains($0) }
    }

    private static func currentOutput() -> (device: AudioObjectID, headphones: Bool) {
        let d = CoreAudioQuery.defaultOutput
        let transport: UInt32 = CoreAudioQuery.value(d, kAudioDevicePropertyTransportType, UInt32(0))
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let hasSource = AudioObjectHasProperty(d, &addr) && AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &source) == noErr
        return (d, isHeadphones(transport: transport, dataSource: hasSource ? source : nil, name: AppAudio.outputName))
    }

    private static func checkHeadphones() {
        let now = currentOutput()
        defer { lastOutput = now }
        guard let last = lastOutput, last.headphones, !now.headphones else { return }
        let target = Double(headphonePercent) / 100
        if let v = AppAudio.outputVolume, v > target {
            AppAudio.outputVolume = target
            QuitReminder.show("Headphones disconnected: volume lowered to \(headphonePercent)%", plain: true)
        }
    }
}
