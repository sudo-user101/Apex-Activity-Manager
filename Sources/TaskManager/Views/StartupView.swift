import SwiftUI

/// Last loaded results, so revisiting the tab is instant.
@MainActor enum StartupCache { static var items: [StartupItem]? }

struct StartupView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [StartupItem] = StartupCache.items ?? []
    @State private var loading = StartupCache.items == nil
    @State private var busy = Set<String>()
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\StartupItem.displayName)]
    @State private var error: String?
    @State private var search = ""

    var body: some View {
        let shown = items.filter {
            search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.label.localizedCaseInsensitiveContains(search)
        }.sorted(using: sortOrder)
        Table(shown, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.displayName) { item in
                HStack(spacing: 8) {
                    Image(nsImage: item.iconPath.isEmpty ? IconCache.shared.executable : IconCache.shared.icon(forBundle: item.iconPath))
                        .resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayName).lineLimit(1)
                        Text(item.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .width(min: 220, ideal: 340)
            TableColumn("Vendor", value: \.vendor) { Text($0.vendor).foregroundStyle(.secondary) }
                .width(min: 70, ideal: 110)
            TableColumn("Kind", value: \.scope.rawValue) { Text($0.scope.rawValue).foregroundStyle(.secondary) }
                .width(min: 110, ideal: 160)
            TableColumn("Impact") { item in
                let use = impact(item)
                HStack(spacing: 5) {
                    Circle().fill(use.color).frame(width: 7, height: 7)
                    Text(use.label).foregroundStyle(item.running ? .primary : .secondary)
                }
                .help(use.detail)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Memory") { item in
                NumberCell(item.pid.flatMap { model.process($0) }.map { Fmt.bytes($0.memory) } ?? "—", bold: false)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Starts Automatically", value: \.enabledSort) { item in
                Toggle(isOn: Binding(get: { item.enabled }, set: { toggle(item, $0) })) {
                    Text(item.statusText)
                }
                .toggleStyle(.switch).controlSize(.mini)
                .disabled(busy.contains(item.id))
            }
            .width(min: 120, ideal: 140)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let item = items.first(where: { ids.contains($0.id) }) {
                Button(item.enabled ? "Disable" : "Enable") { toggle(item, !item.enabled) }
                if item.addedByTaskManager {
                    Button("Remove from Login") { remove(item) }
                }
                Button("Show Property List in Finder") { ProcessActions.reveal(path: item.plistPath) }
                if !item.program.isEmpty, FileManager.default.fileExists(atPath: item.program) {
                    Button("Show Program in Finder") { ProcessActions.reveal(path: item.program) }
                }
                Button("Copy Label") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.label, forType: .string)
                }
            }
        }
        .overlay { if loading { ProgressView() } else if items.isEmpty { ContentUnavailableView("No Startup Items", systemImage: "power") } }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .navigationSubtitle("\(items.filter(\.enabled).count) of \(items.count) enabled")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { addApp() } label: { Label("Add App…", systemImage: "plus") }
                    .help("Choose an app to open automatically when you log in")
                Button { openLoginItems() } label: { Label("Login Items Settings", systemImage: "person.crop.circle.badge.checkmark") }
                    .help("Open System Settings › General › Login Items")
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .alert("Couldn’t change startup item", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task { await load() }
    }

    /// How much the item costs right now while running (memory + CPU of its process).
    private func impact(_ item: StartupItem) -> (label: String, color: Color, detail: String) {
        guard let pid = item.pid, let p = model.process(pid) else {
            return ("Not running", .secondary.opacity(0.5), "Not running right now, so it uses nothing.")
        }
        let mb = Double(p.memory) / 1_048_576
        let detail = "Running now: \(Fmt.bytes(p.memory)) memory, \(Fmt.percent(p.cpu))% CPU"
        if mb > 300 || p.cpu > 10 { return ("High", .red, detail) }
        if mb > 80 || p.cpu > 2 { return ("Medium", .orange, detail) }
        return ("Low", .green, detail)
    }

    private func load() async {
        loading = items.isEmpty
        items = await Task.detached(priority: .userInitiated) { StartupItems.load() }.value
        StartupCache.items = items
        loading = false
    }

    private func toggle(_ item: StartupItem, _ on: Bool) {
        busy.insert(item.id)
        Task {
            let err = await Task.detached { Launchd.setEnabled(on, label: item.label, systemDomain: item.isDaemon) }.value
            busy.remove(item.id)
            if let err, err != "Cancelled" { error = err }
            if err == nil, let i = items.firstIndex(where: { $0.id == item.id }) { items[i].enabled = on; StartupCache.items = items }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Open at Login"
        panel.message = "Choose apps to open automatically when you log in."
        panel.prompt = "Add"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            let errors = await Task.detached { urls.compactMap { StartupItems.addLoginApp($0) } }.value
            if let e = errors.first { error = e }
            await load()
        }
    }

    private func remove(_ item: StartupItem) {
        Task {
            if let e = await Task.detached(operation: { StartupItems.remove(item) }).value { error = e }
            await load()
        }
    }

    private func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
