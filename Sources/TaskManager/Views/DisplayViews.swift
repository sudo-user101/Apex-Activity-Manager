import AppKit
import SwiftUI

/// Connected displays, their brightness and resolutions. Read when the
/// Display page opens and whenever displays change; brightness changes run on
/// one serial queue, and only the latest slider value is sent.
@MainActor @Observable
final class DisplayStore {
    static let shared = DisplayStore()

    private(set) var displays: [DisplayInfo] = []
    private(set) var methods: [CGDirectDisplayID: BrightnessMethod] = [:]
    private(set) var brightness: [CGDirectDisplayID: Double] = [:]
    private(set) var modes: [CGDirectDisplayID: [DisplayModeChoice]] = [:]
    /// Brightness over the last 10 minutes, one point every 5 s while the page is open.
    private(set) var brightnessHistory: [CGDirectDisplayID: [Double]] = [:]
    var message: String?

    @ObservationIgnored private let queue = DispatchQueue(label: "apex.display", qos: .userInitiated)
    @ObservationIgnored private var pending: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                DDC.reset()
                DisplayStore.shared.reload()
            }
        }
    }

    func reload() {
        let list = Displays.all()
        displays = list
        for d in list { modes[d.id] = Displays.modes(d.id) }
        queue.async {
            var m: [CGDirectDisplayID: BrightnessMethod] = [:], b: [CGDirectDisplayID: Double] = [:]
            for d in list {
                let method = Brightness.method(for: d)
                m[d.id] = method
                b[d.id] = Brightness.get(d, method)
            }
            DispatchQueue.main.async {
                self.methods = m
                // Keep values the user is dragging right now.
                for (id, v) in b where self.pending[id] == nil { self.brightness[id] = v }
            }
        }
    }

    /// Reads brightness again (it changes on its own with auto-brightness) and
    /// adds a point to each display's history.
    func sampleBrightness() {
        let list = displays, m = methods
        queue.async {
            var b: [CGDirectDisplayID: Double] = [:]
            for d in list { if let method = m[d.id], let v = Brightness.get(d, method) { b[d.id] = v } }
            DispatchQueue.main.async {
                for (id, v) in b {
                    if self.pending[id] == nil { self.brightness[id] = v }
                    var h = self.brightnessHistory[id] ?? []
                    h.append(v * 100)
                    if h.count > 120 { h.removeFirst(h.count - 120) }
                    self.brightnessHistory[id] = h
                }
            }
        }
    }

    func setBrightness(_ v: Double, for d: DisplayInfo) {
        brightness[d.id] = v
        guard let method = methods[d.id] else { return }
        let first = pending[d.id] == nil
        pending[d.id] = v
        guard first else { return }            // a send is already queued; it picks up the latest value
        queue.async {
            let value = DispatchQueue.main.sync { MainActor.assumeIsolated { self.pending.removeValue(forKey: d.id) } } ?? v
            let err = Brightness.set(value, on: d, method)
            if let err { DispatchQueue.main.async { self.message = err } }
        }
    }

    func setMode(_ m: DisplayModeChoice, for d: DisplayInfo) {
        message = Displays.setMode(m, on: d.id)
        reload()
    }
}

struct DisplayDetail: View {
    /// macOS only lets Control Center and System Settings start screen
    /// mirroring, so this opens Displays settings (its "+" / AirPlay menu).
    static func openAirPlay() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @AppStorage("displayTab") private var tab: Int = 0
    private let store = DisplayStore.shared

    var body: some View {
        let list = store.displays
        let d = list.first { Int($0.id) == tab } ?? list.first
        VStack(alignment: .leading, spacing: 16) {
            if list.count > 1 {
                TabStrip(tabs: list.map { (String($0.id), $0.name, $0.symbol) }, selected: String(d?.id ?? 0)) {
                    tab = Int($0) ?? 0
                }
                .help("Switch between displays")
            }
            if let d {
                page(d)
            } else {
                ContentUnavailableView("No Display", systemImage: "display", description: Text("macOS reports no active display."))
            }
        }
        .onAppear { store.reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                store.sampleBrightness()
            }
        }
    }

    @ViewBuilder private func page(_ d: DisplayInfo) -> some View {
        let method = store.methods[d.id]
        PageHeader(title: d.name, subtitle: [d.isBuiltin ? "Built-in" : "External", d.isMain ? "Main display" : "",
                                             d.mirrored ? "Mirrored" : ""].filter { !$0.isEmpty }.joined(separator: " · "),
                   accessory: AnyView(AirPlayButton()),
                   showsRange: false)

        VStack(alignment: .leading, spacing: 8) {
            Text("Brightness").font(.headline)
            HStack(spacing: 10) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: Binding(get: { store.brightness[d.id] ?? 1 }, set: { store.setBrightness($0, for: d) }), in: 0...1)
                    .disabled(method == nil)
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                Text(store.brightness[d.id].map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            Text(method?.note ?? "Checking how this display can be controlled…")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

        VStack(alignment: .leading, spacing: 8) {
            Text("Arrangement").font(.headline)
            DisplayArrangement(displays: store.displays, selected: d.id, labels: true)
                .frame(height: 150)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

        if let h = store.brightnessHistory[d.id], h.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Brightness over time").font(.headline)
                    Spacer()
                    Text("one point every 5 s while this page is open").font(.caption).foregroundStyle(.secondary)
                }
                LineGraph(series: [.init(values: h, color: .yellow, name: "Brightness")], maxValue: 100)
                    .environment(\.graphUnit, .percent)
                    .frame(height: 90)
            }
        }

        statsGrid([
            ("Looks like", "\(d.pointsWide) × \(d.pointsHigh)"),
            ("Pixels", "\(d.pixelsWide) × \(d.pixelsHigh)"),
            ("Scale", d.scale > 1 ? String(format: "%g× (sharp text)", d.scale) : "1× (low resolution)"),
            ("Refresh rate", d.refresh > 0 ? String(format: "%g Hz", d.refresh.rounded()) : "—"),
            ("Size", d.diagonalInches.map { String(format: "%g-inch", $0) } ?? "—"),
            ("HDR", d.hdr ? "Yes" : "No"),
            ("Color profile", d.colorProfile.isEmpty ? "—" : d.colorProfile),
            ("Rotation", d.rotation == 0 ? "Standard" : "\(d.rotation)°"),
        ])

        let modes = store.modes[d.id] ?? []
        if !modes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Resolution").font(.headline)
                Picker("Resolution", selection: Binding(
                    get: { modes.first(where: \.isCurrent)?.id ?? -1 },
                    set: { id in if let m = modes.first(where: { $0.id == id }), !m.isCurrent { store.setMode(m, for: d) } })) {
                    ForEach(modes) { m in
                        Text(m.title + (m.isNative ? " (native)" : "")).tag(m.id)
                    }
                }
                .labelsHidden().fixedSize()
                Text("Changes right away and is kept after restart, like in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let m = store.message {
            Text(m).font(.callout).foregroundStyle(.orange)
        }
    }
}

/// Display header: AirPlay devices on this network, found by Apex. Picking
/// one opens macOS's screen mirroring to connect (macOS keeps starting AirPlay
/// mirroring to itself); once connected it gets its own tab here.
private struct AirPlayButton: View {
    @State private var show = false
    @State private var picked: String?
    private let browser = AirPlayBrowser.shared

    var body: some View {
        Button { show.toggle() } label: { Image(systemName: "airplayvideo") }
            .buttonStyle(.bordered)
            .help("AirPlay: show this Mac’s screen on an Apple TV or AirPlay display")
            .popover(isPresented: $show, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("AirPlay").font(.headline)
                        Spacer()
                        if browser.searching { ProgressView().controlSize(.small) }
                    }
                    if browser.devices.isEmpty {
                        Text(browser.searching ? "Looking for AirPlay displays on your network…" : "No AirPlay displays found.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
                    }
                    ForEach(browser.devices) { d in
                        Button {
                            picked = d.name
                            DisplayDetail.openAirPlay()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: d.symbol).frame(width: 22).foregroundStyle(d.video ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(d.name)
                                    Text(d.video ? "Can show your screen" : "Audio only").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if picked == d.name { Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary) }
                            }
                            .padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!d.video)
                    }
                    if let picked {
                        Text("macOS only lets its own Screen Mirroring start AirPlay, so Apex opened it: choose “\(picked)” there. It then appears here as its own display, with its resolution.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Pick a display to mirror or extend this Mac’s screen to it.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(14).frame(width: 320)
            }
            .onChange(of: show) { _, open in if open { picked = nil; browser.start() } else { browser.stop() } }
    }
}

/// Displays drawn to scale where macOS places them (CGDisplayBounds), the
/// main one marked; in the sidebar card and on the Display page.
struct DisplayArrangement: View {
    var displays: [DisplayInfo]
    var selected: CGDirectDisplayID? = nil
    var labels = false

    var body: some View {
        Canvas { ctx, size in
            let rects = displays.map { (d: $0, r: CGDisplayBounds($0.id)) }
            guard let first = rects.first else { return }
            let all = rects.dropFirst().reduce(first.r) { $0.union($1.r) }
            guard all.width > 0, all.height > 0 else { return }
            let pad: CGFloat = labels ? 8 : 3
            let scale = min((size.width - pad * 2) / all.width, (size.height - pad * 2) / all.height)
            let offX = (size.width - all.width * scale) / 2, offY = (size.height - all.height * scale) / 2
            for (d, r) in rects {
                let box = CGRect(x: offX + (r.minX - all.minX) * scale, y: offY + (r.minY - all.minY) * scale,
                                 width: r.width * scale, height: r.height * scale).insetBy(dx: 1.5, dy: 1.5)
                let on = d.id == selected || (selected == nil && d.isMain)
                let shape = Path(roundedRect: box, cornerRadius: labels ? 6 : 3)
                ctx.fill(shape, with: .color(on ? Color.teal.opacity(0.35) : Color.secondary.opacity(0.18)))
                ctx.stroke(shape, with: .color(on ? .teal : Color.secondary.opacity(0.6)), lineWidth: on ? 1.5 : 1)
                if d.isMain {   // menu bar strip, like System Settings
                    let bar = CGRect(x: box.minX, y: box.minY, width: box.width, height: max(2, box.height * 0.07))
                    ctx.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(.white.opacity(0.8)))
                }
                if labels {
                    let text = Text("\(d.name)\n\(d.pointsWide) × \(d.pointsHigh)" + (d.refresh > 0 ? String(format: " · %g Hz", d.refresh.rounded()) : ""))
                        .font(.caption).foregroundStyle(.primary)
                    ctx.draw(text, at: CGPoint(x: box.midX, y: box.midY))
                }
            }
        }
        .accessibilityLabel("\(displays.count) display\(displays.count == 1 ? "" : "s")")
    }
}
