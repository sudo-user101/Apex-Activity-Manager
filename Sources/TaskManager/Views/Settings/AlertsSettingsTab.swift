import SwiftUI

/// Settings › Alerts: the master switch and what raises a notification.
/// Everything under the switch greys out while it's off.
struct AlertsSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var s = Alerts.shared.settings
    @State private var explaining = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(isOn: $model.alertsEnabled.animation(.easeInOut(duration: 0.2))) {
                    HStack(spacing: 6) {
                        Text("Alerts")
                        Button { explaining.toggle() } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("How alerts work")
                            .popover(isPresented: $explaining, arrowEdge: .trailing) {
                                Text("Alerts need a problem to last: an app over the limit for the time you pick, memory critical for 30s, heat for 30s. Shorter spikes are only recorded. See them in History › Events.")
                                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                                    .frame(width: 260).padding(14)
                            }
                    }
                }
                Text("A notification when a problem lasts. Shorter spikes are only recorded.").settingsCaption()
            }
            Section("Notify Me") {
                LabeledContent("When an app uses over") {
                    HStack(spacing: 6) {
                        Picker("CPU", selection: $s.cpuThreshold) { ForEach([50.0, 80, 100, 150, 200], id: \.self) { Text("\(Int($0))%").tag($0) } }
                            .labelsHidden().fixedSize()
                        Text("CPU for").foregroundStyle(.secondary)
                        Picker("Duration", selection: $s.cpuMinutes) { ForEach([1.0, 3, 5, 10], id: \.self) { Text(Fmt.duration($0 * 60)).tag($0) } }
                            .labelsHidden().fixedSize()
                    }
                }
                Toggle("Memory runs critically low", isOn: $s.memory)
                Toggle("An app’s memory keeps growing, or swap grows fast", isOn: $s.memoryGrowth)
                Toggle("Your Mac is running hot", isOn: $s.heat)
                Toggle("Your disk is almost full or filling up fast", isOn: $s.disk)
            }
            .disabled(!model.alertsEnabled)
        }
        .settingsForm()
        // History edits the same settings: start from what's saved each time.
        .onAppear { s = Alerts.shared.settings }
        .onChange(of: s) { Alerts.shared.settings = s }
    }
}
