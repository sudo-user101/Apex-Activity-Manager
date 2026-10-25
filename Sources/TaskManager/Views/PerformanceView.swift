import SwiftUI

enum Resource: String, CaseIterable, Identifiable {
    case cpu, memory, disk, cloud, network, gpu, display, battery, sensors
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .cloud: return "Cloud Disks"
        case .network: return "Network"
        case .gpu: return "GPU"
        case .display: return "Display"
        case .battery: return "Energy"
        case .sensors: return "Sensors"
        }
    }
    var color: Color {
        switch self {
        case .cpu: return .blue
        case .memory: return .messageBlue
        case .disk: return .green
        case .cloud: return .cyan
        case .network: return .orange
        case .gpu: return .pink
        case .display: return .teal
        case .battery: return .green
        case .sensors: return .red
        }
    }
}

struct PerformanceView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("perfItem") private var itemKey: String = UserDefaults.standard.string(forKey: "perfResource") ?? "cpu"
    private let hardware = HardwareStore.shared

    /// The selected page; a drive or adapter that was unplugged falls back to Disk / Network.
    private func current(_ items: [PerfItem]) -> PerfItem {
        let sel = PerfItem(key: itemKey)
        if items.contains(sel) { return sel }
        switch sel {
        case .disk: return .resource(.disk)
        case .net: return .resource(.network)
        case .resource: return .resource(.cpu)
        }
    }

    var body: some View {
        let s = model.snapshot.system
        let items = PerfItem.all(s)
        let selected = current(items)
        let rows = Resource.allCases.map { PerfItem.resource($0) }
        HStack(spacing: 0) {
            GeometryReader { geo in
                // One row per resource; plugged-in drives and adapters are tabs
                // on the Storage and Network pages (DeviceSwitcher).
                let need = CGFloat(rows.count) * 62 + 12
                let listHeight = min(need, max(300, geo.size.height - 170))
                VStack(spacing: 0) {
                    // A plain stack, not a List: a List re-selects rows by position when
                    // devices are plugged in or removed. Here only a click (or ↑/↓) selects.
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(rows, id: \.self) { item in
                                SidebarRow(selected: item.resource == selected.resource) {
                                    ResourceCard(resource: item.resource)
                                }
                                .onTapGesture { if item.resource != selected.resource { itemKey = item.key } }
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    .scrollDisabled(need <= listHeight)
                    .frame(height: listHeight)
                    .focusable()
                    .focusEffectDisabled()
                    .onMoveCommand { dir in
                        guard let i = rows.firstIndex(of: .resource(selected.resource)) else { return }
                        let n = dir == .up ? i - 1 : dir == .down ? i + 1 : i
                        if rows.indices.contains(n) { itemKey = rows[n].key }
                    }
                    // An unplugged drive's page shows Disk / Network until it's back
                    // (current(_:)); the saved choice only changes when you pick a row.
                    Divider()
                    ScrollView { ThisMacPanel().padding(12) }
                }
            }
            .frame(width: 250)
            .environment(\.graphTimeline, model.graphTimeline)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                Group {
                    switch selected {
                    case .resource(.battery): EnergyDetail(store: hardware)
                    case .resource(.sensors): SensorsDetail(store: hardware)
                    case .resource(.display): DisplayDetail()
                    case .resource(.cloud): CloudDetail()
                    case .resource(.network), .net:
                        // One page per connection (Wi-Fi, Ethernet, VPN); the Network row
                        // opens the one in use.
                        if let d = NetworkPage.device(for: selected, in: s) {
                            DeviceSwitcher(selected: .net(d.id), itemKey: $itemKey)
                            NetworkPage(device: d, inUse: d.id == s.network.interface)
                        } else {
                            ResourceDetail(resource: .network)
                        }
                    case .resource(let r):
                        DeviceSwitcher(selected: selected, itemKey: $itemKey)
                        ResourceDetail(resource: r)
                    case .disk(let id):
                        DeviceSwitcher(selected: selected, itemKey: $itemKey)
                        if let d = s.storageDevices.first(where: { $0.id == id }) { StorageDeviceDetail(device: d) }
                    }
                }
                }
                .id(selected.key)                                   // a fresh page per selection…
                .transition(.opacity.combined(with: .offset(y: 6)))  // …that fades in instead of jumping
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.2), value: selected.key)
                .environment(\.graphTimeline, model.graphTimeline)
                .environment(\.advancedGraph, model.advancedGraph)
            }
        }
        .task {
            while !Task.isCancelled {
                await hardware.poll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

private struct ResourceCard: View {
    @Environment(AppModel.self) private var model
    let resource: Resource

    var body: some View {
        let s = model.snapshot.system, h = model.history
        HStack(spacing: 10) {
            Group {
                switch resource {
                case .cpu: LineGraph(series: [.init(values: h.cpu, color: resource.color)], gridLines: false, cornerRadius: 4)
                case .memory: LineGraph(series: [.init(values: h.memory, color: .messageBlue)], gridLines: false, cornerRadius: 4)
                case .disk: LineGraph(series: [.init(values: h.diskRead, color: .green), .init(values: h.diskWrite, color: .red, fill: false)], maxValue: nil, gridLines: false, cornerRadius: 4)
                case .network: LineGraph(series: [.init(values: h.netIn, color: .orange), .init(values: h.netOut, color: .blue, fill: false)], maxValue: nil, gridLines: false, cornerRadius: 4)
                case .gpu: LineGraph(series: [.init(values: h.gpu, color: resource.color)], gridLines: false, cornerRadius: 4)
                case .cloud:
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.3))
                        .overlay(Image(systemName: "icloud").font(.title3).foregroundStyle(resource.color))
                case .display:
                    // The arrangement, to scale: nothing here changes second to second.
                    DisplayArrangement(displays: DisplayStore.shared.displays)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
                case .battery: LineGraph(series: [.init(values: h.power, color: .green)],
                                         maxValue: nil, gridLines: false, cornerRadius: 4)
                case .sensors: LineGraph(series: [.init(values: HardwareStore.shared.cpuTempHistory, color: .red)], gridLines: false, cornerRadius: 4)
                    .environment(\.graphTimeline, HardwareStore.shared.timeline(minutes: model.graphMinutes))
                }
            }
            .frame(width: 64, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.title).font(.headline)
                Text(summary(s)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func summary(_ s: SystemSnapshot) -> String {
        switch resource {
        case .cpu: return Fmt.percent(s.cpu.total, decimals: 0) + "%"
        case .memory: return "\(Fmt.bytes(s.memory.used)) / \(Fmt.bytes(s.memory.total))"
        case .disk: return "R \(Fmt.rate(s.disk.readPerSec))  W \(Fmt.rate(s.disk.writePerSec))"
        case .network: return "↓ \(Fmt.rate(s.network.inPerSec))  ↑ \(Fmt.rate(s.network.outPerSec))"
        case .gpu: return s.gpu.utilization.map { Fmt.percent($0, decimals: 0) + "%" } ?? "—"
        case .cloud:
            let c = CloudStore.shared
            let on = c.onMacTotal
            return "\(c.services.count) service\(c.services.count == 1 ? "" : "s")" + (on > 0 ? " · \(Fmt.diskBytes(on)) here" : "")
        case .display:
            let n = NSScreen.screens.count
            guard let m = NSScreen.main else { return "—" }
            let size = "\(Int(m.frame.width)) × \(Int(m.frame.height))"
            return n > 1 ? "\(n) displays · \(size)" : size
        case .battery:
            let b = HardwareStore.shared.battery
            if !HardwareStore.shared.hasBattery { return b.systemPower.map { String(format: "%.1f W", $0) } ?? "—" }
            return "\(b.percent)% · " + (b.systemPower.map { String(format: "%.1f W", $0) } ?? "health \(Int(b.health.rounded()))%")
        case .sensors:
            return HardwareStore.shared.sensors.cpuTemp.map { String(format: "CPU %.0f °C", $0) } ?? "—"
        }
    }

}

enum CPUKind: String { case user = "User", system = "System" }

/// Items in the memory panel that can be graphed (click to toggle).
enum MemSeries: String, CaseIterable, Identifiable {
    case used, available, free, swap, apps, system, compressed, cache
    var id: String { rawValue }
    var title: String {
        switch self {
        case .used: return "Memory used"
        case .available: return "Available"
        case .free: return "Free"
        case .swap: return "Swap used"
        case .apps: return "Apps"
        case .system: return "Operating System Memory"
        case .compressed: return "Compressed"
        case .cache: return "Cache"
        }
    }
    var color: Color {
        switch self {
        case .used: return .messageBlue
        case .available: return .mint
        case .free: return Color(white: 0.75)
        case .swap: return .pink
        case .apps: return .windowsBlue
        case .system: return .windowsTeal
        case .compressed: return .windowsLavender
        case .cache: return .gray
        }
    }
    /// History values as % of physical RAM.
    func values(_ h: History) -> [Double] {
        switch self {
        case .used: return h.memory
        case .available: return h.memAvailable
        case .free: return h.memFree
        case .swap: return h.memSwap
        case .apps: return h.memOpen
        case .system: return h.memSystem
        case .compressed: return h.memCompressed
        case .cache: return h.memCache
        }
    }
}

/// RAM type/speed is read once per launch (~80 ms).
@MainActor enum MemorySpecCache { static var value: MemorySpec? }

private struct ResourceDetail: View {
    @State private var showHealth = false
    @State private var showDoctor = false
    @Environment(AppModel.self) private var model
    let resource: Resource
    @State private var cpuBreakdown: CPUKind?
    @State private var memSelection = Set<MemSeries>()
    @State private var memSpec: MemorySpec? = MemorySpecCache.value

    var body: some View {
        let s = model.snapshot.system, h = model.history
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: resource.title, subtitle: subtitle(s), accessory: headerAccessory, record: RecordScope.page(resource))
                .onAppear {
                    // APEX_OPEN=doctor on the Disk page opens Drive Doctor for the startup drive.
                    if resource == .disk, ProcessInfo.processInfo.environment["APEX_OPEN"] == "doctor" { showDoctor = true }
                }
                .sheet(isPresented: $showDoctor) {
                    DriveDoctorView(title: s.disk.volumeName, record: DriveHealthStore.shared.startup, usb: nil,
                                    capacity: s.disk.capacity, available: s.disk.available,
                                    volumes: [(s.disk.volumeName, "/"), ("\(s.disk.volumeName) – Data", "/System/Volumes/Data")])
                }
            switch resource {
            case .cpu:
                HStack(spacing: 8) {
                    breakdownChip(.user, .blue)
                    breakdownChip(.system, .red)
                    Text("Click the graph or a label to see which processes use it")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    RangeCaption()
                }
                GeometryReader { geo in
                    LineGraph(series: [.init(values: h.cpu, color: .red, name: "Total"), .init(values: h.cpuUser, color: .blue, name: "User")])
                        .overlay(alignment: .topLeading) {
                            // Live split, right on the graph.
                            HStack(spacing: 8) {
                                graphChip("User", s.cpu.user, .blue)
                                graphChip("System", s.cpu.system, .red)
                                graphChip("Total", s.cpu.total, .primary)
                            }
                            .padding(8)
                            .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { pt in
                            cpuBreakdown = hitTest(pt, size: geo.size, user: h.cpuUser, total: h.cpu)
                        }
                }
                .frame(height: 180)
                if let kind = cpuBreakdown {
                    CPUBreakdown(kind: kind) { cpuBreakdown = nil }
                }
                Text("Per core").font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
                    ForEach(h.perCore.indices, id: \.self) { i in
                        LineGraph(series: [.init(values: h.perCore[i], color: .blue)], gridLines: false, cornerRadius: 4)
                            .frame(height: 52)
                            .overlay(alignment: .topLeading) {
                                Text(coreLabel(i, s.cpu)).font(.caption2).foregroundStyle(.secondary).padding(4)
                            }
                    }
                }
                stats([
                    ("Utilization", Fmt.percent(s.cpu.total) + "%"),
                    ("Load average", s.cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  ")),
                    ("Cores", coresText(s.cpu)), ("Processes", "\(s.processCount)"), ("Threads", "\(s.threadCount)"),
                    ("Uptime", Fmt.duration(s.uptime)), ("Thermal state", thermal(s.thermal)),
                ])
            case .memory:
                HStack {
                    if memSelection.isEmpty {
                        legend([("RAM used", .messageBlue), ("Memory pressure: \(s.memory.pressureLevel.title)", s.memory.pressureLevel.color)])
                    } else {
                        legend(MemSeries.allCases.filter(memSelection.contains).map { ($0.title, $0.color) })
                        Button("Show default") { withAnimation(.easeOut(duration: 0.15)) { memSelection = [] } }
                            .buttonStyle(.link).font(.caption)
                    }
                    Spacer()
                    RangeCaption()
                }
                // RAM in use as a blue area; memory pressure as a line on top —
                // iMessage green while normal, yellow / red when it rises.
                LineGraph(series: memSelection.isEmpty
                          ? [.init(values: h.memory, color: .messageBlue, name: "RAM used"),
                             .init(values: h.pressure, color: s.memory.pressureLevel.color, fill: false,
                                   pointColors: h.pressureLevels.count == h.pressure.count ? h.pressureLevels.map(\.color) : nil,
                                   name: "Pressure")]
                          : MemSeries.allCases.filter(memSelection.contains).map {
                              .init(values: $0.values(h), color: $0.color, fill: memSelection.count == 1, name: $0.title)
                          },
                          maxValue: max(100, memSelection.contains(.swap) ? (visibleValues(h.memSwap, model.graphTimeline).max() ?? 0) * 1.1 : 100))
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 8) {
                            if let spec = memSpec, !spec.speed.isEmpty {
                                memChip("Speed", [spec.type, spec.speed, spec.manufacturer].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .help(spec.fromSpecSheet ? "macOS doesn’t report RAM speed on Apple Silicon; this is Apple’s specification for your chip." : "Reported by macOS")
                            }
                            memChip("Swap", "↓ \(Fmt.rate(s.memory.swapInPerSec))  ↑ \(Fmt.rate(s.memory.swapOutPerSec))")
                                .help("How fast memory is moving between RAM and the swap file right now")
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                    }
                    .frame(height: 180)
                MemoryTiles(memory: s.memory, selection: $memSelection)
            case .disk:
                HStack { legend([("Read", .green), ("Write", .red)]); Spacer(); RangeCaption() }
                LineGraph(series: [.init(values: h.diskRead, color: .green, name: "Read"), .init(values: h.diskWrite, color: .red, fill: false, name: "Write")], maxValue: nil)
                    .environment(\.graphUnit, .rate)
                    .frame(height: 180)
                let used = s.disk.capacity > s.disk.available ? s.disk.capacity - s.disk.available : 0
                StackedBar(parts: [.init(value: Double(used), color: .green)], total: Double(s.disk.capacity))
                stats([
                    ("Reading", Fmt.rate(s.disk.readPerSec)), ("Writing", Fmt.rate(s.disk.writePerSec)),
                    ("Reads per second", Fmt.count(s.disk.readOpsPerSec)),
                    ("Writes per second", Fmt.count(s.disk.writeOpsPerSec)),
                    // Amount and number of operations together: one fact each, not four look-alikes.
                    ("Read since startup", "\(Fmt.diskBytes(s.disk.totalBytesRead)) · \(Fmt.compactCount(s.disk.totalReadOps)) reads"),
                    ("Written since startup", "\(Fmt.diskBytes(s.disk.totalBytesWritten)) · \(Fmt.compactCount(s.disk.totalWriteOps)) writes"),
                    // Whole-life totals from the SSD's own health log (since it was made).
                    ("Read in its lifetime", DriveHealthStore.shared.startup?.smart.map { Fmt.diskBytes($0.dataReadBytes) } ?? "—"),
                    ("Written in its lifetime", DriveHealthStore.shared.startup?.smart.map { Fmt.diskBytes($0.dataWrittenBytes) } ?? "—"),
                    ("Capacity", Fmt.diskBytes(s.disk.capacity)), ("Available", Fmt.diskBytes(s.disk.available)),
                    ("Volume", s.disk.volumeName),
                ], extra: AnyView(DriveHealthStat(title: s.disk.volumeName, record: DriveHealthStore.shared.startup,
                                                  volumes: [(s.disk.volumeName, "/"), ("\(s.disk.volumeName) – Data", "/System/Volumes/Data")],
                                                  show: $showHealth)))

            case .network:
                HStack { legend([("Received", .orange), ("Sent", .blue)]); Spacer(); RangeCaption() }
                LineGraph(series: [.init(values: h.netIn, color: .orange, name: "Received"), .init(values: h.netOut, color: .blue, fill: false, name: "Sent")], maxValue: nil)
                    .environment(\.graphUnit, .rate)
                    .frame(height: 180)
                stats([
                    ("Receiving", Fmt.rate(s.network.inPerSec)), ("Sending", Fmt.rate(s.network.outPerSec)),
                ], extra: AnyView(Group {
                    LocalIPStat(primary: s.network.interface)
                    PublicIPStat(primary: s.network.interface)
                }))
                ConnectionDetails()
                NetworkTrafficPanel()
                PortsPanel()
            case .gpu:
                let ai = LocalAI.detect(model.snapshot.processes) { _ in nil }
                let showAI = !ai.isEmpty || h.gpuAI.contains { $0 > 0 }
                HStack { legend(showAI ? [("Whole GPU", .pink), ("Local AI", .purple)] : [("Utilization", .pink)]); Spacer(); RangeCaption() }
                LineGraph(series: [.init(values: h.gpu, color: .pink, name: "GPU")]
                          + (showAI ? [.init(values: h.gpuAI, color: .purple, fill: false, name: "Local AI")] : []))
                    .frame(height: 180)
                stats([
                    ("Utilization", s.gpu.utilization.map { Fmt.percent($0, decimals: 0) + "%" } ?? "—"),
                    ("Rendering", s.gpu.renderer.map { Fmt.percent($0, decimals: 0) + "%" } ?? "—"),
                    ("Geometry (tiler)", s.gpu.tiler.map { Fmt.percent($0, decimals: 0) + "%" } ?? "—"),
                    ("Model", s.gpu.model), ("GPU cores", s.gpu.cores > 0 ? "\(s.gpu.cores)" : "—"),
                    ("Memory in use", s.gpu.memoryInUse.map(Fmt.bytes) ?? "—"),
                    ("Memory reserved", s.gpu.memoryAllocated.map(Fmt.bytes) ?? "—"),
                    ("Temperature", HardwareStore.shared.sensors.gpuTemp.map { String(format: "%.0f °C", $0) } ?? "—"),
                    ("GPU restarts", s.gpu.recoveries.map { $0 == 0 ? "None" : "\($0)" } ?? "—"),
                ])
                if showAI { LocalAIGPUCard(runtimes: ai) }
                Text("The GPU shares the Mac’s memory with everything else, so “memory” here is system memory the graphics driver uses. Per-app figures are each app’s share of GPU time, from macOS’s GPU accounting. GPU power isn’t shown: macOS only reports it to administrator tools.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            case .battery, .sensors, .display, .cloud:
                EmptyView()
            }
            TopProcesses(resource: resource)
        }
        .task(id: resource) {
            if resource == .memory, memSpec == nil {
                let spec = await Task.detached(priority: .utility) { MemorySpec.read() }.value
                MemorySpecCache.value = spec
                memSpec = spec
            }
        }
    }

    private func memChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    private func graphChip(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 5) {
            if color != .primary { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8) }
            Text(label).foregroundStyle(.secondary)
            Text(Fmt.percent(value) + "%").fontWeight(.semibold).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    private func breakdownChip(_ kind: CPUKind, _ color: Color) -> some View {
        Button { cpuBreakdown = cpuBreakdown == kind ? nil : kind } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                Text(kind.rawValue).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(cpuBreakdown == kind ? color.opacity(0.18) : Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Blue area = user time; the red band above it = system time.
    private func hitTest(_ pt: CGPoint, size: CGSize, user: [Double], total: [Double]) -> CPUKind? {
        guard !total.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let xs = graphXs(total.count, width: size.width, timeline: model.graphTimeline)
        guard let i = xs.indices.min(by: { abs(xs[$0] - pt.x) < abs(xs[$1] - pt.x) }),
              user.indices.contains(i) else { return nil }
        let value = Double(1 - pt.y / size.height) * 100
        if value <= user[i] + 2 { return .user }
        if value <= total[i] + 4 { return .system }
        return cpuBreakdown == nil ? (user[i] >= total[i] - user[i] ? .user : .system) : nil
    }

    /// Icon buttons shown next to the time-range button for this page.
    private var headerAccessory: AnyView? {
        switch resource {
        case .memory:
            return AnyView(Button { model.showFreeMemory = true } label: {
                Image(systemName: "memorychip").foregroundStyle(Color.secondary)
            }
            .buttonStyle(.bordered)
            .help("Free Up Memory…"))
        case .disk:
            return AnyView(HStack(spacing: 8) {
                TransfersButton(volumes: ["/"])
                Button { showDoctor = true } label: { Image(systemName: "stethoscope").foregroundStyle(Color.secondary) }
                    .buttonStyle(.bordered).help("Drive Doctor: find and fix drive problems…")
                Button { model.showCleanup = true } label: { FreeSpaceIcon() }
                    .buttonStyle(.bordered).help("Free up space: Optimize, Analyze, Clean…")
            })
        default:
            return nil
        }
    }

    private func subtitle(_ s: SystemSnapshot) -> String {
        switch resource {
        case .cpu: return s.cpu.brand
        case .memory: return Fmt.bytes(s.memory.total)
        case .disk: return [s.disk.volumeName, s.disk.fileSystem].filter { !$0.isEmpty }.joined(separator: " · ")
        case .network: return s.network.interface
        case .gpu: return s.gpu.model
        case .battery, .sensors, .display, .cloud: return ""
        }
    }

    private func coreLabel(_ i: Int, _ c: CPUStats) -> String {
        // Apple Silicon numbers efficiency cores first.
        if c.efficiencyCores > 0 { return i < c.efficiencyCores ? "E\(i + 1)" : "P\(i - c.efficiencyCores + 1)" }
        return "\(i + 1)"
    }

    private func coresText(_ c: CPUStats) -> String {
        if c.performanceCores > 0 && c.efficiencyCores > 0 {
            return "\(c.performanceCores) P + \(c.efficiencyCores) E"
        }
        return "\(c.physicalCores) physical, \(c.logicalCores) logical"
    }

    private func thermal(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "—"
        }
    }

    private func legend(_ items: [(String, Color)]) -> some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(item.1).frame(width: 10, height: 10)
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stats(_ items: [(String, String)], extra: AnyView? = nil) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .topLeading)], alignment: .leading, spacing: 12) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                    Text(item.1).font(.body.weight(.medium)).monospacedDigit().lineLimit(1).truncationMode(.middle)
                }
            }
            if let extra { extra }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Local AI on the GPU page: each runtime's share of GPU time next to
/// everything else that's using the GPU right now.
private struct LocalAIGPUCard: View {
    @Environment(AppModel.self) private var model
    let runtimes: [AIRuntime]

    var body: some View {
        let others = model.snapshot.processes.filter { p in !runtimes.contains { $0.pids.contains(p.pid) } }.reduce(0) { $0 + $1.gpu }
        let aiTotal = runtimes.reduce(0) { $0 + $1.gpu }
        let total = max(aiTotal + others, 0.001)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "cpu").foregroundStyle(.purple)
                Text("Local AI on the GPU").font(.headline)
                Spacer()
                if runtimes.isEmpty { Text("Not running now").foregroundStyle(.secondary) }
            }
            if !runtimes.isEmpty {
                StackedBar(parts: runtimes.map { .init(value: $0.gpu, color: .purple) } + [.init(value: others, color: .pink.opacity(0.6))], total: total)
                ForEach(runtimes) { rt in
                    HStack(spacing: 8) {
                        Image(nsImage: rt.iconPath.isEmpty ? IconCache.shared.executable : IconCache.shared.icon(forBundle: rt.iconPath))
                            .resizable().frame(width: 16, height: 16)
                        Text(rt.name)
                        Text("\(rt.pids.count) process\(rt.pids.count == 1 ? "" : "es") · \(Fmt.bytes(rt.memory))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.percent(rt.gpu, decimals: 1) + "% of GPU time").monospacedDigit()
                        Text("(\(Int((rt.gpu / total * 100).rounded()))% of GPU use)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                HStack(spacing: 8) {
                    Circle().fill(.pink.opacity(0.6)).frame(width: 8, height: 8)
                    Text("Everything else")
                    Spacer()
                    Text(Fmt.percent(others, decimals: 1) + "% of GPU time").monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                Text("The purple line shows when a local AI runtime (Ollama, LM Studio, llama.cpp…) last used the GPU.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TopProcesses: View {
    @Environment(AppModel.self) private var model
    let resource: Resource

    var body: some View {
        let entries = top()
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Top processes").font(.subheadline).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.0.pid) { i, e in
                        HStack(spacing: 8) {
                            Image(nsImage: e.0.bundlePath.isEmpty ? IconCache.shared.executable : IconCache.shared.icon(forBundle: e.0.bundlePath))
                                .resizable().frame(width: 16, height: 16)
                            Text(e.0.name).lineLimit(1)
                            Spacer()
                            Text(e.1).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(i % 2 == 1 ? Color.primary.opacity(0.035) : .clear)
                        .processRowDetails(pid: e.0.pid)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func top() -> [(ProcessInfoSample, String)] {
        let procs = model.snapshot.processes
        let scale = model.cpuScale
        switch resource {
        case .cpu:
            return procs.sorted { $0.cpu > $1.cpu }.prefix(6).map { ($0, Fmt.percent($0.cpu * scale) + "%") }
        case .memory:
            return procs.sorted { $0.memory > $1.memory }.prefix(6).map { ($0, Fmt.bytes($0.memory)) }
        case .disk:
            return procs.sorted { $0.diskReadPerSec + $0.diskWritePerSec > $1.diskReadPerSec + $1.diskWritePerSec }
                .prefix(6).map { ($0, Fmt.rate($0.diskReadPerSec + $0.diskWritePerSec)) }
        case .gpu:
            return procs.filter { $0.gpu >= 0.1 }.sorted { $0.gpu > $1.gpu }.prefix(6).map { ($0, Fmt.percent($0.gpu, decimals: 1) + "%") }
        case .network, .battery, .sensors, .display, .cloud:
            return []   // per-process values are only collected on the Processes view
        }
    }
}

/// Processes ranked by user or system CPU, grouped like the Processes view.
private struct CPUBreakdown: View {
    @Environment(AppModel.self) private var model
    let kind: CPUKind
    let close: () -> Void

    var body: some View {
        let scale = model.cpuScale
        let value: (ProcessInfoSample) -> Double = { (kind == .user ? $0.cpuUser : $0.cpuSystem) * scale }
        let active = model.snapshot.processes.filter { value($0) >= 0.05 }
        let total = active.reduce(0) { $0 + value($1) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(kind.rawValue) CPU by process").font(.headline)
                Text("— " + (kind == .user
                    ? "time spent running the apps’ own code. Most apps use both kinds, so the same app can appear in both lists."
                    : "time macOS spends working for the app (files, network, memory, drawing). Most apps use both kinds."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).controlSize(.small)
            }
            if active.isEmpty {
                Text("Nothing is using measurable \(kind.rawValue.lowercased()) CPU right now.")
                    .foregroundStyle(.secondary)
            }
            ForEach(ProcessKind.allCases, id: \.self) { k in
                let group = active.filter { $0.kind == k }.sorted { value($0) > value($1) }
                if !group.isEmpty {
                    let sum = group.reduce(0) { $0 + value($1) }
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(k.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(Fmt.percent(sum) + "%" + (total > 0 ? "  ·  \(Int((sum / total * 100).rounded()))% of \(kind.rawValue.lowercased())" : ""))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 4)
                        ForEach(Array(group.prefix(12).enumerated()), id: \.element.pid) { i, p in
                            HStack(spacing: 8) {
                                Image(nsImage: p.bundlePath.isEmpty ? IconCache.shared.executable : IconCache.shared.icon(forBundle: p.bundlePath))
                                    .resizable().frame(width: 16, height: 16)
                                Text(p.name).lineLimit(1)
                                if p.background { Image(systemName: "leaf.fill").font(.caption).foregroundStyle(.green) }
                                Spacer()
                                // Both figures, so it's clear one app can use both kinds of CPU time.
                                Text("user \(Fmt.percent(p.cpuUser * scale))  ·  system \(Fmt.percent(p.cpuSystem * scale))")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                Text(Fmt.percent(value(p)) + "%").monospacedDigit().fontWeight(.semibold)
                                    .frame(width: 56, alignment: .trailing)
                                Button { model.end(pids: [p.pid], force: false) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.borderless).help("Quit \(p.name)")
                            }
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(i % 2 == 1 ? Color.primary.opacity(0.035) : .clear)
                            .processRowDetails(pid: p.pid)
                        }
                        if group.count > 12 {
                            Text("+ \(group.count - 12) more").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Memory panel: totals on the left, what the used
/// memory is made of on the right, pressure last. Swap opens the per-app list.
private struct MemoryTiles: View {
    let memory: MemoryStats
    @Binding var selection: Set<MemSeries>
    @State private var showSwap = false

    var body: some View {
        let m = memory
        VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(.used, "\(Fmt.bytes(m.used)) (\(Fmt.percent(m.percent, decimals: 0))%)")
                toggleRow(.available, "\(Fmt.bytes(m.total > m.used ? m.total - m.used : 0)) (\(pct(m.total > m.used ? m.total - m.used : 0)))")
                let free = m.total > m.used + m.cached ? m.total - m.used - m.cached : 0
                toggleRow(.free, "\(Fmt.bytes(free)) (\(pct(free)))")
                toggleRow(.swap, m.swapTotal > 0 ? "\(Fmt.bytes(m.swapUsed)) of \(Fmt.bytes(m.swapTotal))" : "None") {
                    Button { showSwap.toggle() } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                            .rotationEffect(.degrees(showSwap ? 180 : 0))
                            .padding(.horizontal, 2)
                    }
                    .buttonStyle(.plain)
                    .help("Show which apps are using swap")
                    .popover(isPresented: $showSwap, arrowEdge: .bottom) { SwapPopover(memory: m).frame(width: 640) }
                }
            }
            .frame(maxWidth: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(.apps, "\(Fmt.bytes(m.app)) (\(pct(m.app)))")
                toggleRow(.system, "\(Fmt.bytes(m.wired)) (\(pct(m.wired)))")
                toggleRow(.compressed, "\(Fmt.bytes(m.compressed)) (\(pct(m.compressed)))")
                toggleRow(.cache, "\(Fmt.bytes(m.cached)) (\(pct(m.cached)))")
            }
            .frame(maxWidth: .infinity)
            Divider()
            VStack(alignment: .center, spacing: 4) {
                Text("Memory pressure").foregroundStyle(.secondary)
                Text(Fmt.percent(m.pressure, decimals: 0) + "%")
                    .font(.title.weight(.semibold)).monospacedDigit().foregroundStyle(m.pressureLevel.color)
            }
            .frame(width: 150, alignment: .center)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func pct(_ v: UInt64) -> String {
        "\(Int((Double(v) / Double(max(1, memory.total)) * 100).rounded()))%"
    }

    /// A panel row that toggles its series on the graph above.
    private func toggleRow<Extra: View>(_ item: MemSeries, _ value: String,
                                        @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        let on = selection.contains(item)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(item.color).frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0.9 : 0), lineWidth: 1.5).padding(-2))
            Text(item.title).foregroundStyle(on ? .primary : .secondary).fontWeight(on ? .semibold : .regular)
                .lineLimit(1).fixedSize()
            extra()
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).monospacedDigit().lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(on ? item.color.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, -6).padding(.vertical, -3)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                if on { selection.remove(item) } else { selection.insert(item) }
            }
        }
        .help(on ? "Remove \(item.title) from the graph" : "Show \(item.title) on the graph")
    }

    private func row(_ label: String, _ value: String, dot: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit()
        }
    }
}

/// Which apps have memory compressed or in the swap file (scanned when opened;
/// results stream in as each app is checked).
private struct SwapPopover: View {
    @Environment(AppModel.self) private var model
    let memory: MemoryStats
    @State private var entries: [SwapEntry] = []
    @State private var progress: (done: Int, total: Int) = (0, 0)
    @State private var scanning = false

    var body: some View {
        let totalSwapped = entries.reduce(UInt64(0)) { $0 + $1.swapped }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Apps using swap").font(.title3).bold()
                Spacer()
                if scanning {
                    ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                        .frame(width: 110)
                    Text("\(progress.done)/\(progress.total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Button { Task { await scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .controlSize(.small)
                }
            }
            Text("How much of each app is in RAM, and how much macOS has compressed or moved to swap. macOS counts those two together per app. Helper processes are counted with their app.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("App").frame(maxWidth: .infinity, alignment: .leading)
                Text("In RAM").frame(width: 130, alignment: .trailing)
                Text("In swap").frame(width: 130, alignment: .trailing)
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                        HStack(spacing: 8) {
                            Image(nsImage: e.bundlePath.isEmpty ? IconCache.shared.executable : IconCache.shared.icon(forBundle: e.bundlePath))
                                .resizable().frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(e.name).lineLimit(1).truncationMode(.middle)
                                if e.processes > 1 {
                                    Text("\(e.processes) processes").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(Fmt.bytes(e.inRAM)) (\(Int((100 - e.swappedShare).rounded()))%)")
                                .frame(width: 130, alignment: .trailing)
                            Text("\(Fmt.bytes(e.swapped)) (\(Int(e.swappedShare.rounded()))%)")
                                .foregroundStyle(e.swappedShare > 50 ? .red : .primary)
                                .frame(width: 130, alignment: .trailing)
                        }
                        .monospacedDigit()
                        .padding(.horizontal, 8).frame(minHeight: 32)
                        .background(i % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                    }
                }
            }
            .frame(minHeight: 300, maxHeight: 520)
            .overlay {
                if entries.isEmpty {
                    if scanning {
                        Text("Checking your apps…").foregroundStyle(.secondary)
                    } else {
                        Text("None of your apps have memory in swap.").foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                if !entries.isEmpty {
                    Text("\(entries.count) apps · \(Fmt.bytes(totalSwapped)) of their data is compressed or in swap.")
                }
                Text("Sizes are before compression. In total macOS is holding \(Fmt.bytes(memory.compressorStored)) of app data in \(Fmt.bytes(memory.compressed)) of compressed memory plus \(Fmt.bytes(memory.swapUsed)) of swap file.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await scan() }
    }

    private func scan() async {
        scanning = true
        entries = []
        progress = (0, 0)
        await SwapScan.run(model.snapshot.processes) { list, done, total in
            entries = list
            progress = (done, total)
        }
        scanning = false
    }
}

/// "This Mac": device identity and the current network configuration,
/// shown compactly under the resource list.
private struct ThisMacPanel: View {
    @State private var info: DeviceInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("This Mac").font(.headline)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }
            if let d = info {
                item("Computer name", d.computerName)
                item("User name", d.fullName.isEmpty || d.fullName == d.userName ? d.userName : "\(d.userName) (\(d.fullName))")
                item("Model", d.model)
                item("System", d.osVersion)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            // Network settings rarely change; refresh every 30 s while visible.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func load() async {
        info = await Task.detached(priority: .utility) { DeviceInfo.read() }.value
    }

    private func item(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.callout).monospacedDigit()
                .textSelection(.enabled).lineLimit(3)
        }
    }
}

/// Network page: the current connection's addresses (read on demand from
/// SystemConfiguration; refreshed every 30 s while shown).
/// "Local IP" next to Receiving / Sending: the primary interface's address,
/// which interface it is, and whether it's private. Other active interfaces
/// (Ethernet + Wi-Fi, VPN tunnels) are one click away.
private struct LocalIPStat: View {
    let primary: String
    @State private var addresses: [LocalAddress] = []
    @State private var show = false

    var body: some View {
        let a = addresses.first
        Button { show.toggle() } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(a.map { "Local IP (\($0.scope.rawValue.lowercased()))" } ?? "Local IP").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Text(a?.address ?? "Not connected").font(.body.weight(.medium)).monospacedDigit()
                        .foregroundStyle(a == nil ? .secondary : .primary)
                    if let a { Text(a.kind).font(.caption).foregroundStyle(.secondary) }
                    if addresses.count > 1 {
                        Text("+\(addresses.count - 1)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(addresses.isEmpty)
        .help("This Mac’s address on its network (not the public internet address). Click for every interface.")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("This Mac’s addresses").font(.headline)
                ForEach(addresses, id: \.self) { x in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(x.kind + (x.isPrimary ? " · in use" : "")).font(.callout.weight(.medium))
                            Text("\(x.interface) · \(x.scope.rawValue)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 24)
                        Text(x.address).monospacedDigit().textSelection(.enabled)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(x.address, forType: .string) } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless).help("Copy")
                    }
                }
                Text("Private addresses only work inside your network. Your public address (next to this) is the one the internet sees, assigned by your internet provider.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(width: 380)
        }
        .task(id: primary) {
            while !Task.isCancelled {
                let list = await Task.detached(priority: .utility) { LocalAddresses.read() }.value
                if list != addresses { addresses = list }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// Network › one connection (Wi-Fi, Ethernet, VPN). Every tab is the same
/// page: graph, speeds, addresses, and the apps using that connection. The
/// router details and public IP belong to the connection the internet goes
/// through (`inUse`).
struct NetworkPage: View {
    @Environment(AppModel.self) private var model
    let device: NetworkDevice
    let inUse: Bool
    @State private var showDoctor = false

    /// The connection to show: the chosen tab, else the one in use, else the first.
    static func device(for item: PerfItem, in s: SystemSnapshot) -> NetworkDevice? {
        if case .net(let id) = item, let d = s.networkDevices.first(where: { $0.id == id }) { return d }
        return s.networkDevices.first { $0.id == s.network.interface } ?? s.networkDevices.first
    }

    var body: some View {
        let d = device
        let series = model.history.devices["net:" + d.id]
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: d.name,
                       subtitle: [d.usb?.short ?? d.connection, d.adapter == d.name ? "" : d.adapter,
                                  d.isUp ? d.linkText : "not connected", inUse ? "in use for the internet" : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "),
                       subtitleColor: d.isUp ? .secondary : .orange,
                       accessory: AnyView(
                           Button { showDoctor = true } label: { Image(systemName: "stethoscope") }
                               .buttonStyle(.bordered)
                               .help("Network Doctor: find out why the internet is slow or not working")),
                       record: .network)
                .sheet(isPresented: $showDoctor) {
                    NetworkDoctorView(device: d, primary: model.snapshot.system.network.interface)
                }
                .onAppear { if inUse, ProcessInfo.processInfo.environment["APEX_OPEN"] == "netdoctor" { showDoctor = true } }
            HStack {
                HStack(spacing: 14) {
                    ForEach([("Received", Color.orange), ("Sent", Color.blue)], id: \.0) { item in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(item.1).frame(width: 10, height: 10)
                            Text(item.0).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(); RangeCaption()
            }
            LineGraph(series: [.init(values: series?.a ?? [], color: .orange, name: "Received"),
                               .init(values: series?.b ?? [], color: .blue, fill: false, name: "Sent")], maxValue: nil)
                .environment(\.graphTimeline, deviceTimeline(series, minutes: model.graphMinutes))
                .environment(\.graphUnit, .rate)
                .frame(height: 180)
            statsGrid(stats(d),
                      extra: AnyView(Group {
                          if inUse {
                              LocalIPStat(primary: d.id)
                              PublicIPStat(primary: d.id)
                          }
                          if d.isUp && d.kind != "VPN" { SpeedStat(interface: d.id) }
                      }), extraAt: 2)
            if !d.isUp {
                Text(d.kind == "Wi-Fi" ? "Wi-Fi is off or not joined to a network."
                     : d.isPlugIn ? "The adapter is plugged in but has no network link. Check the cable or the other end."
                     : "No cable is connected to this port.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !inUse {
                Text("Connected, but internet traffic goes through \(model.snapshot.system.networkDevices.first { $0.id == model.snapshot.system.network.interface }?.name ?? "another connection"). This one is used for its own network only.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if inUse { ConnectionDetails() }
            NetworkTrafficPanel(interface: d.id)
            PortsPanel()
        }
    }

    private func stats(_ d: NetworkDevice) -> [(String, String)] {
        let since = d.isPlugIn ? "since plugged in" : d.kind == "VPN" ? "since connected" : "since startup"
        var out: [(String, String)] = [("Receiving", Fmt.rate(d.inPerSec)), ("Sending", Fmt.rate(d.outPerSec))]
        if !inUse { out.append(("Local IP", d.address.isEmpty ? "—" : d.address)) }
        out += [("Received " + since, Fmt.diskBytes(d.totalIn)), ("Sent " + since, Fmt.diskBytes(d.totalOut)),
                ("Status", d.isUp ? "Connected" : "Not connected"), ("Link speed", d.linkText.isEmpty ? "—" : d.linkText),
                ("Interface", d.id), ("Connection", d.usb?.connectedAs ?? d.connection)]
        if d.kind != "VPN", !d.hardwareAddress.isEmpty { out.append(("Hardware address", d.hardwareAddress)) }
        if let u = d.usb { out.append(("Supports", u.supports.isEmpty ? "—" : u.supports)) }
        return out
    }
}

/// "Internet connection speed": download / upload through this connection,
/// measured on request with macOS's network-quality test.
private struct SpeedStat: View {
    let interface: String
    @State private var result: SpeedResult?
    @State private var testing = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Internet connection speed").font(.caption).foregroundStyle(.secondary)
                if testing { ProgressView().controlSize(.mini) }
                else {
                    Button { test() } label: { Image(systemName: "gauge.with.needle").font(.caption) }
                        .buttonStyle(.borderless)
                        .help("Test the speed now (about 15 seconds; downloads and uploads test data)")
                }
            }
            if testing {
                Text("Testing…").font(.body.weight(.medium)).foregroundStyle(.secondary)
            } else if let r = result {
                Text("↓ \(r.downloadText)  ↑ \(r.uploadText)").font(.body.weight(.medium)).monospacedDigit()
                    .help(r.responsiveness.map { "Responsiveness: \($0) round trips a minute under load. " } ?? ""
                          + "Measured " + r.date.formatted(date: .abbreviated, time: .shortened))
                Text(r.date.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
            } else {
                Button(failed ? "Couldn’t test · Try again" : "Test speed") { test() }
                    .buttonStyle(.link).font(.body.weight(.medium))
            }
        }
        .onAppear { result = SpeedTest.saved(interface) }
        .onChange(of: interface) { result = SpeedTest.saved(interface) }
    }

    private func test() {
        testing = true; failed = false
        let i = interface
        Task {
            let r = await Task.detached(priority: .userInitiated) { SpeedTest.run(interface: i) }.value
            if let r { result = r } else { failed = true }
            testing = false
        }
    }
}

/// "Public IP": the address the internet sees. Only an outside service can
/// tell, so Apex asks one (ipify, plain HTTPS, nothing else sent) while the
/// Network page is open: again when the connection changes, else every
/// 10 minutes. Blurred by default; the eye button's choice is saved.
private struct PublicIPStat: View {
    let primary: String
    @AppStorage("blurPublicIP") private var blurred = true
    @State private var address: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Public IP").font(.caption).foregroundStyle(.secondary)
                Button { blurred.toggle() } label: {
                    Image(systemName: blurred ? "eye.slash" : "eye").font(.caption)
                }
                .buttonStyle(.borderless)
                .help(blurred ? "Show the public IP" : "Hide the public IP (kept hidden next time too)")
            }
            HStack(spacing: 5) {
                Text(address ?? (failed ? "Couldn’t check" : "Checking…"))
                    .font(.body.weight(.medium)).monospacedDigit()
                    .foregroundStyle(address == nil ? .secondary : .primary)
                    .blur(radius: blurred && address != nil ? 6 : 0)
                    .textSelection(.enabled)
                if let address, !blurred {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string) } label: {
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.borderless).help("Copy")
                }
            }
        }
        .help("The address websites see for this Mac, from your internet provider. Looked up with ipify while this page is open.")
        .task(id: primary) {
            while !Task.isCancelled {
                if let ip = await PublicIP.lookup() { address = ip; failed = false } else { failed = address == nil }
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }
}

enum PublicIP {
    /// The public IPv4 (or IPv6) address, or nil when offline / blocked.
    static func lookup() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.setValue("Apex Activity Manager", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let s = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return isAddress(s) ? s : nil
    }

    static func isAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }
}

private struct ConnectionDetails: View {
    @State private var info: DeviceInfo?
    @State private var router: RouterIdentity?
    @State private var macNetworkName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Connection").font(.headline)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }
            if let d = info {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                    item("Connected via", d.interface.isEmpty ? "Not connected"
                         : (d.interfaceName.isEmpty ? d.interface : "\(d.interfaceName) (\(d.interface))"))
                    item("MAC address", d.macAddress)
                    // The IP address is in the stats above (Local IP), not repeated here.
                    item("Subnet mask", d.subnetMask)
                    item("Gateway (router)", d.router)
                    item("Router name", router.map { $0.displayName.isEmpty ? "Not published by the router" : $0.displayName } ?? "Looking up…")
                    if let r = router, !r.modelLine.isEmpty { item("Router model", r.modelLine) }
                    if let r = router, !r.dnsName.isEmpty, !r.friendlyName.isEmpty, r.friendlyName != r.dnsName {
                        item("Router description", r.friendlyName)
                    }
                    item("This Mac’s host name", d.localHostName)
                    item("This Mac on the network", macNetworkName.map { $0.isEmpty ? "No DNS name from the router" : $0 } ?? "Looking up…")
                    item("DNS servers", d.dns.joined(separator: ", "))
                    if !d.ipv6.isEmpty { item("IPv6 address", d.ipv6) }
                    if !d.searchDomains.isEmpty { item("Search domains", d.searchDomains.joined(separator: ", ")) }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func load() async {
        let d = await Task.detached(priority: .utility) { DeviceInfo.read() }.value
        info = d
        // Names need the network: look them up after showing everything else.
        async let r = RouterLookup.identity(router: d.router)
        async let n = RouterLookup.networkName(of: d.ipv4)
        router = await r
        macNetworkName = await n
    }

    private func item(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.body.weight(.medium)).monospacedDigit()
                .textSelection(.enabled).lineLimit(2)
        }
    }
}

extension PressureLevel {
    /// Pressure colours: green = fine, yellow = under strain, red = critical.
    var color: Color { self == .normal ? .messageGreen : self == .warning ? .yellow : .red }
}


extension Color {
    /// Windows 11 accent blue (#0078D4), used for memory.
    static let windowsBlue = Color(red: 0, green: 0x78 / 255, blue: 0xD4 / 255)
    /// iMessage bubble blue and its companion green (Apple's system blue/green).
    static let messageBlue = Color(nsColor: .systemBlue)
    static let messageGreen = Color(nsColor: .systemGreen)
    /// Windows 11 teal (#00B7C3) and lavender (#8764B8) — kept away from the
    /// green / yellow / red used for memory pressure so they can't be confused.
    static let windowsTeal = Color(red: 0, green: 0xB7 / 255, blue: 0xC3 / 255)
    static let windowsLavender = Color(red: 0x87 / 255, green: 0x64 / 255, blue: 0xB8 / 255)
}

/// Large title with a quiet subtitle, and the time range on the right —
/// laid out like Apple's Health / Stocks charts.
struct PageHeader: View {
    let title: String
    var subtitle: String = ""
    var subtitleColor: Color = .secondary
    /// Optional icon buttons shown before the time-range button.
    var accessory: AnyView? = nil
    /// Pages without a graph (Display) leave out the time-range button.
    var showsRange = true
    /// This page's own Record button (records only its resource).
    var record: RecordScope? = nil

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.largeTitle.weight(.bold))
                if !subtitle.isEmpty {
                    Text(subtitle).foregroundStyle(subtitleColor).font(.callout).lineLimit(1)
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                if let accessory { accessory }
                if let record { RecordButton(scope: record, compact: true) }
                if showsRange { RangePicker() }
            }
        }
    }
}

/// Sits just above a graph, on the right: "Last 2m · recording 38s".
struct RangeCaption: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let recorded = model.history.times.first.map { Date().timeIntervalSince($0) } ?? 0
        HStack(spacing: 4) {
            Text("Last \(RangePicker.label(model.graphMinutes))")
            if recorded < model.graphMinutes * 60 - 5 {
                Text("· recording \(RangePicker.label(recorded / 60))").monospacedDigit()
            }
        }
        .font(.caption).foregroundStyle(.tertiary)
    }
}

/// Compact segmented 1m · 2m · 5m · 10m with a slider for custom lengths.
struct RangePicker: View {
    @Environment(AppModel.self) private var model
    @State private var showCustom = false
    private static let presets: [Double] = [1, 2, 5, 10]

    var body: some View {
        @Bindable var model = model
        let isPreset = Self.presets.contains(model.graphMinutes)
        // Icon only in the header; the choices live in its popover.
        Button { showCustom.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(showCustom ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.bordered)
        .help("Graph time range: last \(Self.label(model.graphMinutes))")
        .popover(isPresented: $showCustom, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Time Range").font(.headline)
                    Spacer()
                    Text("Last \(Self.label(model.graphMinutes))").monospacedDigit().foregroundStyle(.secondary)
                }
                Picker("Range", selection: Binding(get: { isPreset ? model.graphMinutes : -1 },
                                                   set: { if $0 > 0 { model.graphMinutes = $0 } })) {
                    ForEach(Self.presets, id: \.self) { Text(Fmt.duration($0 * 60)).tag($0) }
                    if !isPreset { Text("Custom").tag(-1.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Slider(value: $model.graphMinutes, in: 0.5...10, step: 0.5) {
                    EmptyView()
                } minimumValueLabel: { Text("30s").font(.caption) } maximumValueLabel: { Text("10m").font(.caption) }
                Text("Apex keeps the last 10 minutes and discards anything older.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                Toggle(isOn: $model.advancedGraph) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Advanced graph")
                        Text("Value and time axes, low · average · peak, and exact values when you point at the graph.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(14).frame(width: 300)
        }
    }

    static func label(_ m: Double) -> String { Fmt.duration(m * 60) }
    static func short(_ m: Double) -> String {
        if m < 1 { return "\(Int((m * 60).rounded()))s" }
        return m == m.rounded() ? "\(Int(m))m" : String(format: "%.1fm", m)
    }
}

/// Sidebar row with the system selection look (accent background, white text).
private struct SidebarRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 8).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 60)
            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .environment(\.sidebarSelected, selected)
            .contentShape(Rectangle())
    }
}

private struct SidebarSelectedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var sidebarSelected: Bool {
        get { self[SidebarSelectedKey.self] }
        set { self[SidebarSelectedKey.self] = newValue }
    }
}
