import AppKit
import SwiftUI

/// Energy header icon: stay awake (for a while, on chosen days) and keep chosen
/// apps running with the lid closed.
struct StayAwakeButton: View {
    @State private var show = false
    private let lid = LidAwake.shared
    private let awake = KeepAwake.shared

    var body: some View {
        let on = lid.active || awake.isOn
        Button { show.toggle() } label: {
            Image(systemName: on ? "sun.max.fill" : "moon.zzz").foregroundStyle(on ? Color.yellow : .primary)
        }
        .buttonStyle(.bordered)
        .help(on ? "Staying awake: click for details" : "Stay awake: keep the Mac (and chosen apps) going, even with the lid closed")
        .popover(isPresented: $show, arrowEdge: .bottom) { StayAwakePopover().padding(16).frame(width: 440) }
    }
}

struct StayAwakePopover: View {
    @State private var duration: TimeInterval? = 3600
    private let lid = LidAwake.shared
    private let awake = KeepAwake.shared

    var body: some View {
        @Bindable var lid = lid
        VStack(alignment: .leading, spacing: 14) {
            Text("Stay Awake").font(.headline)

            // 1. Lid open: now, for a while.
            section("With the lid open") {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep awake now")
                        Text(awake.isOn ? awake.remainingText() : "Off: your Mac sleeps as usual")
                            .font(.caption).foregroundStyle(awake.isOn ? Color.green : .secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { duration ?? -1 }, set: { duration = $0 < 0 ? nil : $0 })) {
                        ForEach(KeepAwake.choices, id: \.0) { c in Text(c.0).tag(c.1 ?? -1) }
                    }
                    .labelsHidden().fixedSize().disabled(awake.isOn)
                    Toggle("", isOn: Binding(get: { awake.isOn }, set: { $0 ? awake.start(for: duration, keepDisplayOn: awake.displayOn) : awake.stop() }))
                        .toggleStyle(.switch).labelsHidden()
                }
                HStack(spacing: 4) {
                    Text("Every").foregroundStyle(.secondary)
                    ForEach(1...7, id: \.self) { d in
                        let sym = Calendar.current.veryShortWeekdaySymbols[d - 1]
                        let on = lid.awakeDays.contains(d)
                        Button { if on { lid.awakeDays.remove(d) } else { lid.awakeDays.insert(d) } } label: {
                            Text(sym).frame(width: 24, height: 22)
                                .background(on ? Color.accentColor : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                                .foregroundStyle(on ? Color.white : .primary)
                        }
                        .buttonStyle(.plain)
                        .help(Calendar.current.weekdaySymbols[d - 1] + (on ? ": staying awake all day" : ""))
                    }
                    Text("all day").foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            // 2. Lid closed: chosen apps keep running.
            section("With the lid closed") {
                Toggle("Keep these apps running when I close the lid", isOn: $lid.lidEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lid.apps, id: \.self) { id in
                        HStack(spacing: 8) {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                            }
                            Text(LidAwake.name(id))
                            Spacer()
                            Button { lid.apps.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Remove")
                        }
                    }
                    Menu {
                        let running = NSWorkspace.shared.runningApplications
                            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !lid.apps.contains($0.bundleIdentifier!) }
                            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
                        if running.isEmpty { Text("No other open apps") }
                        ForEach(running, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? "App") { lid.apps.append(app.bundleIdentifier!) }
                        }
                    } label: { Label("Add an Open App", systemImage: "plus") }
                    .fixedSize()
                    .help("For example a browser downloading a file, or an app uploading a video")
                }
                .disabled(!lid.lidEnabled)
                HStack {
                    Toggle("On battery too, for up to", isOn: $lid.allowOnBattery)
                    Picker("", selection: $lid.batteryMinutes) {
                        ForEach(LidAwake.batteryChoices, id: \.self) { m in Text(m == 60 ? "1 hour" : "\(m) minutes").tag(m) }
                    }
                    .labelsHidden().fixedSize().disabled(!lid.allowOnBattery)
                }
                .disabled(!lid.lidEnabled)
                if !lid.reason.isEmpty {
                    Label(lid.reason, systemImage: lid.active ? "checkmark.circle.fill" : "info.circle")
                        .font(.caption).foregroundStyle(lid.active ? Color.green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("On power, the chosen apps keep going with the lid closed. On battery the Mac sleeps as usual unless you allow it, and never for more than an hour. Keep a closed Mac somewhere it can breathe, not in a bag.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { lid.evaluate() }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
