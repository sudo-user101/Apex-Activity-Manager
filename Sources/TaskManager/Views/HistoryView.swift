import SwiftUI

/// History tab: app usage over days, or the event history (alerts and spikes).
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // In the page, not the toolbar: the toolbar already holds the main tabs.
            HStack {
                Picker("Show", selection: $model.historyMode) {
                    Text("App Usage").tag("apps"); Text("Events").tag("events")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("App Usage: what used the most. Events: alerts and spikes, with why each fired.")
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 38)
            Divider()
            if model.historyMode == "events" { EventsView() } else { AppHistoryView() }
        }
    }
}

/// Windows-style "App history": which apps used the most over time.
/// Click a row for details; double-click a running app to show it in Processes.
struct AppHistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var range = 1
    @State private var search = ""
    @State private var confirmClear = false
    @AppStorage("historySortKey") private var sortKey = "cpu"
    @AppStorage("historySortAscending") private var sortAscending = false

    var body: some View {
        let _ = model.snapshot.date   // refresh as new samples are recorded
        let less = HistoryRow.comparator(sortKey)
        let rows = HistoryStore.shared.totals(days: range)
            .map { HistoryRow(id: $0.key, u: $0.usage) }
            .filter { search.isEmpty || $0.u.name.localizedCaseInsensitiveContains(search) }
            .sorted { a, b in less(a, b) ? sortAscending : (less(b, a) ? !sortAscending : a.id < b.id) }
        let usage = Dictionary(rows.map { ($0.id, $0.u) }, uniquingKeysWith: { a, _ in a })
        let range = range
        VStack(spacing: 0) {
            NativeOutline(
                rows: rows, columns: HistoryRow.columns, autosaveName: "HistoryOutline.v1",
                selection: [], sortKey: sortKey, sortAscending: sortAscending,
                isExpanded: { _ in false }, onSelect: { _ in },
                onSort: { sortKey = $0; sortAscending = $1 }, onExpand: { _, _ in },
                onDoubleClick: { key in
                    if let p = model.snapshot.processes.first(where: { $0.appKey == key }) { model.reveal(pid: p.pid) }
                },
                menu: { _ in nil },
                popover: { key in usage[key].map { AnyView(HistoryDetailPopover(key: key, usage: $0, rangeDays: range)) } })
            .overlay {
                if rows.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView("No History Yet", systemImage: "clock",
                                               description: Text("Apex records how much each app uses while it’s running — including from the menu bar."))
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
            Divider()
            HStack {
                Text(HistoryStore.shared.since.map { "Recording since " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "Recording")
                    .font(.caption).foregroundStyle(.secondary)
                Text("· click an app for details").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Clear History…") { confirmClear = true }.controlSize(.small)
            }
            .padding(.horizontal, 14).frame(height: 30).background(.bar)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Range", selection: $range) {
                    Text("Today").tag(1); Text("7 Days").tag(7); Text("30 Days").tag(30)
                }
                .pickerStyle(.segmented).fixedSize()
            }
        }
        .confirmationDialog("Clear all app history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { HistoryStore.shared.clear() }
        }
    }

    static func duration(_ s: Double) -> String { Fmt.duration(s) }
}

struct HistoryRow: OutlineRow {
    let id: String
    let u: AppUsageDay
    var children: [HistoryRow]? { nil }

    static func comparator(_ key: String) -> (HistoryRow, HistoryRow) -> Bool {
        switch key {
        case "name": return { $0.u.name.localizedStandardCompare($1.u.name) == .orderedAscending }
        case "disk": return { $0.u.diskBytes < $1.u.diskBytes }
        case "network": return { $0.u.netBytes < $1.u.netBytes }
        case "energy": return { ($0.u.energyJoules ?? 0) < ($1.u.energyJoules ?? 0) }
        case "memory": return { $0.u.peakMemory < $1.u.peakMemory }
        case "last": return { $0.u.lastSeen < $1.u.lastSeen }
        default: return { $0.u.cpuSeconds < $1.u.cpuSeconds }
        }
    }

    @MainActor static let columns: [OutlineColumn<HistoryRow>] = [
        OutlineColumn(id: "name", title: "App", width: 280, minWidth: 160, alignment: .left, defaultAscending: true,
                      canHide: false, text: { $0.u.name }, icon: { IconCache.shared.icon(forBundle: $0.u.bundlePath) }),
        OutlineColumn(id: "cpu", title: "CPU time", width: 90, text: { AppHistoryView.duration($0.u.cpuSeconds) },
                      help: "Total processor time used in the selected range."),
        OutlineColumn(id: "disk", title: "Disk", width: 90, text: { Fmt.diskBytes(UInt64($0.u.diskBytes)) }),
        OutlineColumn(id: "network", title: "Network", width: 90, text: { Fmt.diskBytes(UInt64($0.u.netBytes)) }),
        OutlineColumn(id: "energy", title: "Energy", width: 90,
                      text: { r in r.u.energyJoules.map { $0 < 360 ? String(format: "%.1f mWh", $0 / 3.6) : String(format: "%.2f Wh", $0 / 3600) } ?? "—" }),
        OutlineColumn(id: "memory", title: "Peak memory", width: 100, text: { Fmt.bytes($0.u.peakMemory) }),
        OutlineColumn(id: "last", title: "Last active", width: 120, alignment: .left,
                      text: { $0.u.lastSeen.formatted(.relative(presentation: .named)) }, secondary: true),
    ]
}
