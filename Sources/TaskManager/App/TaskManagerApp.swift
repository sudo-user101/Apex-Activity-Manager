import AppKit
import SwiftUI
import DetectionCore

@main
struct TaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Apex Activity Manager", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1120, minHeight: 560)
        }
        .defaultSize(width: 1240, height: 760)
        .commands { AppCommands(model: model) }

        MenuBarExtra(isInserted: Binding(get: { model.showMenuBar }, set: { model.showMenuBar = $0 })) {
            MenuBarPanel().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.start()
            Alerts.shared.start()
            MemoryGuard.start()
            DeviceWatcher.shared.start()
        }
    }

    /// Keep running (menu bar, alerts, history) after the window closes,
    /// unless all background features are off.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !AppModel.shared.keepsRunningInBackground }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppModel.shared.openMainWindow?() } }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            FanController.shared.restoreAutomatic()   // fans back to macOS
            AppModel.shared.stop()
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Run New Task…") { model.showRunTask = true }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { i, s in
                Button(s.title) { model.section = s }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
            }
            Divider()
            Picker("Show Processes", selection: Binding(get: { model.processFilter }, set: { model.processFilter = $0 })) {
                ForEach(ProcessFilter.allCases) { f in Text(f.title).tag(f) }
            }
            Divider()
            Picker("Update Frequency", selection: Binding(get: { model.interval }, set: { model.interval = $0 })) {
                Text("Very Often (1s)").tag(1.0)
                Text("Often (2s)").tag(2.0)
                Text("Normally (5s)").tag(5.0)
                Text("Rarely (10s)").tag(10.0)
            }
            Divider()
        }
        CommandMenu("Process") {
            Button("Quit Process") { model.endSelected(force: false) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectedPIDs.isEmpty)
            Button("Force Quit Process") { model.endSelected(force: true) }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(model.selectedPIDs.isEmpty)
            Button("Optimize / Restore") { model.toggleOptimizeSelected() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.selectedPIDs.isEmpty)
            Button("What’s Using a File or Disk…") { model.showWhoIsUsing = true }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Divider()
            Button("Get Info") { model.showInfo() }
                .keyboardShortcut("i")
                .disabled(model.selectedPIDs.isEmpty)
            Button("Show in Finder") {
                if let p = model.selectedPIDs.first.flatMap(model.process) {
                    ProcessActions.reveal(path: p.bundlePath.isEmpty ? p.path : p.bundlePath)
                }
            }
            .keyboardShortcut("r")
            .disabled(model.selectedPIDs.isEmpty)
        }
    }
}

struct AlertSettings: View {
    @State private var s = Alerts.shared.settings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("When an app uses over")
                Picker("", selection: $s.cpuThreshold) { ForEach([50.0, 80, 100, 150, 200], id: \.self) { Text("\(Int($0))%").tag($0) } }
                    .labelsHidden().fixedSize()
                Text("CPU for")
                Picker("", selection: $s.cpuMinutes) { ForEach([1.0, 3, 5, 10], id: \.self) { Text(Fmt.duration($0 * 60)).tag($0) } }
                    .labelsHidden().fixedSize()
            }
            Toggle("When memory runs critically low", isOn: $s.memory)
            Toggle("When an app’s memory keeps growing, or swap grows fast", isOn: $s.memoryGrowth)
            Toggle("When your Mac is running hot", isOn: $s.heat)
            Toggle("When your disk is almost full or filling up fast", isOn: $s.disk)
            Toggle("Record heavy disk writing in History", isOn: $s.diskWrites)
            Toggle("Record short spikes in History", isOn: $s.recordSpikes)
            Text("Alerts need a problem to last: an app over the limit for the time you pick, memory critical for 30s, heat for 30s. Shorter spikes are only recorded. See them in History › Events.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 20)
        .onChange(of: s) { Alerts.shared.settings = s }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Update frequency:", selection: $model.interval) {
                Text("Every 1s").tag(1.0)
                Text("Every 2s").tag(2.0)
                Text("Every 5s").tag(5.0)
                Text("Every 10s").tag(10.0)
            }
            Text("Less frequent updates use less energy. Sampling pauses completely while the window is hidden or covered.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("CPU percentages:", selection: $model.cpuShareOfAllCores) {
                Text("Per core (macOS convention)").tag(false)
                Text("Share of all cores, like Windows").tag(true)
            }
            .pickerStyle(.radioGroup)

            Divider().padding(.vertical, 6)
            Toggle("Show in menu bar", isOn: $model.showMenuBar)
            Picker("Menu bar shows:", selection: $model.menuBarStyle) {
                Text("CPU").tag("cpu"); Text("Memory").tag("memory"); Text("CPU and memory").tag("both"); Text("Icon only").tag("icon")
            }
            .disabled(!model.showMenuBar)
            Toggle("Record app history", isOn: $model.historyEnabled)
            Toggle("Alerts", isOn: $model.alertsEnabled)
            AlertSettings().disabled(!model.alertsEnabled)
            Text("With the window closed, Apex keeps these running by sampling every 10s — about 1% of one core.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 500)
    }
}
