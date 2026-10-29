import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio

/// Menu bar › Sound: which apps are playing, a volume for each, and play /
/// pause / next for whatever is playing.
///
/// Per-app volume uses Core Audio process taps (macOS 14.2+): a tap mutes
/// the app's own output (`mutedWhenTapped`) and Apex plays the tapped sound
/// to the speakers through a private aggregate device, scaled by the app's
/// volume. Nothing is recorded or stored; the sound only passes through. An
/// app at 100% has no tap at all, so nothing runs until a slider moves.

/// An app that has audio in Core Audio (its helpers grouped under it).
struct AudioApp: Identifiable, Hashable, Sendable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var pid: pid_t
    /// Core Audio process objects for the app and its helpers.
    var objects: [AudioObjectID]
    var playing: Bool
}

enum CoreAudioQuery {
    static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ fallback: T,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
        var addr = address(sel, scope)
        var v = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        return err == noErr ? v : fallback
    }

    static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func objects(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(sel)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    static var defaultOutput: AudioObjectID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown))
    }
}

enum AppAudio {
    /// Every app with audio in Core Audio, helpers grouped under their app.
    /// Cheap (property reads only).
    static func apps() -> [AudioApp] {
        var byOwner: [String: AudioApp] = [:]
        for obj in CoreAudioQuery.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            let pid: pid_t = CoreAudioQuery.value(obj, kAudioProcessPropertyPID, -1)
            guard pid > 0, pid != getpid() else { continue }
            let bundle = CoreAudioQuery.string(obj, kAudioProcessPropertyBundleID) ?? ""
            let playing = CoreAudioQuery.value(obj, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0
            // Only apps you can see (in the Dock): macOS's own audio services aren't listed.
            guard let owner = ownerApp(pid: pid, bundleID: bundle), !owner.bundleID.isEmpty else { continue }
            var a = byOwner[owner.bundleID] ?? AudioApp(bundleID: owner.bundleID, name: owner.name, pid: owner.pid, objects: [], playing: false)
            a.objects.append(obj)
            a.playing = a.playing || playing
            byOwner[owner.bundleID] = a
        }
        return byOwner.values.sorted { ($0.playing ? 0 : 1, $0.name.lowercased()) < ($1.playing ? 0 : 1, $1.name.lowercased()) }
    }

    /// The app a sound-making process belongs to: the process macOS holds
    /// responsible for it (Safari for its WebKit helpers), else the bundle
    /// name without its helper part.
    /// Nil when no app owns it (one of macOS's own audio services).
    static func ownerApp(pid: pid_t, bundleID: String) -> (bundleID: String, name: String, pid: pid_t)? {
        let rpid = responsiblePID(pid) ?? pid
        for p in [rpid, pid] {
            if let app = NSRunningApplication(processIdentifier: p), let b = app.bundleIdentifier, app.activationPolicy == .regular {
                return (b, app.localizedName ?? b, p)
            }
        }
        let b = ownerBundle(bundleID)
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first(where: { $0.activationPolicy == .regular }) else { return nil }
        return (b, app.localizedName ?? b, app.processIdentifier)
    }

    /// "com.google.Chrome.helper.renderer" → "com.google.Chrome". Pure: tested.
    static func ownerBundle(_ bundleID: String) -> String {
        let parts = bundleID.split(separator: ".")
        guard let i = parts.firstIndex(where: { $0.lowercased().hasPrefix("helper") || $0.lowercased() == "plugincontainer" }), i > 0 else { return bundleID }
        return parts[..<i].joined(separator: ".")
    }

    /// `responsibility_get_pid_responsible_for_pid` (libSystem; looked up so a
    /// missing symbol only means "no answer").
    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        typealias Fn = @convention(c) (pid_t) -> pid_t
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        let r = unsafeBitCast(sym, to: Fn.self)(pid)
        return r > 0 ? r : nil
    }

    // MARK: Volume curve

    /// Slider position (0–1) → gain. Squared, so the slider feels even to the
    /// ear (half way sounds about half as loud). Muted = 0. Pure: tested.
    static func gain(_ volume: Double, muted: Bool) -> Float {
        muted ? 0 : Float(min(max(volume, 0), 1) * min(max(volume, 0), 1))
    }

    /// Needs a tap: anything other than full volume, unmuted. Pure: tested.
    static func needsTap(_ volume: Double, muted: Bool) -> Bool { muted || volume < 0.995 }

    /// Copies `src` into `dst` scaled by `gain`; the rest of `dst` is silence.
    /// What the audio thread does for each buffer. Pure: tested.
    static func mix(_ src: UnsafePointer<Float>?, count srcCount: Int, into dst: UnsafeMutablePointer<Float>, count dstCount: Int, gain: Float) {
        let n = src == nil ? 0 : min(srcCount, dstCount)
        if let src { for i in 0..<n { dst[i] = src[i] * gain } }
        if n < dstCount { (dst + n).update(repeating: 0, count: dstCount - n) }
    }

    // MARK: System output

    static var outputName: String {
        CoreAudioQuery.string(CoreAudioQuery.defaultOutput, kAudioObjectPropertyName) ?? "Speakers"
    }

    /// The system output volume (0–1), nil when the device has no volume control.
    static var outputVolume: Double? {
        get {
            var addr = CoreAudioQuery.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioHardwareServiceGetPropertyData(CoreAudioQuery.defaultOutput, &addr, 0, nil, &size, &v)
            return err == noErr ? Double(v) : nil
        }
        set {
            guard let newValue else { return }
            var addr = CoreAudioQuery.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
            var v = Float32(min(max(newValue, 0), 1))
            _ = AudioHardwareServiceSetPropertyData(CoreAudioQuery.defaultOutput, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }
}

/// The gain the audio thread reads. A Float written from the main thread and
/// read on the audio thread: a torn read can't happen for 32 bits on Apple
/// silicon or Intel, and a stale one only lasts one buffer.
final class GainBox: @unchecked Sendable { var value: Float = 1 }

/// One app's volume: its process tap, a private aggregate device (the tap in,
/// the current speakers out) and the audio callback that scales the sound.
@available(macOS 14.2, *)
final class AppVolumeTap {
    enum Failure: Error { case tap(OSStatus), aggregate(OSStatus), ioProc(OSStatus), start(OSStatus), noOutput }

    let objects: [AudioObjectID]
    let output: AudioObjectID
    let gain = GainBox()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.apex.appvolume", qos: .userInteractive)

    init(objects: [AudioObjectID], gain: Float) throws {
        self.objects = objects
        output = CoreAudioQuery.defaultOutput
        self.gain.value = gain
        guard output != kAudioObjectUnknown, let outputUID = CoreAudioQuery.string(output, kAudioDevicePropertyDeviceUID) else { throw Failure.noOutput }

        let desc = CATapDescription(stereoMixdownOfProcesses: objects)
        desc.uuid = UUID()
        desc.name = "Apex volume"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { throw Failure.tap(err) }
        tapID = tap

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Apex App Volume",
            kAudioAggregateDeviceUIDKey: "com.apex.appvolume." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard err == noErr else { cleanUp(); throw Failure.aggregate(err) }
        aggregateID = agg

        let box = self.gain
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { _, inInput, _, outOutput, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            let outs = UnsafeMutableAudioBufferListPointer(outOutput)
            let g = box.value
            for (i, out) in outs.enumerated() {
                guard let dst = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let dstCount = Int(out.mDataByteSize) / MemoryLayout<Float>.size
                if ins.count == 0 { AppAudio.mix(nil, count: 0, into: dst, count: dstCount, gain: g); continue }
                let src = ins[min(i, ins.count - 1)]
                AppAudio.mix(src.mData?.assumingMemoryBound(to: Float.self), count: Int(src.mDataByteSize) / MemoryLayout<Float>.size,
                             into: dst, count: dstCount, gain: g)
            }
        }
        guard err == noErr, let proc else { cleanUp(); throw Failure.ioProc(err) }
        procID = proc
        err = AudioDeviceStart(agg, proc)
        guard err == noErr else { cleanUp(); throw Failure.start(err) }
    }

    /// Stops the callback and removes the device and the tap; the app's own sound comes back.
    func cleanUp() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    deinit { cleanUp() }
}

/// Play / pause, next and previous for whatever is playing: the keyboard's
/// media keys, sent the way the keyboard sends them (macOS routes them to
/// the app playing now). Sending keys needs Accessibility permission.
enum MediaKeys {
    enum Key: Int32 { case playPause = 16, next = 17, previous = 18 }   // NX_KEYTYPE_PLAY / NEXT / PREVIOUS

    static var allowed: Bool { AXIsProcessTrusted() }

    /// Asks macOS (once it shows the prompt; afterwards opens the switch).
    static func askPermission() { Task { @MainActor in AccessibilityAccess.ask() } }

    /// The `data1` of a media-key event. Pure: tested.
    static func data1(_ key: Key, down: Bool) -> Int { Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8)) }

    @discardableResult
    static func send(_ key: Key) -> Bool {
        guard allowed else { askPermission(); return false }
        for down in [true, false] {
            let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                       modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                       timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                       data1: data1(key, down: down), data2: -1)
            e?.cgEvent?.post(tap: .cghidEventTap)
        }
        return true
    }
}
