import AppKit
import SwiftUI

struct ProcessesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("procSortKey") private var sortKey = "cpu"
    @AppStorage("procSortAscending") private var sortAscending = false

    var body: some View {
        @Bindable var model = model
        let rows = ProcessTree.cached(model.snapshot, search: model.search,
                                      cpuScale: model.cpuScale, sortKey: sortKey, ascending: sortAscending,
                                      optimized: model.optimized, filter: model.processFilter)
        VStack(spacing: 0) {
            NativeOutline(
                rows: rows, columns: ProcessColumns.all, autosaveName: "ProcessesOutline.v1",
                selection: model.processSelection, sortKey: sortKey, sortAscending: sortAscending,
                isExpanded: { id in
                    if !model.search.isEmpty { return true }
                    return id.hasPrefix("s:") ? !model.collapsed.contains(id) : model.expanded.contains(id)
                },
                onSelect: { model.processSelection = $0 },
                onSort: { sortKey = $0; sortAscending = $1 },
                onExpand: { id, open in
                    if id.hasPrefix("s:") {
                        if open { model.collapsed.remove(id) } else { model.collapsed.insert(id) }
                    } else {
                        if open { model.expanded.insert(id) } else { model.expanded.remove(id) }
                    }
                },
                onDoubleClick: { _ in model.showInspector = true },
                menu: { ids in ProcessMenu.make(model: model, pids: ProcessTree.pids(for: Set(ids), in: model.snapshot.processes)) },
                scrollTo: model.revealRequest,
                onScrolled: { model.revealRequest = nil })
            .overlay {
                if !model.hasData {
                    ProgressView("Reading processes…").controlSize(.small)
                } else if rows.isEmpty {
                    if !model.search.isEmpty {
                        ContentUnavailableView.search(text: model.search)
                    } else {
                        ContentUnavailableView("No \(model.processFilter.title)", systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("Nothing matches this filter right now."))
                    }
                }
            }
            Divider()
            SummaryBar()
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search")
        .navigationSubtitle("\(model.snapshot.system.processCount) processes")
        .toolbar { ProcessToolbar() }
        .inspector(isPresented: $model.showInspector) {
            ProcessInspector(pid: model.selectedPIDs.first)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
    }
}

enum ProcessColumns {
    @MainActor static let leaf: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(.init(paletteColors: [.systemGreen]))
        return NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "Optimized")?.withSymbolConfiguration(cfg)
    }()

    static let totalMemory = UInt64(Sysctl.int("hw.memsize") ?? 1)

    @MainActor static let pausedBadge: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(.init(paletteColors: [.systemOrange]))
        return NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "Paused")?.withSymbolConfiguration(cfg)
    }()

    @MainActor static let all: [OutlineColumn<ProcRow>] = [
        OutlineColumn(id: "name", title: "Process Name", width: 290, minWidth: 160, alignment: .left,
                      defaultAscending: true, canHide: false,
                      text: { r in
                          if r.isSection { return "\(r.name)  (\(r.count))" }
                          return r.kind == .group && !r.isApp ? "\(r.name) (\(r.count))" : r.name
                      },
                      icon: { r in
                          if r.isSection { return nil }
                          return r.iconPath.isEmpty ? IconCache.shared.executable : IconCache.shared.icon(forBundle: r.iconPath)
                      },
                      badge: { $0.paused ? pausedBadge : ($0.optimized ? leaf : nil) },
                      bold: { $0.isSection }),
        OutlineColumn(id: "cpu", title: "% CPU", width: 70, minWidth: 64, text: { Fmt.percent($0.cpu) }, bold: { $0.isSection },
                      bar: { $0.isSection ? 0 : min(1, $0.cpu / 100) }, barColor: .systemBlue,
                      help: "CPU used by the process. By default 100% = one full core (the macOS convention); Settings can switch to share of all cores."),
        OutlineColumn(id: "memory", title: "Memory", width: 84, text: { Fmt.bytes($0.memory) }, bold: { $0.isSection },
                      bar: { r in r.isSection ? 0 : min(1, Double(r.memory) / Double(max(1, ProcessColumns.totalMemory))) },
                      barColor: .systemTeal,
                      help: "Memory the process is responsible for (its footprint, the figure macOS reports), including compressed memory."),
        OutlineColumn(id: "disk", title: "Disk", width: 76, 
                      text: { $0.restricted && $0.kind == .process ? "—" : Fmt.rate($0.disk) }, bold: { $0.isSection }, help: "Bytes read + written per second by the process. Not available for other users’ processes."),
        OutlineColumn(id: "network", title: "Network", width: 76,  text: { Fmt.rate($0.net) }, bold: { $0.isSection }, help: "Bytes sent + received per second (from nettop)."),
        OutlineColumn(id: "gpu", title: "% GPU", width: 56,  text: { Fmt.percent($0.gpu) }, bold: { $0.isSection }, help: "Share of GPU time used by the process."),
        OutlineColumn(id: "threads", title: "Threads", width: 58,
                      text: { $0.restricted && $0.kind == .process ? "—" : "\($0.threads)" }, bold: { $0.isSection }),
        OutlineColumn(id: "pid", title: "PID", width: 56, defaultAscending: true, text: { $0.pid.map { String($0) } ?? "" }),
        OutlineColumn(id: "user", title: "User", width: 90, alignment: .left, defaultAscending: true,
                      text: { $0.user }, secondary: true),
    ]
}

/// Right-click menu shared by Processes and Details.
@MainActor
enum ProcessMenu {
    static func make(model: AppModel, pids: [pid_t]) -> NSMenu? {
        guard !pids.isEmpty else { return nil }
        let targets = model.withHelpers(pids)
        let isOptimized = targets.allSatisfy(model.optimized.contains)
        var items: [NSMenuItem] = [
            ClosureMenuItem(title: "Quit") { model.end(pids: pids, force: false) },
            ClosureMenuItem(title: "Force Quit") { model.end(pids: pids, force: true) },
            ClosureMenuItem(title: "Quit with Child Processes") { model.endTree(pids: model.withHelpers(pids), force: false) },
            .separator(),
            pids.allSatisfy({ model.process($0)?.state == .stopped })
                ? ClosureMenuItem(title: "Resume") { model.setPaused(pids: model.withHelpers(pids), false) }
                : ClosureMenuItem(title: "Pause") { model.setPaused(pids: model.withHelpers(pids), true) },
            isOptimized
                ? ClosureMenuItem(title: "Stop Optimizing") { model.setOptimized(pids: targets, false) }
                : ClosureMenuItem(title: "Optimize — Use Fewer Resources") { model.setOptimized(pids: targets, true) },
        ]
        let prio = NSMenuItem(title: "Priority", action: nil, keyEquivalent: "")
        prio.submenu = NSMenu.build(Priority.allCases.map { p in
            ClosureMenuItem(title: p.title) { model.setPriority(p.nice, pids: pids) }
        })
        items.append(prio)
        items.append(.separator())
        items.append(ClosureMenuItem(title: "Get Info") {
            model.processSelection = [model.process(pids[0])?.isRegularApp == true ? "a:\(pids[0])" : "p:\(pids[0])"]
            model.section = .processes
            model.showInspector = true
        })
        if let p = model.process(pids[0]), !p.path.isEmpty {
            items.append(ClosureMenuItem(title: "Show in Finder") {
                ProcessActions.reveal(path: p.bundlePath.isEmpty ? p.path : p.bundlePath)
            })
        }
        items.append(ClosureMenuItem(title: "Copy PID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pids.map(String.init).joined(separator: " "), forType: .string)
        })
        return NSMenu.build(items)
    }
}

enum Priority: Int32, CaseIterable, Identifiable {
    case high = -10, aboveNormal = -5, normal = 0, belowNormal = 5, low = 10
    var id: Int32 { rawValue }
    var nice: Int32 { rawValue }
    var title: String {
        switch self {
        case .high: return "High"
        case .aboveNormal: return "Above Normal"
        case .normal: return "Normal"
        case .belowNormal: return "Below Normal"
        case .low: return "Low"
        }
    }
}

struct ProcessToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.endSelected(force: false) } label: {
                Label("Quit Process", systemImage: "xmark.octagon")
            }
            .help("Quit the selected process (⌘⌫). Force quit: ⌥⌘⌫")
            .disabled(model.selectedPIDs.isEmpty)

            let optimizedNow = !model.selectedPIDs.isEmpty && model.selectedPIDsWithHelpers.allSatisfy(model.optimized.contains)
            Button { model.toggleOptimizeSelected() } label: {
                Label(optimizedNow ? "Stop Optimizing" : "Optimize", systemImage: optimizedNow ? "leaf.fill" : "leaf")
            }
            .help("Optimize keeps the selected app running but makes it as light as possible: efficiency cores, lowest priority, throttled disk I/O, and apps are hidden so App Nap kicks in. Its memory is the first to be compressed when RAM runs low. Click again to restore. (⇧⌘O)")
            .disabled(model.selectedPIDs.isEmpty)

            Button { model.showInspector.toggle() } label: {
                Label("Info", systemImage: model.showInspector ? "info.circle.fill" : "info.circle")
            }
            .help("Show or hide details for the selected process (⌘I)")

            Menu {
                Button("Run New Task…") { model.showRunTask = true }
                Button("What’s Using a File or Disk…") { model.showWhoIsUsing = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help("Run a new task, or find what’s using a file or disk")
        }
    }
}

/// Summary strip under the table.
struct SummaryBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot.system
        @Bindable var model = model
        HStack(spacing: 22) {
            Picker("Show", selection: $model.processFilter) {
                ForEach(ProcessFilter.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.menu).fixedSize().controlSize(.small)
            .help("Filter the process list")
            Divider().frame(height: 14)
            stat("System", Fmt.percent(s.cpu.system) + "%", .red)
            stat("User", Fmt.percent(s.cpu.user) + "%", .blue)
            stat("Idle", Fmt.percent(max(0, 100 - s.cpu.total)) + "%", .secondary)
            Divider().frame(height: 14)
            stat("Memory", Fmt.bytes(s.memory.used) + " of " + Fmt.bytes(s.memory.total), .windowsBlue)
            if !model.optimized.isEmpty {
                Label("\(model.optimized.count) optimized", systemImage: "leaf.fill")
                    .foregroundStyle(.green)
            }
            Spacer()
            stat("Threads", "\(s.threadCount)", .secondary)
            stat("Processes", "\(s.processCount)", .secondary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar)
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label + ":").foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(color == .secondary ? .primary : color)
        }
    }
}

struct NumberCell: View {
    let text: String
    let bold: Bool
    init(_ text: String, bold: Bool) { self.text = text; self.bold = bold }

    var body: some View {
        Text(text)
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
