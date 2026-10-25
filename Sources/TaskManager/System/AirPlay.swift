import Foundation
import Network

/// An AirPlay receiver on the local network (Apple TV, AirPlay TV, Mac).
struct AirPlayDevice: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let model: String          // from the Bonjour record, e.g. "AppleTV11,1"
    let video: Bool            // can show a screen, not only play audio

    var symbol: String {
        if model.hasPrefix("AppleTV") { return "appletv" }
        if model.hasPrefix("Mac") { return "desktopcomputer" }
        if model.hasPrefix("AudioAccessory") { return "homepod" }
        return video ? "tv" : "hifispeaker"
    }

    /// AirPlay "features" bits 0 (video) and 7 (screen mirroring) say it can
    /// show a screen. The value is "0x…" or "0x…,0x…" (low, high 32 bits).
    static func supportsVideo(features: String) -> Bool {
        let low = features.split(separator: ",").first.map(String.init) ?? features
        guard let v = UInt64(low.replacingOccurrences(of: "0x", with: ""), radix: 16) else { return true }
        return v & 0x1 != 0 || v & 0x80 != 0
    }
}

/// Finds AirPlay receivers with Bonjour (`_airplay._tcp`) while the Display
/// page's AirPlay popover is open.
@MainActor @Observable
final class AirPlayBrowser {
    static let shared = AirPlayBrowser()
    private(set) var devices: [AirPlayDevice] = []
    private(set) var searching = false
    @ObservationIgnored private var browser: NWBrowser?
    nonisolated static let thisMac = Host.current().localizedName ?? ""

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            let list = results.compactMap { r -> AirPlayDevice? in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                var model = "", features = ""
                if case .bonjour(let txt) = r.metadata {
                    model = txt["model"] ?? ""
                    features = txt["features"] ?? ""
                }
                // This Mac announces itself as an AirPlay receiver too.
                if name == AirPlayBrowser.thisMac { return nil }
                return AirPlayDevice(name: name, model: model, video: AirPlayDevice.supportsVideo(features: features))
            }
            .sorted { ($0.video ? 0 : 1, $0.name) < ($1.video ? 0 : 1, $1.name) }
            Task { @MainActor in AirPlayBrowser.shared.devices = list }
        }
        b.stateUpdateHandler = { state in
            Task { @MainActor in
                if case .ready = state { AirPlayBrowser.shared.searching = true }
                if case .failed = state { AirPlayBrowser.shared.searching = false }
            }
        }
        b.start(queue: .main)
        browser = b
        searching = true
    }

    func stop() {
        browser?.cancel()
        browser = nil
        searching = false
    }
}
