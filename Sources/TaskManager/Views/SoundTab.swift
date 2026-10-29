import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Menu bar › Sound: play / pause and next for whatever is playing, the
/// speakers' volume, and a volume and mute for each app with sound.
struct SoundTab: View {
    private let store = AppVolumeStore.shared
    @State private var keysAllowed = MediaKeys.allowed

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Media keys: macOS sends them to the app playing now.
            HStack(spacing: 18) {
                Spacer()
                mediaButton(.previous, "backward.fill", "Previous")
                mediaButton(.playPause, "playpause.fill", "Play or pause what’s playing")
                mediaButton(.next, "forward.fill", "Next")
                Spacer()
            }
            if !keysAllowed {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "hand.raised").foregroundStyle(.secondary)
                    Text("To control playback, allow Apex under Privacy & Security › Accessibility. It sends the same keys as your keyboard’s play and next keys.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Allow…") { MediaKeys.askPermission() }.controlSize(.small)
                }
            }

            if let v = store.outputVolume {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary).frame(width: 16)
                    Slider(value: Binding(get: { v }, set: { store.setOutputVolume($0) }), in: 0...1)
                    Text("\(Int((v * 100).rounded()))%").font(.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
                }
                .help("Volume of \(store.outputName)")
            }
            Text(store.outputName).font(.caption).foregroundStyle(.secondary)
            Divider()

            if !AppVolumeStore.supported {
                Text("Volume per app needs macOS 14.2 or later.").font(.callout).foregroundStyle(.secondary)
            } else if store.apps.isEmpty {
                Text("No app is playing sound.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) { ForEach(store.apps) { row($0) } }
                }
                .frame(maxHeight: 300)
            }
            if let p = store.problem {
                VStack(alignment: .leading, spacing: 4) {
                    Label(p, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(AppVolumeStore.permissionSettings) }.controlSize(.small)
                }
            }
            HStack {
                Text("Each app’s sound passes through Apex on its way to the speakers. Nothing is recorded.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if store.hasCustom { Button("Reset All") { store.resetAll() }.controlSize(.small).help("Every app back to its normal volume") }
            }
        }
        .onAppear { store.setShowing(true); keysAllowed = MediaKeys.allowed }
        .onDisappear { store.setShowing(false) }
    }

    private func mediaButton(_ key: MediaKeys.Key, _ symbol: String, _ help: String) -> some View {
        Button { if !MediaKeys.send(key) { keysAllowed = false } } label: {
            Image(systemName: symbol).font(.title3).frame(width: 34, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func row(_ a: AudioApp) -> some View {
        let muted = store.isMuted(a.bundleID)
        let v = store.volume(a.bundleID)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(nsImage: icon(a)).resizable().frame(width: 18, height: 18)
                Text(a.name).lineLimit(1)
                if a.playing {
                    Image(systemName: "waveform").font(.caption).foregroundStyle(.green).help("Playing now")
                }
                Spacer()
                Text(muted ? "Muted" : "\(Int((v * 100).rounded()))%").font(.caption).monospacedDigit()
                    .foregroundStyle(muted ? .orange : .secondary)
            }
            HStack(spacing: 8) {
                Button { store.toggleMute(a.bundleID) } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(muted ? Color.orange : Color.secondary).frame(width: 18)
                }
                .buttonStyle(.borderless).help(muted ? "Unmute \(a.name)" : "Mute \(a.name)")
                Slider(value: Binding(get: { v }, set: { store.setVolume(a.bundleID, $0) }), in: 0...1)
                    .disabled(muted)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(_ a: AudioApp) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.bundleID) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .application)
    }
}
