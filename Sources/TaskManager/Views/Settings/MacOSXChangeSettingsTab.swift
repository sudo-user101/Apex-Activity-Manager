import SwiftUI

/// Settings › MacOSX Change: macOS settings System Settings hides, as plain
/// switches. Laid out like Utilities: the groups on the left (each with how
/// many are changed), the chosen group's switches on the right. Off puts
/// back what was there before. Read live from macOS.
struct MacOSXChangeSettingsTab: View {
    /// Bumped after every change so the switches re-read macOS.
    @State private var tick = 0
    @State private var confirmUndo = false
    // Test switch: APEX_MACCHANGE_GROUP=Finder opens on that group.
    @AppStorage("settingsMacChangeGroup") private var selected = ProcessInfo.processInfo.environment["APEX_MACCHANGE_GROUP"] ?? MacChanges.groups[0]

    static func symbol(_ group: String) -> (String, Color) {
        switch group {
        case "Desktop & Spaces": ("macwindow.on.rectangle", .indigo)
        case "Dock": ("dock.rectangle", .blue)
        case "Finder": ("folder.fill", .cyan)
        case "Screenshots": ("camera.viewfinder", .gray)
        case "Windows & dialogs": ("macwindow", .teal)
        case "Keyboard & typing": ("keyboard.fill", .orange)
        case "Mouse": ("computermouse.fill", .pink)
        case "Clipboard & links": ("doc.on.clipboard.fill", .green)
        case "Apps & system": ("app.badge.fill", .purple)
        default: ("gearshape.fill", .gray)
        }
    }

    /// Settings in a group that differ from what you had (switched on, or a choice moved).
    private func changed(_ g: String) -> Int {
        MacChanges.switches.filter { $0.group == g && MacChanges.isOn($0) }.count
            + MacChanges.choices.filter { $0.group == g && MacChanges.current($0) != 0 }.count
            + MacBehaviours.all.filter { $0.group == g && MacBehaviours.isOn($0.id) }.count
    }

    private var group: String { MacChanges.groups.contains(selected) ? selected : MacChanges.groups[0] }

    var body: some View {
        let _ = tick
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(MacChanges.groups, id: \.self, selection: Binding(get: { group }, set: { if let g = $0 { selected = g } })) { g in
                    HStack(spacing: 10) {
                        GroupIcon(group: g, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g)
                            let n = changed(g)
                            Text(n == 0 ? "As macOS had it" : "\(n) changed").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(g)
                }
                .listStyle(.sidebar)
                Divider()
                Button("Undo All Changes…") { confirmUndo = true }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .help("Put every setting changed here back as it was")
            }
            .frame(width: 210)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    GroupIcon(group: group, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group).font(.title2.weight(.semibold))
                        Text("Settings macOS has but doesn’t show in System Settings, and things Apex can do for you. Only for you, no password; turning one off puts back what you had.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
                Form {
                    let hidden = MacChanges.choices.contains { $0.group == group } || MacChanges.switches.contains { $0.group == group }
                    if hidden {
                        Section {
                            ForEach(MacChanges.choices.filter { $0.group == group }) { c in choice(c) }
                            ForEach(MacChanges.switches.filter { $0.group == group }) { c in toggle(c) }
                        }
                    }
                    let behaviours = MacBehaviours.all.filter { $0.group == group }
                    if !behaviours.isEmpty {
                        Section {
                            ForEach(behaviours) { b in behaviour(b) }
                        } header: {
                            Text("Apex does these while it’s open")
                        } footer: {
                            if let problem = InputTweaks.shared.lastProblem, behaviours.contains(where: { $0.usesInput && MacBehaviours.isOn($0.id) }) {
                                Text(problem).settingsCaption().foregroundStyle(.orange)
                                AccessibilityNotice()
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .id(group)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: UtilitiesSettingsTab.width, height: UtilitiesSettingsTab.height)
        .onAppear { tick += 1 }
        .confirmationDialog("Undo every change made here?", isPresented: $confirmUndo) {
            Button("Undo All Changes") { MacChanges.undoAll(); MacBehaviours.undoAll(); tick += 1 }
        } message: {
            Text("Each setting goes back to what it was before Apex changed it (or to macOS’s default), and everything Apex does here stops. The Dock and Finder may restart.")
        }
    }

    private func toggle(_ c: MacChange) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(c.title, isOn: Binding(get: { MacChanges.isOn(c) }, set: { MacChanges.set(c, on: $0); tick += 1 }))
            let caption = [c.detail, c.restart.note].filter { !$0.isEmpty }.joined(separator: " ")
            if !caption.isEmpty { Text(caption).settingsCaption() }
        }
    }

    private func behaviour(_ b: MacBehaviour) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(b.title, isOn: Binding(get: { MacBehaviours.isOn(b.id) }, set: { MacBehaviours.set(b.id, on: $0); tick += 1 }))
            Text(b.detail + (b.usesInput ? " Needs Accessibility." : "")).settingsCaption()
            if b.id == "clip.autoClear", MacBehaviours.isOn(b.id) {
                Picker("After", selection: Binding(get: { MacBehaviours.clearMinutes },
                                                   set: { UserDefaults.standard.set($0, forKey: MacBehaviours.key(b.id) + ".minutes"); tick += 1 })) {
                    ForEach([1, 2, 5, 15, 60], id: \.self) { Text("\($0) minute\($0 == 1 ? "" : "s")").tag($0) }
                }
                .padding(.top, 4)
            }
            if b.id == "keys.brightness", MacBehaviours.isOn(b.id) {
                option(b.id, "Shortcut", [("⌥⌘↑ / ⌥⌘↓", "optCmd"), ("⌘↑ / ⌘↓ (no longer jump to the top or bottom of a document)", "cmd")], fallback: "optCmd")
            }
            if b.id == "sys.headphoneVolume", MacBehaviours.isOn(b.id) {
                Picker("Lower it to", selection: Binding(get: { WindowTweaks.headphonePercent },
                                                          set: { UserDefaults.standard.set($0, forKey: MacBehaviours.key(b.id) + ".percent"); tick += 1 })) {
                    ForEach([20, 30, 40, 50, 60], id: \.self) { Text("\($0)%").tag($0) }
                }
                .padding(.top, 4)
            }
            if b.id == "ui.quitOnClose", MacBehaviours.isOn(b.id) { QuitOnCloseApps(onChange: { tick += 1 }).padding(.top, 4) }
        }
    }

    /// A behaviour's option, saved as `behaviour.<id>.keys`; the hot keys are set up again at once.
    private func option(_ id: String, _ title: String, _ options: [(String, String)], fallback: String) -> some View {
        let key = MacBehaviours.key(id) + ".keys"
        return Picker(title, selection: Binding(get: { UserDefaults.standard.string(forKey: key) ?? fallback },
                                                set: { UserDefaults.standard.set($0, forKey: key); InputTweaks.shared.apply(); tick += 1 })) {
            ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
        }
        .padding(.top, 4)
    }

    private func choice(_ c: MacChoice) -> some View {
        Picker(c.title, selection: Binding(get: { MacChanges.current(c) }, set: { MacChanges.choose(c, $0); tick += 1 })) {
            ForEach(Array(c.options.enumerated()), id: \.offset) { i, o in Text(o.title).tag(i) }
        }
    }
}

/// The apps "Quit when the last window closes" applies to.
private struct QuitOnCloseApps: View {
    var onChange: () -> Void
    @State private var apps = MacBehaviours.quitOnCloseApps

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(apps, id: \.self) { id in
                HStack(spacing: 8) {
                    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()).resizable().frame(width: 18, height: 18)
                    Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? id)
                    Spacer()
                    Button { save(apps.filter { $0 != id }) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove")
                }
            }
            HStack { Spacer(); Button("Add App…") { add() } }
        }
    }

    private func save(_ list: [String]) {
        apps = list
        UserDefaults.standard.set(list, forKey: MacBehaviours.key("ui.quitOnClose") + ".apps")
        onChange()
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        save(apps + ids.filter { !apps.contains($0) })
    }
}

/// A group's icon: its symbol in white on a rounded square, like System Settings.
private struct GroupIcon: View {
    let group: String
    var size: CGFloat
    var body: some View {
        let (symbol, color) = MacOSXChangeSettingsTab.symbol(group)
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}
