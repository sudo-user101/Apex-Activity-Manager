import SwiftUI

/// Settings › Menu Bar: the item itself and what its panel opens on.
struct MenuBarSettingsTab: View {
    @Environment(AppModel.self) private var model
    @AppStorage("menuTab") private var menuTab = "monitor"

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Menu bar item") {
                Toggle("Show in menu bar", isOn: $model.showMenuBar.animation(.easeInOut(duration: 0.2)))
                Picker("Shows", selection: $model.menuBarStyle) {
                    Text("CPU").tag("cpu"); Text("Memory").tag("memory"); Text("CPU and memory").tag("both"); Text("Icon only").tag("icon")
                }
                .disabled(!model.showMenuBar)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Panel opens on", selection: $menuTab) {
                        Text("Monitor").tag("monitor"); Text("Energy").tag("energy"); Text("Shelf").tag("shelf")
                        Text("Clipboard").tag("clipboard"); Text("Sessions").tag("sessions")
                    }
                    .disabled(!model.showMenuBar)
                    Text("Click the item once for the panel, three times for the main window.").settingsCaption()
                }
            }
        }
        .settingsForm()
    }
}
