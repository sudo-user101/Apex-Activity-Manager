import SwiftUI

/// Settings › Permissions: what macOS lets Apex do, and the Bluetooth accessories.
struct PermissionsSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [AccessoryControl.BluetoothDevice] = []
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Permissions") {
                    Button("Review Permissions…") { model.showWelcome = true; model.openMainWindow?() }
                }
            }
            Section {
                if devices.isEmpty {
                    Text(loaded ? "No Bluetooth devices connected." : "Looking for devices…").foregroundStyle(.secondary)
                }
                ForEach(devices) { d in
                    Picker(d.name, selection: Binding(get: { d.type }, set: { t in
                        BluetoothTypes.set(t, for: d.address)
                        devices = AccessoryControl.bluetoothDevices()
                    })) {
                        ForEach(BluetoothType.allCases) { t in Text(t.title).tag(t) }
                    }
                }
            } header: {
                Text("Bluetooth Accessories")
            } footer: {
                Text("Pick what each device is, for Energy › Accessories.").settingsCaption()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Energy › Accessories shows a typical power figure for that type; macOS doesn’t measure accessories’ real power use.")
            }
        }
        .settingsForm()
        .animation(.easeInOut(duration: 0.2), value: devices.count)
        .task {
            devices = await Task.detached(priority: .utility) { AccessoryControl.bluetoothDevices() }.value
            loaded = true
        }
    }
}
