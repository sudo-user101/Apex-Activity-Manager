import SwiftUI
import AppKit
import FanControlCore

/// Energy header icon → battery charge limit.
struct ChargeLimitButton: View {
    @State private var show = false
    private var control: FanController { FanController.shared }

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: control.chargeLimit == nil ? "bolt.batteryblock" : "bolt.batteryblock.fill")
                .foregroundStyle(control.chargeLimit == nil ? Color.secondary : Color.green)
        }
        .buttonStyle(.bordered)
        .help(control.chargeLimit.map { "Charge limit: \($0)%" } ?? "Battery charge limit")
        .popover(isPresented: $show, arrowEdge: .bottom) { ChargeLimitPopover() }
    }
}

struct ChargeLimitPopover: View {
    @State private var working = false
    @State private var draft: Double = Double(FanController.shared.chargeLimit ?? 80)
    @State private var opened = Date()
    private var control: FanController { FanController.shared }

    /// Everything charge control needs, in the order the user grants it.
    private var ready: Bool {
        // An older helper still runs the limit: it doesn't block the controls (see `updateNote`).
        control.installed && control.settingsWritable && control.helperRunning
            && control.status?.chargeMethod != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Charge Limit").font(.headline)
                Spacer()
                if let l = control.chargeLimit { Text("\(l)%").monospacedDigit().foregroundStyle(.green) }
            }
            if ready { updateNote; controls } else { setup }
            if let e = control.lastError { Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14)
        .frame(width: 330)
        .task {
            while !Task.isCancelled {
                control.refreshStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Setup checklist

    @ViewBuilder private var setup: some View {
        Text("Stop charging at a level you choose to reduce battery wear. Apex needs these before it can change how your Mac charges:")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 8) {
            step(done: control.installed, "Administrator approval",
                 "Installs a small helper. macOS asks for your password once.")
            if control.installed {
                step(done: control.settingsWritable, "Settings access",
                     "Apex can’t write the helper’s settings file.")
                step(done: control.helperRunning, "Allowed in the background",
                     waitingForHelper ? "Starting…" : "Turn on “Apex Activity Manager” / “com.apex.fanhelper” in System Settings › General › Login Items & Extensions.")
                if control.helperRunning {
                    step(done: control.status?.chargeMethod != nil, "Supported by this Mac",
                         "This Mac’s firmware doesn’t allow charge control.")
                }
            }
        }
        HStack {
            if !control.installed {
                Button(working ? "Waiting for approval…" : "Allow…") { run { await control.install() } }
                    .keyboardShortcut(.defaultAction)
            } else if !control.settingsWritable {
                Button(working ? "Waiting for approval…" : "Repair…") {
                    run { await control.install() }
                }
                .keyboardShortcut(.defaultAction)
            } else if !control.helperRunning && !waitingForHelper {
                Button("Open Login Items Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
                Button("Try Again") { run { await control.install() } }
            }
            Spacer()
            if control.installed { removeButton }
        }
        .disabled(working)
    }

    /// Only when the helper itself changed (rare): it keeps working meanwhile.
    @ViewBuilder private var updateNote: some View {
        if !control.helperUpToDate {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                Text((["An updated helper is available."] + FanControl.helperNewsSince(control.status?.helperVersion)
                      + ["The limit keeps working until you update."]).joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(working ? "Updating…" : "Update…") { run { await control.install() } }.controlSize(.small).disabled(working)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Just installed: give the helper a few seconds to report in before calling it blocked.
    private var waitingForHelper: Bool { control.status == nil && Date().timeIntervalSince(opened) < 15 || working }

    private func step(done: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !done { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        Toggle("Limit charging", isOn: Binding(get: { control.chargeLimit != nil },
                                               set: { control.setChargeLimit($0 ? Int(draft) : nil) }))
            .toggleStyle(.switch)
        HStack {
            Slider(value: $draft, in: 50...100, step: 5) { editing in
                if !editing, control.chargeLimit != nil { control.setChargeLimit(Int(draft)) }
            }
            Text("\(Int(draft))%").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        .disabled(control.chargeLimit == nil)

        if control.chargeLimit != nil {
            if let until = control.chargeOverrideUntil, until > Date() {
                HStack {
                    Label("Charging to 100% once", systemImage: "bolt.fill").foregroundStyle(.orange)
                    Spacer()
                    Button("Resume Limit") { control.chargeToFullNow(false) }.controlSize(.small)
                }
            } else {
                Button("Charge to 100% Now") { control.chargeToFullNow(true) }
                    .help("Ignores the limit until the battery is full (at most 24 hours)")
            }
        }
        Divider()
        NightChargingSection()
        Divider()
        ChargeSchedulesSection()
        statusLine
        Text("The limit and schedules keep working when Apex is closed. At the limit the power adapter powers your Mac and the battery rests; it stays paused while the Mac sleeps, and is left paused when it shuts down (whether a switched-off Mac keeps that depends on its firmware: Apex tells you after a restart).")
            .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        HStack { Spacer(); removeButton }
    }

    private var removeButton: some View {
        Button("Remove Helper…") { run { await control.uninstall() } }
            .controlSize(.small)
            .help("Uninstalls the helper. Charging and fans go back to normal.")
    }

    private func run(_ action: @escaping () async -> Void) {
        working = true
        Task { await action(); control.refreshStatus(); opened = Date(); working = false }
    }

    @ViewBuilder private var statusLine: some View {
        if let s = control.status {
            if let m = s.message {
                Label(m, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            } else if control.chargeLimit == nil {
                Label("Charging normally", systemImage: "bolt.circle").font(.caption).foregroundStyle(.secondary)
            } else if s.limitNotHeld == true {
                Label("Not holding the limit: the power adapter keeps powering your Mac", systemImage: "powerplug.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if s.chargingBlocked {
                Label(s.chargeMethod == "hold"
                      ? "Holding at the limit: running on battery while plugged in"
                      : "Charging paused at \(s.batteryPercent.map { "\($0)%" } ?? "the limit") · the power adapter powers your Mac",
                      systemImage: s.chargeMethod == "hold" ? "battery.75percent" : "powerplug.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if let p = s.batteryPercent, let l = control.chargeLimit, p < l {
                Label("Charging to \(l)% (now \(p)%)", systemImage: "bolt.circle").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Applying the limit…", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if s.batteryPowering == true, s.chargeMethod != "hold" || !control.holdOnBattery {
                Label("Plugged in, but the battery is powering your Mac. The adapter may be too weak for what’s running, or it isn’t delivering power (try another cable or port).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if s.adapterRestored == true {
                Text("Something had disconnected the power adapter (another battery app?). Apex connected it again so it powers your Mac.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let off = s.whileOff {
                Label(off, systemImage: "power").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if s.chargeMethod == "hold" {
                Toggle("Hold the limit by running on battery", isOn: Binding(get: { control.holdOnBattery }, set: { control.setHoldOnBattery($0) }))
                    .toggleStyle(.switch).controlSize(.small)
                Text(control.holdOnBattery
                     ? "This Mac’s firmware can only stop charging by disconnecting the adapter, so at the limit your apps run on battery and it drifts down 3% before the adapter reconnects."
                     : "Off: the power adapter always powers your Mac. This Mac’s firmware can only stop charging by disconnecting the adapter, so the limit isn’t held while plugged in.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Night charging

/// Hold low overnight, full by morning, full until the Mac is opened.
struct NightChargingSection: View {
    private var control: FanController { FanController.shared }

    var body: some View {
        let n = control.nightCharging
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { n?.enabled == true }, set: { on in
                var x = n ?? FanControl.NightCharging(holdAt: control.chargeLimit.map { min($0, 95) } ?? 80)
                x.enabled = on; control.setNightCharging(x)
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Night charging").font(.subheadline.weight(.semibold))
                    Text("Holds a lower charge overnight and has it full when you wake up.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if let n, n.enabled {
                HStack {
                    Text("From")
                    DatePicker("", selection: time(\.start), displayedComponents: .hourAndMinute).labelsHidden()
                    Text("hold at")
                    Picker("", selection: Binding(get: { n.holdAt }, set: { var x = n; x.holdAt = $0; control.setNightCharging(x) })) {
                        ForEach(Array(stride(from: 50, through: 95, by: 5)), id: \.self) { Text("\($0)%").tag($0) }
                    }
                    .labelsHidden().frame(width: 70)
                }
                HStack {
                    Text("Full by")
                    DatePicker("", selection: time(\.fullBy), displayedComponents: .hourAndMinute).labelsHidden()
                }
                Text(status(n)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func status(_ n: FanControl.NightCharging) -> String {
        let p = FanControl.nightPlan(n, now: Date())
        let t = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        switch p.phase {
        case .hold(let until): return "Now holding at \(n.holdAt)%. Charging to 100% starts at \(t(until)) so it's full by \(t(p.fullBy))."
        case .topUp(let by): return "Now charging to 100%, to be full by \(t(by))."
        case .keepFull: return "Full. Kept full until you open your Mac (or noon)."
        case .off: return "Starts at \(t(p.start > Date() ? p.start : Calendar.current.date(byAdding: .day, value: 1, to: p.start)!)). Works with the lid closed: the Mac wakes for a few seconds every 30 minutes to check."
        }
    }

    private func time(_ key: WritableKeyPath<FanControl.NightCharging, Int>) -> Binding<Date> {
        Binding(get: {
            let m = control.nightCharging?[keyPath: key] ?? 0
            return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        }, set: {
            guard var x = control.nightCharging else { return }
            let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
            x[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            x.openedAt = nil
            control.setNightCharging(x)
        })
    }
}

// MARK: Schedules

/// Weekly charging windows, enforced by the helper (so they work with Apex
/// closed and after a restart). A manual "Charge to 100% Now" wins over them.
struct ChargeSchedulesSection: View {
    @State private var editing: FanControl.ChargeSchedule?
    private var control: FanController { FanController.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Schedules").font(.subheadline.weight(.semibold))
                Spacer()
                Button { editing = .init(days: [2, 3, 4, 5, 6], start: 6 * 60, end: 8 * 60, action: .fullCharge) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless).help("Add a schedule")
            }
            if control.chargeSchedules.isEmpty && editing == nil {
                Text("For example, charge to 100% on weekday mornings before you leave.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            let active = control.effectiveCharge.source
            ForEach(control.chargeSchedules) { sch in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { sch.enabled }, set: { var s = sch; s.enabled = $0; control.setSchedule(s) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.describe(sch)).font(.callout)
                        if active == .schedule(sch.id) { Text("Active now").font(.caption2.weight(.semibold)).foregroundStyle(.green) }
                    }
                    Spacer()
                    Button { editing = sch } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit")
                    Button { control.removeSchedule(sch.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete")
                }
            }
            if active == .override, !control.chargeSchedules.isEmpty {
                Text("Charge to 100% Now is on, so schedules wait until it ends.").font(.caption).foregroundStyle(.orange)
            } else if active == .night, !control.chargeSchedules.isEmpty {
                Text("Night charging is in charge right now; schedules apply outside the night.").font(.caption).foregroundStyle(.secondary)
            }
            if let e = editing {
                ScheduleEditor(schedule: e, onSave: { control.setSchedule($0); editing = nil }, onCancel: { editing = nil })
            }
        }
    }

    static let dayLetters = ["S", "M", "T", "W", "T", "F", "S"]
    static let dayNames = Calendar.current.shortWeekdaySymbols

    static func describe(_ s: FanControl.ChargeSchedule) -> String {
        let days: String
        switch s.days {
        case [2, 3, 4, 5, 6]: days = "Weekdays"
        case [1, 7]: days = "Weekends"
        case Set(1...7): days = "Every day"
        default: days = s.days.sorted().map { dayNames[$0 - 1] }.joined(separator: ", ")
        }
        let action: String
        switch s.action {
        case .fullCharge: action = "charge to 100%"
        case .limit(let l): action = "hold at \(l)%"
        }
        return "\(days) \(time(s.start))–\(time(s.end)): \(action)"
    }

    static func time(_ m: Int) -> String {
        let d = Calendar.current.date(bySettingHour: m / 60 % 24, minute: m % 60, second: 0, of: Date()) ?? Date()
        return d.formatted(date: .omitted, time: .shortened)
    }
}

private struct ScheduleEditor: View {
    @State var schedule: FanControl.ChargeSchedule
    var onSave: (FanControl.ChargeSchedule) -> Void
    var onCancel: () -> Void
    @State private var limit: Double = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { d in
                    let on = schedule.days.contains(d)
                    Button(ChargeSchedulesSection.dayLetters[d - 1]) {
                        if on { schedule.days.remove(d) } else { schedule.days.insert(d) }
                    }
                    .buttonStyle(.bordered).tint(on ? .accentColor : .secondary)
                    .help(ChargeSchedulesSection.dayNames[d - 1])
                }
            }
            HStack {
                DatePicker("From", selection: minutes(\.start), displayedComponents: .hourAndMinute)
                DatePicker("to", selection: minutes(\.end), displayedComponents: .hourAndMinute)
            }
            .labelsHidden()
            Picker("", selection: Binding(get: { schedule.action == .fullCharge }, set: { schedule.action = $0 ? .fullCharge : .limit(Int(limit)) })) {
                Text("Charge to 100%").tag(true)
                Text("Hold at a limit").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()
            if case .limit = schedule.action {
                HStack {
                    Slider(value: $limit, in: 50...95, step: 5) { _ in schedule.action = .limit(Int(limit)) }
                    Text("\(Int(limit))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            if schedule.end <= schedule.start {
                Text("Ends the next day.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(schedule) }.keyboardShortcut(.defaultAction)
                    .disabled(schedule.days.isEmpty || schedule.start == schedule.end)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { if case .limit(let l) = schedule.action { limit = Double(l) } }
    }

    private func minutes(_ key: WritableKeyPath<FanControl.ChargeSchedule, Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: schedule[keyPath: key] / 60, minute: schedule[keyPath: key] % 60, second: 0, of: Date()) ?? Date() },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); schedule[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0) })
    }
}
