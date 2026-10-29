import SwiftUI

/// Settings › History: what Apex writes down for History › Apps and Events.
struct HistorySettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var s = Alerts.shared.settings

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Record app history", isOn: $model.historyEnabled)
            }
            Section {
                Toggle("Record heavy disk writing", isOn: $s.diskWrites)
                Toggle("Record network spikes", isOn: $s.network.animation(.easeInOut(duration: 0.2)))
                LabeledContent("Over") {
                    HStack(spacing: 6) {
                        Picker("Threshold", selection: $s.networkThreshold) {
                            ForEach([1_000_000.0, 5_000_000, 10_000_000, 50_000_000], id: \.self) { Text(Fmt.rate($0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Text("for").foregroundStyle(.secondary)
                        Picker("Duration", selection: $s.networkMinutes) { ForEach([1.0, 2, 5, 10], id: \.self) { Text(Fmt.duration($0 * 60)).tag($0) } }
                            .labelsHidden().fixedSize()
                    }
                }
                .disabled(!s.network)
                Toggle("Record short spikes", isOn: $s.recordSpikes)
            } header: {
                Text("Events")
            } footer: {
                // These are noticed by the same watcher as alerts, so they need it on.
                if !model.alertsEnabled {
                    Text("Recorded while Alerts is on.").settingsCaption()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(!model.alertsEnabled)
        }
        .settingsForm()
        .animation(.easeInOut(duration: 0.2), value: model.alertsEnabled)
        // Alerts edits the same settings: start from what's saved each time.
        .onAppear { s = Alerts.shared.settings }
        .onChange(of: s) { Alerts.shared.settings = s }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let now = Alerts.shared.settings
            if now != s { s = now }
        }
    }
}
