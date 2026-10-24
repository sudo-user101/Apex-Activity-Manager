import SwiftUI
import FanControlCore

/// Manual fan controls (shown only on Macs that report fans).
struct FanControlPanel: View {
    let fans: [FanReading]
    let sensors: SensorSnapshot
    private var control: FanController { FanController.shared }
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Fans").font(.headline)
                Spacer()
                if control.installed {
                    Menu("Presets") {
                        Button("Automatic (macOS)") { control.applyToAll { $0.mode = .auto } }
                        Button("Quiet — ramp 65 °C → 95 °C") { control.applyToAll { $0.mode = .curve; $0.sensor = .cpu; $0.startTemp = 65; $0.fullTemp = 95 } }
                        Button("Balanced — ramp 50 °C → 85 °C") { control.applyToAll { $0.mode = .curve; $0.sensor = .cpu; $0.startTemp = 50; $0.fullTemp = 85 } }
                        Button("Cool — ramp 40 °C → 75 °C") { control.applyToAll { $0.mode = .curve; $0.sensor = .hottest; $0.startTemp = 40; $0.fullTemp = 75 } }
                        Button("Full speed") { control.applyToAll { $0.mode = .max } }
                    }
                    .fixedSize()
                }
            }
            if !control.installed {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "fan.badge.automatic").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Manual fan control").fontWeight(.medium)
                        Text("Set a fixed speed, a temperature curve or full speed. Changing fan speed needs a small helper that runs with administrator rights. It only sets fan speeds within each fan’s safe range, and fans return to automatic whenever Apex quits.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(working ? "Enabling…" : "Enable…") {
                        working = true
                        Task { await control.install(); working = false }
                    }
                    .disabled(working)
                }
            }
            ForEach(fans) { fan in
                FanRow(fan: fan, temps: temps, enabled: control.installed)
            }
            if let e = control.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            if control.installed {
                HStack {
                    Text("Fans return to automatic when Apex quits. Fan control on Apple Silicon is undocumented by Apple; if a Mac ignores a setting, it stays on automatic.")
                        .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Remove Helper…") {
                        working = true
                        Task { await control.uninstall(); working = false }
                    }
                    .controlSize(.small).disabled(working)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { control.ensureSettings(for: fans) }
    }

    private var temps: FanControl.Temps {
        .init(cpu: sensors.cpuTemp, gpu: sensors.gpuTemp, hottest: sensors.hottest?.celsius)
    }
}

private struct FanRow: View {
    let fan: FanReading
    let temps: FanControl.Temps
    let enabled: Bool
    private var control: FanController { FanController.shared }

    var body: some View {
        let setting = control.settings.first { $0.index == fan.index } ?? .init(index: fan.index)
        let binding = Binding(get: { setting }, set: { control.update($0) })
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "fan").foregroundStyle(.secondary)
                Text("Fan \(fan.index + 1)").fontWeight(.medium)
                Text("\(Int(fan.rpm)) rpm").monospacedDigit()
                Text("(\(Int(fan.minRPM))–\(Int(fan.maxRPM)))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Picker("", selection: binding.mode) {
                    ForEach(FanControl.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize().disabled(!enabled)
            }
            switch setting.mode {
            case .fixed:
                HStack {
                    Slider(value: binding.rpm, in: fan.minRPM...max(fan.minRPM + 1, fan.maxRPM), step: 100)
                    Text("\(Int(setting.rpm)) rpm").monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                .disabled(!enabled)
            case .curve:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Follow").foregroundStyle(.secondary)
                        Picker("", selection: binding.sensor) {
                            ForEach(FanControl.Sensor.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Spacer()
                        if let target = FanControl.target(setting, minRPM: fan.minRPM, maxRPM: fan.maxRPM, temps: temps),
                           let now = temps.value(setting.sensor) {
                            Text(String(format: "At %.0f °C → %d rpm", now, Int(target))).font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Start ramping at").frame(width: 120, alignment: .leading).foregroundStyle(.secondary)
                        Slider(value: binding.startTemp, in: 30...95, step: 1)
                        Text("\(Int(setting.startTemp)) °C").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                    HStack {
                        Text("Full speed at").frame(width: 120, alignment: .leading).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { max(setting.fullTemp, setting.startTemp + 1) },
                                              set: { var s = setting; s.fullTemp = max($0, s.startTemp + 1); control.update(s) }),
                               in: 31...105, step: 1)
                        Text("\(Int(max(setting.fullTemp, setting.startTemp + 1))) °C").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                .disabled(!enabled)
            case .auto, .max:
                EmptyView()
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }
}
