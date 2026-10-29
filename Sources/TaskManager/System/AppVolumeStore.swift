import AppKit
import CoreAudio

/// Volume per app, kept by bundle id (UserDefaults `appVolumes` 0–1 and
/// `appMuted`) and applied whenever that app plays, with the menu open or
/// not. Checks every 3 s while the Sound tab shows or any app has its own
/// volume; otherwise does nothing.
@MainActor @Observable
final class AppVolumeStore {
    static let shared = AppVolumeStore()

    private(set) var apps: [AudioApp] = []
    private(set) var volumes: [String: Double]
    private(set) var muted: Set<String>
    /// Why an app's volume couldn't be applied (permission, no speakers…).
    private(set) var problem: String?
    private(set) var outputName = ""
    private(set) var outputVolume: Double?
    @ObservationIgnored private var taps: [String: AnyObject] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var showing = false

    /// Per-app volume needs Core Audio process taps (macOS 14.2+).
    static var supported: Bool { if #available(macOS 14.2, *) { return true } else { return false } }

    private init() {
        volumes = UserDefaults.standard.dictionary(forKey: "appVolumes") as? [String: Double] ?? [:]
        muted = Set(UserDefaults.standard.stringArray(forKey: "appMuted") ?? [])
    }

    /// At launch: only does anything if some app has its own volume.
    func start() { if hasCustom { refresh(); schedule() } }

    var hasCustom: Bool { !volumes.isEmpty || !muted.isEmpty }

    func volume(_ bundle: String) -> Double { volumes[bundle] ?? 1 }
    func isMuted(_ bundle: String) -> Bool { muted.contains(bundle) }

    /// The Sound tab opened or closed.
    func setShowing(_ on: Bool) {
        showing = on
        if on { refresh() }
        schedule()
    }

    func refresh() {
        apps = AppAudio.apps()
        // Apps that aren't running any more but have a volume set keep it; they're just not listed.
        outputName = AppAudio.outputName
        outputVolume = AppAudio.outputVolume
        reconcile()
    }

    func setVolume(_ bundle: String, _ v: Double) {
        volumes[bundle] = AppAudio.needsTap(v, muted: false) ? min(max(v, 0), 1) : nil
        save()
        reconcile()
    }

    func toggleMute(_ bundle: String) {
        if muted.contains(bundle) { muted.remove(bundle) } else { muted.insert(bundle) }
        save()
        reconcile()
    }

    /// Every app back to its normal volume (removes all taps).
    func resetAll() {
        volumes = [:]; muted = []
        save()
        reconcile()
    }

    func setOutputVolume(_ v: Double) {
        AppAudio.outputVolume = v
        outputVolume = AppAudio.outputVolume
    }

    private func save() {
        UserDefaults.standard.set(volumes, forKey: "appVolumes")
        UserDefaults.standard.set(Array(muted).sorted(), forKey: "appMuted")
        schedule()
    }

    private func schedule() {
        let wanted = showing || hasCustom
        if wanted, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                MainActor.assumeIsolated { AppVolumeStore.shared.refresh() }
            }
        } else if !wanted {
            timer?.invalidate(); timer = nil
        }
    }

    /// A tap for every listed app that isn't at full volume; none for the rest.
    /// A tap is rebuilt when the app's processes or the speakers change.
    private func reconcile() {
        guard #available(macOS 14.2, *) else { return }
        let out = CoreAudioQuery.defaultOutput
        var keep = Set<String>()
        var failure: String?
        for app in apps {
            let v = volume(app.bundleID), m = isMuted(app.bundleID)
            guard AppAudio.needsTap(v, muted: m) else { continue }
            keep.insert(app.bundleID)
            let g = AppAudio.gain(v, muted: m)
            if let t = taps[app.bundleID] as? AppVolumeTap, t.objects == app.objects, t.output == out {
                t.gain.value = g
                continue
            }
            (taps[app.bundleID] as? AppVolumeTap)?.cleanUp()
            taps[app.bundleID] = nil
            do { taps[app.bundleID] = try AppVolumeTap(objects: app.objects, gain: g) }
            catch AppVolumeTap.Failure.noOutput { failure = "There’s no sound output to play through." }
            catch { failure = Self.permissionHint }
        }
        for (b, t) in taps where !keep.contains(b) {
            (t as? AppVolumeTap)?.cleanUp()
            taps[b] = nil
        }
        problem = failure
    }

    static let permissionHint = "macOS didn’t let Apex pass this app’s sound through. Allow Apex under System Settings › Privacy & Security › Screen & System Audio Recording (System Audio Recording Only). Apex never records or keeps any sound."
    static let permissionSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
