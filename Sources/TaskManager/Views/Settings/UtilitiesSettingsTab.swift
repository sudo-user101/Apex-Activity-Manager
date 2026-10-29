import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Utilities, laid out like Mail's accounts: the utilities in a
/// list on the left (each with whether it's on), the chosen one's settings on
/// the right. A new utility only needs a case in `Utility` and its page.
struct UtilitiesSettingsTab: View {
    enum Utility: String, CaseIterable, Identifiable {
        case shelf, folderPreview, windowManager, appSwitcher, clipboard, chargeLimiter, stayAwake, cleanKeyboard
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shelf: "Drop Shelf"
            case .folderPreview: "Preview-Folder"
            case .windowManager: "Window Manager"
            case .appSwitcher: "App Switcher"
            case .clipboard: "Clipboard History"
            case .chargeLimiter: "Charge Limiter"
            case .stayAwake: "Stay Awake"
            case .cleanKeyboard: "Clean Keyboard"
            }
        }
        var symbol: String {
            switch self {
            case .shelf: "tray.and.arrow.down.fill"
            case .folderPreview: "eye.fill"
            case .windowManager: "rectangle.split.2x2.fill"
            case .appSwitcher: "square.on.square.fill"
            case .clipboard: "doc.on.clipboard.fill"
            case .chargeLimiter: "battery.75percent"
            case .stayAwake: "cup.and.saucer.fill"
            case .cleanKeyboard: "keyboard.fill"
            }
        }
        var color: Color {
            switch self {
            case .shelf: .blue
            case .folderPreview: .purple
            case .windowManager: .indigo
            case .appSwitcher: .blue
            case .clipboard: .orange
            case .chargeLimiter: .green
            case .stayAwake: .brown
            case .cleanKeyboard: .teal
            }
        }
        var blurb: String {
            switch self {
            case .shelf: "A shelf that appears while you drag files, to gather them and drop them somewhere else."
            case .folderPreview: "Look inside folders, archives and disk images from Finder without opening them, and extract, edit or make archives."
            case .windowManager: "Snap windows to halves, thirds and quarters by dragging them to an edge or with shortcuts, and save whole layouts of apps."
            case .appSwitcher: "Hold the keys and press Tab to see every open window, with previews, and jump to one. Minimized windows too."
            case .clipboard: "Your last 50 copies, in the menu bar."
            case .chargeLimiter: "Keeps the battery below a level you choose, which slows its wear."
            case .stayAwake: "Keeps this Mac from sleeping for a while."
            case .cleanKeyboard: "Locks the keyboard for a short while so you can wipe it without typing anything."
            }
        }
    }

    static var width: CGFloat { SettingsLayout.width }
    static var height: CGFloat { SettingsLayout.height }

    @Environment(AppModel.self) private var model
    // Test switch: APEX_UTILITY=clipboard opens on that utility.
    @AppStorage("settingsUtility") private var selectedRaw = ProcessInfo.processInfo.environment["APEX_UTILITY"] ?? Utility.shelf.rawValue
    // Read live from where each setting lives, so a change made elsewhere
    // (the menu bar, the Energy page) shows here at once.
    @AppStorage("floatingShelf") private var shelf = true
    @AppStorage("shelfOnAnyDrag") private var onAnyDrag = false
    @AppStorage(ShelfTrigger.keyKey) private var shelfKey = ""
    @AppStorage(ShelfHotKey.key) private var hotKeyRaw = ""
    private var hotKey: ShelfHotKey.Choice { ShelfHotKey.Choice(rawValue: hotKeyRaw) ?? .off }
    @State private var hotKeyTaken = false
    @State private var excluded = UserDefaults.standard.stringArray(forKey: ShelfTrigger.excludedKey) ?? []    // refreshed when it changes (below)
    @AppStorage(FolderPreview.enabledKey) private var folderPreview = false
    @AppStorage(FolderPreview.shortcutKey) private var folderPreviewKey = FolderPreview.Choice.optionCommandP.rawValue
    @AppStorage(FolderPreview.Keys.layout) private var previewLayout = FolderPreview.Layout.list.rawValue
    @AppStorage(FolderPreview.Keys.sort) private var previewSort = FolderPreview.Sort.size.rawValue
    @AppStorage(FolderPreview.Keys.iconSize) private var previewIcons = FolderPreview.Scale.medium.rawValue
    @AppStorage(FolderPreview.Keys.textSize) private var previewText = FolderPreview.Scale.medium.rawValue
    @AppStorage(FolderPreview.Keys.rows) private var previewRows = FolderPreview.Scale.small.rawValue
    @AppStorage(FolderPreview.Keys.window) private var previewWindow = FolderPreview.Scale.medium.rawValue
    @AppStorage(FolderPreview.Keys.foldersOnTop) private var previewFoldersOnTop = false
    @AppStorage(FolderPreview.Keys.showHidden) private var previewHidden = false
    @AppStorage(FolderPreview.Keys.doubleClickOpens) private var previewDoubleClickOpens = false
    @AppStorage(FolderPreview.Keys.archiveLimit) private var previewArchiveLimit = 2048
    @AppStorage(FolderPreview.Keys.skip) private var previewSkip = ""
    @AppStorage(FolderPreview.Keys.extractAsk) private var previewExtractAsk = false
    @AppStorage(FolderPreview.Keys.revealAfterExtract) private var previewReveal = true
    @AppStorage(FolderPreview.Keys.trashAfterExtract) private var previewTrashAfter = false
    @AppStorage(FolderPreview.Keys.newFormat) private var previewNewFormat = ArchiveTools.Format.zip.rawValue
    @State private var folderKeyTaken = false
    @AppStorage(CleanKeyboard.Keys.enabled) private var cleanKeyboard = false
    @AppStorage(WindowManager.Keys.enabled) private var windowManager = false
    @AppStorage(AppSwitcher.Keys.enabled) private var appSwitcher = false
    @AppStorage(CleanKeyboard.Keys.seconds) private var cleanSeconds = 60
    @AppStorage(CleanKeyboard.Keys.black) private var cleanBlack = true
    @AppStorage(CleanKeyboard.Keys.pointer) private var cleanPointer = false
    private var cleaner: CleanKeyboard { CleanKeyboard.shared }
    private var history: ClipboardHistory { ClipboardHistory.shared }
    /// The slider's position while it's dragged; otherwise the limit as it is.
    @State private var limitDraft: Double?
    private var limiting: Bool { fans.chargeLimit != nil }
    private var limit: Double { limitDraft ?? Double(fans.chargeLimit ?? 80) }
    @State private var awakeFor = 3600.0
    private var fans: FanController { FanController.shared }
    private var awake: KeepAwake { KeepAwake.shared }

    private var utilities: [Utility] { Utility.allCases.filter { $0 != .chargeLimiter || HardwareStore.shared.hasBattery } }
    private var selected: Utility { utilities.first { $0.rawValue == selectedRaw } ?? .shelf }

    var body: some View {
        HStack(spacing: 0) {
            List(utilities, selection: Binding(get: { selected }, set: { if let u = $0 { selectedRaw = u.rawValue } })) { u in
                HStack(spacing: 10) {
                    UtilityIcon(utility: u, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(u.title)
                        Text(status(u)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .tag(u)
            }
            .listStyle(.sidebar)
            .frame(width: 210)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    UtilityIcon(utility: selected, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected.title).font(.title2.weight(.semibold))
                        Text(selected.blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    mainSwitch(selected)
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
                Form { page(selected) }
                    .formStyle(.grouped)
                    .id(selected)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: Self.width, height: Self.height)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let now = UserDefaults.standard.stringArray(forKey: ShelfTrigger.excludedKey) ?? []
            if now != excluded { excluded = now }
        }
    }

    /// The switch in a utility's header.
    @ViewBuilder private func mainSwitch(_ u: Utility) -> some View {
        switch u {
        case .shelf:
            Toggle("Drop Shelf", isOn: Binding(get: { shelf }, set: { FloatingShelf.shared.enabled = $0 }).animation(.easeInOut(duration: 0.2)))
                .labelsHidden().toggleStyle(.switch)
        case .folderPreview:
            Toggle("Preview-Folder", isOn: $folderPreview).labelsHidden().toggleStyle(.switch)
                .onChange(of: folderPreview) { folderKeyTaken = !FolderPreview.apply() }
        case .windowManager:
            Toggle("Window Manager", isOn: Binding(get: { windowManager }, set: { windowManager = $0; if $0 { AccessibilityAccess.ask() }; WindowManager.shared.apply() }))
                .labelsHidden().toggleStyle(.switch)
        case .appSwitcher:
            Toggle("App Switcher", isOn: Binding(get: { appSwitcher }, set: { appSwitcher = $0; if $0 { AccessibilityAccess.ask() }; AppSwitcher.shared.apply() }))
                .labelsHidden().toggleStyle(.switch)
        case .clipboard:
            Toggle("Clipboard History", isOn: Binding(get: { history.enabled }, set: { history.enabled = $0 })).labelsHidden().toggleStyle(.switch)
        case .chargeLimiter:
            if fans.installed {
                Toggle("Charge Limiter", isOn: Binding(get: { limiting }, set: { fans.setChargeLimit($0 ? Int(limit) : nil) }))
                    .labelsHidden().toggleStyle(.switch)
            }
        case .stayAwake:
            EmptyView()     // started for a length of time on its page
        case .cleanKeyboard:
            Toggle("Clean Keyboard", isOn: $cleanKeyboard).labelsHidden().toggleStyle(.switch)
                .help("Shows a Clean Keyboard button in the menu bar panel")
        }
    }

    /// Under its name in the list: on, off, or what it's doing.
    private func status(_ u: Utility) -> String {
        switch u {
        case .shelf: shelf ? "On" : "Off"
        case .folderPreview: folderPreview ? "On" : "Off"
        case .windowManager: windowManager ? "On" : "Off"
        case .appSwitcher: appSwitcher ? (AppSwitcher.trigger == "command" ? "⌘Tab" : "⌥Tab") : "Off"
        case .clipboard: history.enabled ? "On" : "Off"
        case .chargeLimiter: !fans.installed ? "Not set up" : limiting ? "At \(Int(limit))%" : "Off"
        case .stayAwake: awake.isOn ? "Awake " + awake.remainingText() : "Off"
        case .cleanKeyboard: cleaner.isOn ? "Locked " + CleanKeyboard.clock(cleaner.remaining) : cleanKeyboard ? "In the menu bar" : "Off"
        }
    }

    @ViewBuilder private func page(_ u: Utility) -> some View {
        switch u {
        case .shelf: shelfPage
        case .folderPreview: folderPreviewPage
        case .windowManager: WindowManagerPage(enabled: windowManager)
        case .appSwitcher: AppSwitcherPage(enabled: appSwitcher)
        case .clipboard: clipboardPage
        case .chargeLimiter: chargeLimiterPage
        case .stayAwake: stayAwakePage
        case .cleanKeyboard: cleanKeyboardPage
        }
    }

    // MARK: Pages

    @ViewBuilder private var shelfPage: some View {
        Section("Opening it") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Show it", selection: $onAnyDrag) {
                    Text("When you shake a file you’re dragging").tag(false)
                    Text("As soon as you start dragging a file").tag(true)
                }
                Text("Each shake starts a new shelf. After its files are dropped somewhere, it closes into Recently closed.").settingsCaption()
            }
            VStack(alignment: .leading, spacing: 4) {
                Picker("Or hold a key while dragging", selection: $shelfKey) {
                    ForEach(ShelfTrigger.keys, id: \.id) { Text($0.name).tag($0.id) }
                }
                Text("Hold it at any point during the drag and the shelf opens by the pointer.").settingsCaption()
            }
            .disabled(onAnyDrag)
            VStack(alignment: .leading, spacing: 4) {
                Picker("Keyboard shortcut", selection: Binding(get: { hotKey }, set: { ShelfHotKey.shared.choice = $0; hotKeyTaken = !ShelfHotKey.shared.apply() })) {
                    ForEach(ShelfHotKey.Choice.allCases) { Text($0.title).tag($0) }
                }
                Text(hotKeyTaken ? "Another app already uses that shortcut; pick another." : "Shows the shelf by the pointer from any app, or hides it.")
                    .settingsCaption().foregroundStyle(hotKeyTaken ? .orange : .secondary)
            }
        }
        .disabled(!shelf)
        Section("Apps where it never opens") {
            if excluded.isEmpty {
                Text("No apps. Add the ones where you drag a lot, like a photo editor or a design app.").settingsCaption()
            } else {
                ForEach(excluded, id: \.self) { b in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                            Text(FileManager.default.displayName(atPath: url.path))
                        } else {
                            Text(b)
                        }
                        Spacer()
                        Button { setExcluded(excluded.filter { $0 != b }) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove")
                    }
                }
            }
            HStack { Spacer(); Button("Add App…") { addExcluded() } }
        }
        .disabled(!shelf)
    }

    @ViewBuilder private var folderPreviewPage: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Shortcut", selection: $folderPreviewKey) {
                    ForEach(FolderPreview.Choice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: folderPreviewKey) { folderKeyTaken = !FolderPreview.apply() }
                if folderKeyTaken {
                    Text("Another app already uses that shortcut; pick another.").settingsCaption().foregroundStyle(.orange)
                }
            }
            .disabled(!folderPreview)
        }
        Section("Looks") {
            Picker("Show items as", selection: $previewLayout) { ForEach(FolderPreview.Layout.allCases) { Text($0.title).tag($0.rawValue) } }
            Picker("Sort by", selection: $previewSort) { ForEach(FolderPreview.Sort.allCases) { Text($0.title).tag($0.rawValue) } }
            Picker("Icon size", selection: $previewIcons) { ForEach(FolderPreview.Scale.allCases) { Text($0.title).tag($0.rawValue) } }
            Picker("Text size", selection: $previewText) { ForEach(FolderPreview.Scale.allCases) { Text($0.title).tag($0.rawValue) } }
            Picker("Row height", selection: $previewRows) { ForEach(FolderPreview.Scale.allCases) { Text($0.title).tag($0.rawValue) } }
            Picker("Window size", selection: $previewWindow) { ForEach(FolderPreview.Scale.allCases) { Text($0.title).tag($0.rawValue) } }
        }
        .disabled(!folderPreview)
        Section("Behaviour") {
            Toggle("Keep folders on top", isOn: $previewFoldersOnTop)
            Toggle("Show hidden files", isOn: $previewHidden)
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Double-click opens folders in Finder", isOn: $previewDoubleClickOpens)
                Text("Off: double-click looks inside the folder or archive in the preview.").settingsCaption()
            }
            Picker("Ask before reading archives bigger than", selection: $previewArchiveLimit) {
                Text("500 MB").tag(500); Text("2 GB").tag(2048); Text("10 GB").tag(10_240); Text("Never ask").tag(0)
            }
            VStack(alignment: .leading, spacing: 3) {
                TextField("Don’t measure folders named", text: $previewSkip, prompt: Text("node_modules, .git"))
                Text("Their size isn’t added up, which keeps big project folders quick to preview. Separate names with commas.").settingsCaption()
            }
        }
        .disabled(!folderPreview)
        Section("Archives") {
            Picker("Extract to", selection: $previewExtractAsk) {
                Text("Next to the archive").tag(false); Text("Ask each time").tag(true)
            }
            Toggle("Show what was extracted in Finder", isOn: $previewReveal)
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Move the archive to the Trash after extracting all of it", isOn: $previewTrashAfter)
                Text("Split archives go with all their parts.").settingsCaption()
            }
            Picker("New archives", selection: $previewNewFormat) {
                ForEach(ArchiveTools.Format.allCases) { Text($0.title).tag($0.rawValue) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("In Finder").font(.callout.weight(.medium))
                Text("Right-click files › Quick Actions (or Services): Look Inside with Apex, Extract with Apex, Compress with Apex. Choose which ones show under System Settings › Keyboard › Keyboard Shortcuts › Services › Files and Folders.")
                    .settingsCaption()
                Button("Open Services Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!)
                }
            }
        }
        .disabled(!folderPreview)
        Section("How it works") {
            Text("Select a folder (or an archive) in Finder, or just have a folder open, and press the shortcut: what’s inside, with thumbnails, sizes and what takes the space, without opening it. Zip, 7z, RAR, tar, gz, ISO, disk images and 40-odd other formats show what’s in them without unpacking, archives inside archives too; password archives ask for the password. Extract all or just what you pick (one folder isn’t put in another), add to or delete from a ZIP, check for damage, and make ZIP (AES-256 password, or split into parts) or 7z. Space opens Quick Look; right-click for Open, Copy, Copy Path, Show in Finder and Move to Trash; right-click the column titles to choose columns (size, kind, dates, dimensions, tags). Finder asks once whether Apex may see what’s selected.")
                .settingsCaption()
        }
    }

    @ViewBuilder private var cleanKeyboardPage: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cleaner.isOn ? "Locked: unlocks in \(CleanKeyboard.clock(cleaner.remaining))" : "Ready")
                    Text("Starts from here or from the keyboard button in the menu bar panel (switch it on above).").settingsCaption()
                }
                Spacer()
                Button(cleaner.isOn ? "Unlock" : "Lock Keyboard Now") { cleaner.isOn ? cleaner.stop() : cleaner.start() }
            }
            if let p = cleaner.problem { Text(p).settingsCaption().foregroundStyle(.orange); AccessibilityNotice() }
        }
        Section("While cleaning") {
            Picker("Unlock after", selection: $cleanSeconds) {
                ForEach(CleanKeyboard.choices, id: \.seconds) { Text($0.title).tag($0.seconds) }
            }
            Picker("Screen", selection: $cleanBlack) {
                Text("Black, so dust and smudges show").tag(true)
                Text("A small notice at the top").tag(false)
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Lock the trackpad and mouse too", isOn: $cleanPointer)
                Text(cleanPointer ? "Nothing ends it early: it unlocks when the time is up." : "Click Done to finish early.").settingsCaption()
            }
        }
        .disabled(cleaner.isOn)
        Section("How it works") {
            Text("Every key is held back, including volume, brightness and the media keys, then everything works again when the time is up. The power button and Touch ID can’t be locked by any app, so avoid pressing them. Needs Accessibility (System Settings › Privacy & Security).")
                .settingsCaption()
        }
    }

    @ViewBuilder private var clipboardPage: some View {
        Section {
            Text("In the menu bar’s Clipboard tab. Kept in memory only; copies from password managers are never kept.").settingsCaption()
            HStack { Spacer(); Button("Clear Clipboard History") { ClipboardHistory.shared.clear() } }
        }
    }

    @ViewBuilder private var chargeLimiterPage: some View {
        Section {
            if fans.installed {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: Binding(get: { limit }, set: { limitDraft = $0 }), in: 50...100, step: 5,
                           label: { Text("Limit: \(Int(limit))%") },
                           onEditingChanged: { editing in
                               if !editing, let d = limitDraft { if limiting { fans.setChargeLimit(Int(d)) }; limitDraft = nil }
                           })
                        .disabled(!limiting)
                    Text(fans.helperRunning ? "At the limit the Mac runs from the charger and the battery rests. Schedules and night charging are on the Energy page."
                                            : "The helper isn’t running yet: open Energy › Charge Limit to finish setting it up.").settingsCaption()
                }
            } else {
                Text("It needs the Battery and Fan Helper (one password prompt). Set it up from Energy › Charge Limit.").settingsCaption()
                HStack { Spacer(); Button("Open Energy") { openEnergy() } }
            }
        }
    }

    @ViewBuilder private var stayAwakePage: some View {
        Section {
            if awake.isOn {
                HStack {
                    Text("Awake " + awake.remainingText())
                    Spacer()
                    Button("Turn Off") { awake.stop() }
                }
            } else {
                HStack {
                    Picker("Keep this Mac awake", selection: $awakeFor) {
                        Text("15 minutes").tag(900.0); Text("1 hour").tag(3600.0); Text("2 hours").tag(7200.0)
                        Text("5 hours").tag(18000.0); Text("Until turned off").tag(0.0)
                    }
                    Button("Start") { awake.start(for: awakeFor > 0 ? awakeFor : nil, keepDisplayOn: false) }
                }
            }
            Text("Day schedules and keeping chosen apps running with the lid closed are on the Energy page.").settingsCaption()
        }
    }

    // MARK: Actions

    private func openEnergy() {
        UserDefaults.standard.set("battery", forKey: "perfItem")
        model.section = .performance
        model.openMainWindow?()
    }

    private func addExcluded() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        setExcluded(excluded + ids.filter { !excluded.contains($0) })
    }

    private func setExcluded(_ list: [String]) {
        excluded = list
        UserDefaults.standard.set(list, forKey: ShelfTrigger.excludedKey)
    }
}

/// A utility's icon: its symbol in white on a rounded square of its colour,
/// like the icons in System Settings.
struct UtilityIcon: View {
    let utility: UtilitiesSettingsTab.Utility
    var size: CGFloat
    var body: some View {
        Image(systemName: utility.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(utility.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// Utilities › Window Manager's page.
private struct WindowManagerPage: View {
    let enabled: Bool
    @AppStorage(WindowManager.Keys.shortcuts) private var shortcuts = true
    @AppStorage(WindowManager.Keys.modifiers) private var modifiers = "ctrlOpt"
    @AppStorage(WindowManager.Keys.cycle) private var cycle = true
    @AppStorage(WindowManager.Keys.snapping) private var snapping = true
    @AppStorage(WindowManager.Keys.restoreOnDrag) private var restoreOnDrag = true
    @AppStorage(WindowManager.Keys.gap) private var gap = 0
    @State private var off = WindowManager.offActions
    @State private var ignored = WindowManager.ignored
    @State private var names = ["Layout 1", "Layout 2", "Layout 3", "Layout 4"]
    private var manager: WindowManager { WindowManager.shared }

    var body: some View {
        Group {
            Section("Drag to snap") {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Snap windows dragged to a screen edge", isOn: apply($snapping))
                    Text("Corners: quarters · left and right edges: halves · top: fill the screen · bottom: thirds (hold ⇧ for two thirds). A shaded outline shows where it’ll go before you let go.").settingsCaption()
                }
                Toggle("A snapped window goes back to its size when dragged away", isOn: $restoreOnDrag).disabled(!snapping)
                HStack {
                    Text("Gap between windows")
                    Slider(value: Binding(get: { Double(gap) }, set: { gap = Int($0) }), in: 0...30, step: 2)
                    Text("\(gap) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Section {
                Toggle("Keyboard shortcuts", isOn: apply($shortcuts))
                Picker("Hold", selection: apply($modifiers)) {
                    Text("⌃⌥ Control-Option").tag("ctrlOpt"); Text("⌃⌥⌘ Control-Option-Command").tag("ctrlOptCmd"); Text("⌃⌘ Control-Command").tag("ctrlCmd")
                }
                .disabled(!shortcuts)
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Press again for the next size", isOn: $cycle)
                    Text("Left or right half again: two thirds, then one third. A third again: the next third along.").settingsCaption()
                }
                .disabled(!shortcuts)
            } header: { Text("Keyboard") }
            Section {
                let groups = Dictionary(grouping: WindowAction.allCases, by: \.group)
                ForEach(["Halves", "Quarters", "Thirds", "Fourths", "Sixths", "Size", "Displays", "Many windows"], id: \.self) { g in
                    DisclosureGroup(g) {
                        ForEach(groups[g] ?? []) { a in actionRow(a) }
                    }
                }
            } header: { Text("Positions") } footer: {
                Text("Every position, with or without its own key, is also in the picker: hold the keys above and press Space, then press the key under a position or click it.").settingsCaption()
            }
            Section("Layouts") {
                ForEach(0..<4, id: \.self) { i in layoutRow(i) }
                if let m = manager.message { Text(m).settingsCaption() }
                AccessibilityNotice()
                Text("Save puts down where every open window of every app is. Put it back with ⌃⌥⌘1 to ⌃⌥⌘4 (apps that aren’t open are skipped).").settingsCaption()
            }
            Section("Apps to leave alone") {
                ForEach(ignored, id: \.self) { id in
                    HStack(spacing: 8) {
                        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                        Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()).resizable().frame(width: 18, height: 18)
                        Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? id)
                        Spacer()
                        Button { setIgnored(ignored.filter { $0 != id }) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                HStack { Text("Shortcuts and snapping skip these apps.").settingsCaption(); Spacer(); Button("Add App…") { addIgnored() } }
            }
            Section("How it works") {
                Text("Windows are moved through Accessibility (System Settings › Privacy & Security › Accessibility), as every window manager on macOS does. Some apps have a smallest size and won’t shrink below it.").settingsCaption()
            }
        }
        .disabled(!enabled)
    }

    private func actionRow(_ a: WindowAction) -> some View {
        HStack {
            Text(a.title)
            Spacer()
            if let k = a.key { Text(WindowManager.modifierLabel(modifiers) + k.label).font(.callout.monospaced()).foregroundStyle(.secondary) }
            Toggle("", isOn: Binding(get: { !off.contains(a.rawValue) }, set: { on in
                if on { off.remove(a.rawValue) } else { off.insert(a.rawValue) }
                UserDefaults.standard.set(Array(off), forKey: WindowManager.Keys.off)
                WindowManager.shared.apply()
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }

    private func layoutRow(_ i: Int) -> some View {
        let w = manager.workspaces.indices.contains(i) ? manager.workspaces[i] : nil
        let saved = (w?.places.isEmpty == false)
        return HStack {
            TextField("Name", text: $names[i]).frame(width: 130)
            Text(saved ? "\(w!.places.count) windows · ⌃⌥⌘\(i + 1)" : "Empty").settingsCaption()
            Spacer()
            Button("Save Current") { manager.saveWorkspace(i, name: names[i]) }
            Button("Put Back") { manager.restoreWorkspace(i) }.disabled(!saved)
            Button { manager.deleteWorkspace(i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(!saved)
        }
        .onAppear { if let n = w?.name, saved { names[i] = n } }
    }

    private func apply<T>(_ b: Binding<T>) -> Binding<T> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = $0; WindowManager.shared.apply() })
    }

    private func setIgnored(_ list: [String]) {
        ignored = list
        UserDefaults.standard.set(list, forKey: WindowManager.Keys.ignored)
    }

    private func addIgnored() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        setIgnored(ignored + panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }.filter { !ignored.contains($0) })
    }
}

/// Utilities › App Switcher's page.
private struct AppSwitcherPage: View {
    let enabled: Bool
    @AppStorage(AppSwitcher.Keys.trigger) private var trigger = "option"
    @AppStorage(AppSwitcher.Keys.windowsKey) private var windowsKey = false
    @AppStorage(AppSwitcher.Keys.onePerApp) private var onePerApp = false
    @AppStorage(AppSwitcher.Keys.previews) private var previews = true
    @AppStorage(AppSwitcher.Keys.minimizedLast) private var minimizedLast = true
    @AppStorage(AppSwitcher.Keys.hints) private var hints = true
    @AppStorage(AppSwitcher.Keys.delay) private var delay = 100
    @State private var screenOK = CGPreflightScreenCaptureAccess()
    private var switcher: AppSwitcher { AppSwitcher.shared }

    var body: some View {
        Group {
            Section("Keys") {
                Picker("Open it with", selection: Binding(get: { trigger }, set: { trigger = $0; AppSwitcher.shared.apply() })) {
                    Text("⌥Tab (macOS’s ⌘Tab stays as it is)").tag("option")
                    Text("⌘Tab, in place of macOS’s").tag("command")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("⌘` shows the front app’s windows", isOn: Binding(get: { windowsKey }, set: { windowsKey = $0; AppSwitcher.shared.apply() }))
                    Text("In place of macOS’s ⌘` (next window). macOS’s own shortcuts come back when this is off or Apex quits.").settingsCaption()
                }
                HStack {
                    Text("Appears after")
                    Slider(value: Binding(get: { Double(delay) }, set: { delay = Int($0) }), in: 0...400, step: 50)
                    Text("\(delay) ms").monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                Text("Hold the keys, press Tab to go along (⇧Tab or the arrows to go back), let go to switch. A quick press goes straight back to the last window. While it’s open: W closes the window, Q quits the app, H hides it, M minimizes it, Esc cancels.")
                    .settingsCaption()
                if let p = switcher.problem { Text(p).settingsCaption().foregroundStyle(.orange) }
                AccessibilityNotice()
            }
            Section("Looks") {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Live window previews", isOn: $previews)
                    if previews, !screenOK {
                        HStack {
                            Text("Needs Screen Recording; until then each window shows its app’s icon and title.").settingsCaption()
                            Spacer()
                            Button("Allow…") { PermissionCenter.shared.grant(.screenRecording); screenOK = CGPreflightScreenCaptureAccess() }
                        }
                    }
                }
                Toggle("One entry per app, with large icons", isOn: $onePerApp)
                Toggle("Minimized windows at the end", isOn: $minimizedLast)
                Toggle("Show the keys at the bottom", isOn: $hints)
            }
        }
        .disabled(!enabled)
        .onAppear { screenOK = CGPreflightScreenCaptureAccess() }
    }
}
