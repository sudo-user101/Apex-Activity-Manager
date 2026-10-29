import SwiftUI

/// Settings › General: how often Apex samples and how CPU is counted.
struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Updates") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Update frequency", selection: $model.interval) {
                        Text("Every 1s").tag(1.0)
                        Text("Every 2s").tag(2.0)
                        Text("Every 5s").tag(5.0)
                        Text("Every 10s").tag(10.0)
                    }
                    Text("Less often uses less energy.").settingsCaption()
                }
                .help("Sampling pauses completely while the window is hidden or covered. With the window closed, Apex keeps the menu bar, history and alerts running by sampling every 10s — about 1% of one core.")
                Picker("CPU percentages", selection: $model.cpuShareOfAllCores) {
                    Text("Per core (macOS convention)").tag(false)
                    Text("Share of all cores, like Windows").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
        }
        .settingsForm()
    }
}
