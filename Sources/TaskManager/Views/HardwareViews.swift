import AppKit
import SwiftUI

/// Battery + sensor readings for the Performance tab, polled only while it
/// is on screen (sensors ~45 ms per read every 5 s; battery is cheap).
@MainActor
@Observable
final class HardwareStore {
    static let shared = HardwareStore()
    private(set) var battery = BatteryInfo()
    private(set) var bluetooth: [BluetoothBattery] = []
    private(set) var sensors = SensorSnapshot()
    private(set) var cpuTempHistory: [Double] = []
    private(set) var gpuTempHistory: [Double] = []
    private(set) var cpuTempTimes: [Date] = []
    private(set) var loaded = false
    /// Battery charge every minute for the last 12 hours (recorded even
    /// while the window is closed, from the regular sample).
    private(set) var chargeHistory: [Double] = []
    @ObservationIgnored private var chargeTimes: [Date] = []
    private(set) var onBatterySince: Date?
    @ObservationIgnored private var lastChargeSample = Date.distantPast
    @ObservationIgnored private var sawBattery = true
    @ObservationIgnored private var loadedCharge = false

    /// Saved so the 12-hour battery chart survives relaunches.
    private static let chargeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apex Activity Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("charge.json")
    }()
    private struct SavedCharge: Codable { var times: [Date]; var values: [Double] }

    private func loadCharge() {
        loadedCharge = true
        guard let d = try? Data(contentsOf: Self.chargeURL),
              let saved = try? JSONDecoder().decode(SavedCharge.self, from: d) else { return }
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        let keep = zip(saved.times, saved.values).filter { $0.0 >= cutoff }
        chargeTimes = keep.map(\.0)
        chargeHistory = keep.map(\.1)
    }

    private func saveCharge() {
        if let d = try? JSONEncoder().encode(SavedCharge(times: chargeTimes, values: chargeHistory)) {
            try? d.write(to: Self.chargeURL, options: .atomic)
        }
    }

    /// Called from each sample; reads the battery at most once a minute (cheap).
    func recordCharge() {
        if !loadedCharge { loadCharge() }
        guard sawBattery, Date().timeIntervalSince(lastChargeSample) >= 60 else { return }
        lastChargeSample = Date()
        let b = Battery.read()
        guard b.present, b.designCapacity > 0 else { sawBattery = false; return }
        chargeHistory.append(Double(b.percent))
        chargeTimes.append(Date())
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        while let first = chargeTimes.first, first < cutoff { chargeTimes.removeFirst(); chargeHistory.removeFirst() }
        saveCharge()
        if b.onAC { onBatterySince = nil } else if onBatterySince == nil { onBatterySince = Date() }
        if !loaded { battery = b }
    }
    @ObservationIgnored private var tick = 0

    var hasBattery: Bool { battery.present && battery.designCapacity > 0 }

    func timeline(minutes: Double) -> GraphTimeline {
        GraphTimeline(times: cpuTempTimes, window: minutes * 60, end: Date())
    }

    func poll() async {
        let doBattery = tick % 2 == 0
        tick &+= 1
        let s = await Task.detached(priority: .utility) { Sensors.shared.read() }.value
        sensors = s
        cpuTempHistory.append(s.cpuTemp ?? 0)
        gpuTempHistory.append(s.gpuTemp ?? 0)
        cpuTempTimes.append(Date())
        let cutoff = Date().addingTimeInterval(-History.window)
        while cpuTempTimes.count > 1 && cpuTempTimes[1] < cutoff {
            cpuTempTimes.removeFirst(); cpuTempHistory.removeFirst(); gpuTempHistory.removeFirst()
        }
        if doBattery || !loaded {
            let (b, bt) = await Task.detached(priority: .utility) { (Battery.read(), Battery.bluetooth()) }.value
            battery = b
            bluetooth = bt
        }
        loaded = true
    }

}

/// Energy page: which apps use
/// power (and which keep the Mac awake), plus battery charge and health.
struct EnergyDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.graphTimeline) private var timeline
    @Environment(\.advancedGraph) private var advanced
    let store: HardwareStore
    @State private var sleepBlockers: [pid_t: [String]] = [:]
    @AppStorage("energySortKey") private var sortKey = "power"
    @AppStorage("energySortAscending") private var sortAscending = false

    var body: some View {
        let b = store.battery
        let rows = EnergyRow.build(model.snapshot.processes, blockers: sleepBlockers, optimized: model.optimized,
                                   sortKey: sortKey, ascending: sortAscending)
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Energy",
                       subtitle: (store.hasBattery ? status(b) : "Power adapter")
                           + (FanController.shared.chargeLimit.map { " · charge limit \($0)%" } ?? ""),
                       accessory: AnyView(HStack(spacing: 8) {
                           AccessoriesButton(store: store)
                           if store.hasBattery { ChargeLimitButton() }
                           StayAwakeButton()
                       }), record: .energy)
            // The graphs first: with Advanced graph, the big power graph, then the
            // apps using power, then the two smaller graphs and the numbers.
            if advanced {
                PowerDetail(store: store, appsWatts: rows.filter { !$0.restricted }.reduce(0) { $0 + $1.power })
                appsTable(rows)
                graphsPanel(b)
            } else {
                graphsPanel(b)
                appsTable(rows)
            }

            if store.hasBattery {
                statGrid([
                    ("Battery health", "\(Int(b.health.rounded()))% · \(b.condition)"),
                    ("Capacity", "\(b.maxCapacity) of \(b.designCapacity) mAh"),
                    ("Charge cycles", "\(b.cycleCount) of \(b.designCycles)"),
                    (b.isCharging ? "Charging power" : "Battery power", String(format: "%.1f W", b.batteryPower)),
                    ("Temperature", b.temperature.map { String(format: "%.1f °C", $0) } ?? "—"),
                    ("Power adapter", b.onAC ? (b.adapterWatts.map { "\($0) W" + (b.adapterName.map { " · \($0)" } ?? "") } ?? "Connected") : "Not connected"),
                    ("Accessories", !AccessoryStore.shared.loaded ? "Checking…" : AccessoryStore.shared.connectedCount == 0 ? "None connected"
                        : "\(AccessoryStore.shared.connectedCount) · up to " + String(format: "%.1f W", AccessoryStore.shared.maxWatts)),
                ])
            }
            if !store.bluetooth.isEmpty {
                Text("Bluetooth devices").font(.headline)
                ForEach(store.bluetooth) { d in
                    HStack {
                        Image(systemName: "battery.75percent")
                        Text(d.name)
                        Spacer()
                        Text("\(d.percent)%").monospacedDigit().foregroundStyle(d.percent <= 20 ? .red : .primary)
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                sleepBlockers = await Task.detached(priority: .utility) { SleepAssertions.byProcess() }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder private func appsTable(_ rows: [EnergyRow]) -> some View {
            NativeOutline(rows: rows, columns: EnergyRow.columns, autosaveName: "EnergyOutline.v1",
                      selection: [], sortKey: sortKey, sortAscending: sortAscending,
                      isExpanded: { _ in false }, onSelect: { _ in },
                      onSort: { sortKey = $0; sortAscending = $1 }, onExpand: { _, _ in },
                      onDoubleClick: { id in if let pid = pid_t(id.dropFirst(2)) { model.reveal(pid: pid) } },
                      menu: { ids in ProcessMenu.make(model: model, pids: ids.compactMap { pid_t($0.dropFirst(2)) }) },
                      popover: { id in pid_t(id.dropFirst(2)).map { AnyView(ProcessDetailPopover(pid: $0)) } })
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
        Text("Power is the energy each app’s CPU work uses right now; Today is the total so far. System processes need admin rights to measure.")
            .font(.caption).foregroundStyle(.tertiary)

    }

    /// Power draw graph | battery graph | numbers.
    @ViewBuilder private func graphsPanel(_ b: BatteryInfo) -> some View {
            HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("POWER DRAW").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    RangeCaption()
                }
                let limits = PowerLevel.limits(laptop: store.hasBattery)
                let power = model.history.power
                LevelAreaGraph(values: power, colors: power.map { PowerLevel.color($0, limits) },
                               maxValue: max(limits.high * 1.25, visibleValues(power, timeline).max() ?? 0), name: "Whole Mac")
                    .environment(\.graphUnit, .watts)
                    .frame(height: 110)
                let now = b.systemPower ?? power.last ?? 0
                HStack(spacing: 6) {
                    Circle().fill(PowerLevel.color(now, limits)).frame(width: 8, height: 8)
                    Text(String(format: "Whole Mac: %.1f W · ", now) + PowerLevel.label(now, limits))
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if store.hasBattery {
                VStack(alignment: .leading, spacing: 6) {
                    Text("BATTERY (LAST 12 HOURS)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ChargeGraph(values: store.chargeHistory)
                        .frame(height: 110)
                    Text(store.chargeHistory.count < 2 ? "Recording — fills in over time" : "One point per minute")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    stat("Power mode", PowerMode.current().title)
                    stat("Charge limit", FanController.shared.chargeLimit.map { "\($0)%" + (FanController.shared.status?.chargingBlocked == true ? " · holding" : "") } ?? "Off")
                    stat(b.isCharging ? "Time until full" : "Time until empty",
                         b.minutesRemaining.map { Fmt.minutes($0) } ?? (b.fullyCharged ? "—" : "Calculating…"))
                    stat("Time on battery", store.onBatterySince.map { Fmt.duration(Date().timeIntervalSince($0)) } ?? (b.onAC ? "On power adapter" : "—"))
                }
                .frame(width: 190, alignment: .leading)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

    }

    private func status(_ b: BatteryInfo) -> String {
        if b.fullyCharged { return "Fully charged" }
        if b.isCharging { return "Charging" }
        return b.onAC ? "Plugged in, not charging" : "On battery"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium)).monospacedDigit()
        }
    }
}

/// Battery % over 12 hours (0–100), green line with soft fill.
struct ChargeGraph: View {
    let values: [Double]
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var grid = Path()
            for i in 1..<4 { let y = h * CGFloat(i) / 4; grid.move(to: .init(x: 0, y: y)); grid.addLine(to: .init(x: w, y: y)) }
            ctx.stroke(grid, with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
            guard values.count > 1 else { return }
            let step = w / 719
            var line = Path()
            for (i, v) in values.enumerated() {
                let x = w - CGFloat(values.count - 1 - i) * step, y = h - CGFloat(v / 100) * h
                if i == 0 { line.move(to: .init(x: x, y: y)) } else { line.addLine(to: .init(x: x, y: y)) }
            }
            var area = line
            area.addLine(to: .init(x: w, y: h)); area.addLine(to: .init(x: w - CGFloat(values.count - 1) * step, y: h)); area.closeSubpath()
            ctx.fill(area, with: .color(.green.opacity(0.25)))
            ctx.stroke(line, with: .color(.green), lineWidth: 1.5)
        }
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// One app (helpers included) on the Energy page.
struct EnergyRow: OutlineRow {
    let id: String
    let name: String
    let bundlePath: String
    let power: Double
    let todayWh: Double?
    let preventingSleep: Bool
    let optimized: Bool
    let restricted: Bool
    let user: String
    var children: [EnergyRow]? { nil }

    @MainActor
    static func build(_ procs: [ProcessInfoSample], blockers: [pid_t: [String]], optimized: Set<pid_t>,
                      sortKey: String, ascending: Bool) -> [EnergyRow] {
        var names: [String: String] = [:]
        for p in procs where p.isRegularApp && !p.bundlePath.isEmpty { names[p.bundlePath] = p.name }
        let today = Dictionary(HistoryStore.shared.totals(days: 1).map { ($0.key, $0.usage) }, uniquingKeysWith: { a, _ in a })
        var groups: [String: (lead: ProcessInfoSample, members: [ProcessInfoSample])] = [:]
        for p in procs {
            let key = p.bundlePath.isEmpty ? "n:\(p.name):\(p.pid)" : p.bundlePath
            if var g = groups[key] {
                g.members.append(p)
                if p.isRegularApp { g.lead = p }
                groups[key] = g
            } else { groups[key] = (p, [p]) }
        }
        let rows = groups.map { key, g -> EnergyRow in
            let historyKey = g.lead.appKey
            return EnergyRow(id: "p:\(g.lead.pid)", name: names[g.lead.bundlePath] ?? g.lead.name, bundlePath: g.lead.bundlePath,
                             power: g.members.reduce(0) { $0 + $1.power },
                             todayWh: today[historyKey]?.energyJoules.map { $0 / 3600 },
                             preventingSleep: g.members.contains { blockers[$0.pid] != nil },
                             optimized: g.members.allSatisfy { optimized.contains($0.pid) },
                             restricted: g.members.allSatisfy(\.restricted), user: g.lead.user)
        }
        .filter { $0.power > 0.0005 || $0.preventingSleep || ($0.todayWh ?? 0) > 0.0005 }
        let less: (EnergyRow, EnergyRow) -> Bool
        switch sortKey {
        case "name": less = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "today": less = { ($0.todayWh ?? 0) < ($1.todayWh ?? 0) }
        case "sleep": less = { !$0.preventingSleep && $1.preventingSleep }
        default: less = { $0.power < $1.power }
        }
        return rows.sorted { a, b in less(a, b) ? ascending : (less(b, a) ? !ascending : a.id < b.id) }
    }

    static func watts(_ w: Double) -> String {
        w < 0.001 ? "0 mW" : (w < 1 ? String(format: "%.0f mW", w * 1000) : String(format: "%.2f W", w))
    }

    @MainActor static let columns: [OutlineColumn<EnergyRow>] = [
        OutlineColumn(id: "name", title: "App", width: 260, minWidth: 150, alignment: .left, defaultAscending: true,
                      canHide: false, text: { $0.name },
                      icon: { IconCache.shared.icon(forBundle: $0.bundlePath) },
                      badge: { $0.optimized ? ProcessColumns.leaf : nil }),
        OutlineColumn(id: "power", title: "Power", width: 90, text: { $0.restricted ? "—" : watts($0.power) }),
        OutlineColumn(id: "today", title: "Today", width: 90,
                      text: { r in r.todayWh.map { $0 < 0.1 ? String(format: "%.1f mWh", $0 * 1000) : String(format: "%.2f Wh", $0) } ?? "—" }),
        OutlineColumn(id: "sleep", title: "Preventing Sleep", width: 120, alignment: .left,
                      text: { $0.preventingSleep ? "Yes" : "No" }, secondary: true),
        OutlineColumn(id: "user", title: "User", width: 90, alignment: .left, text: { $0.user }, secondary: true),
    ]
}

struct SensorsDetail: View {
    let store: HardwareStore

    var body: some View {
        let s = store.sensors
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Sensors",
                       subtitle: ProcessInfo.processInfo.thermalState == .nominal ? "Temperature normal" : "Mac is running warm",
                       subtitleColor: ProcessInfo.processInfo.thermalState == .nominal ? .secondary : .orange)
            HStack { Spacer(); RangeCaption() }
            LineGraph(series: [.init(values: store.cpuTempHistory, color: .red, name: "CPU")], maxValue: 100).frame(height: 140)
                .environment(\.graphUnit, .celsius)
                .environment(\.graphTimeline, store.timeline(minutes: AppModel.shared.graphMinutes))
            Text("CPU temperature over time (°C, 0–100)").font(.caption).foregroundStyle(.secondary)
            statGrid([
                ("CPU", s.cpuTemp.map { String(format: "%.0f °C", $0) } ?? "—"),
                ("GPU", s.gpuTemp.map { String(format: "%.0f °C", $0) } ?? "—"),
                ("System chip", s.average("System chip").map { String(format: "%.0f °C", $0) } ?? "—"),
                ("Storage", s.average("Storage").map { String(format: "%.0f °C", $0) } ?? "—"),
                ("Battery", s.average("Battery").map { String(format: "%.0f °C", $0) } ?? "—"),
                ("Hottest", s.hottest.map { String(format: "%.0f °C", $0.celsius) } ?? "—"),
            ])
            if s.fans.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fans").font(.headline)
                    Text("This Mac has no fans (or they’re not reporting), so there’s nothing to control.").foregroundStyle(.secondary)
                }
            } else {
                FanControlPanel(fans: s.fans, sensors: s)
            }
            DisclosureGroup("All \(s.temperatures.count) sensors") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(s.temperatures) { t in
                        HStack {
                            Text(t.name).lineLimit(1).font(.caption)
                            Spacer()
                            Text(String(format: "%.1f °C", t.celsius)).font(.caption).monospacedDigit()
                                .foregroundStyle(t.celsius > 90 ? .red : (t.celsius > 75 ? .orange : .secondary))
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

@ViewBuilder
func statGrid(_ items: [(String, String)], extra: AnyView? = nil) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .topLeading)], alignment: .leading, spacing: 12) {
        ForEach(items, id: \.0) { item in
            VStack(alignment: .leading, spacing: 2) {
                Text(item.0).font(.caption).foregroundStyle(.secondary)
                Text(item.1).font(.body.weight(.medium)).monospacedDigit().lineLimit(1)
            }
        }
        if let extra { extra }
    }
    .padding(14)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
}

/// Energy header icon (next to the charge limit): connected accessories and
/// the power macOS has allowed each one. Hubs and docks open into what's
/// plugged into them; drives can be ejected.
/// Wired (USB) and Bluetooth accessories, shared by the Accessories popover
/// and the Energy page's Accessories figure. Bluetooth shows devices connected
/// now plus the ones used regularly (`BluetoothUsage`).
@MainActor @Observable
final class AccessoryStore {
    static let shared = AccessoryStore()

    private(set) var usb: [USBAccessory] = []
    private(set) var drives = Set<String>()          // USB serials of drives (mass storage)
    private(set) var paired: [AccessoryControl.BluetoothDevice] = []
    private(set) var regular = Set<String>()
    private(set) var loaded = false
    @ObservationIgnored private var wasConnected = Set<String>()

    /// Connected now, or used regularly (and not removed).
    var bluetooth: [AccessoryControl.BluetoothDevice] {
        paired.filter { $0.connected || regular.contains($0.address) }
            .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }
    /// Wired devices that draw from the Mac (hubs counted by what's behind them).
    var wired: [USBAccessory] { usb.flatMap(\.flattened).filter { !$0.isHub } }
    var connectedCount: Int { wired.count + paired.filter(\.connected).count }
    /// The most connected accessories can draw: USB allowances + Bluetooth estimates (upper end).
    var maxWatts: Double {
        usb.flatMap(\.flattened).reduce(0) { $0 + $1.maxWatts }
            + paired.filter(\.connected).reduce(0) { $0 + ($1.type.typicalWatts?.upperBound ?? 0) }
    }

    func load() async {
        let list = await Task.detached(priority: .utility) { Accessories.usb() }.value
        if list != usb { usb = list }
        let ms = await Task.detached(priority: .utility) { AccessoryControl.massStorageSerials() }.value
        if ms != drives { drives = ms }
        await reloadBluetooth()
        loaded = true
    }

    func reloadBluetooth() async {
        let bt = await Task.detached(priority: .utility) { AccessoryControl.bluetoothDevices() }.value
        let connected = bt.filter(\.connected).map(\.address)
        // A removed device comes back only after it disconnects and connects again.
        BluetoothUsage.unhideIfConnected(connected.filter { !wasConnected.contains($0) && loaded })
        wasConnected = Set(connected)
        let reg = BluetoothUsage.record(connected: connected)
        if bt != paired { paired = bt }
        if reg != regular { regular = reg }
    }

    func remove(_ d: AccessoryControl.BluetoothDevice) {
        BluetoothUsage.remove(d.address)
        regular.remove(d.address)
    }
}

struct AccessoriesButton: View {
    @Environment(AppModel.self) private var model
    let store: HardwareStore
    private let acc = AccessoryStore.shared
    @State private var show = false
    @State private var expanded = Set<String>()
    @State private var message: String?
    @State private var working = Set<String>()        // devices being stopped / resumed

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "cable.connector.horizontal")
                .foregroundStyle(acc.connectedCount == 0 ? Color.secondary : Color.green)
        }
        .buttonStyle(.bordered)
        .help(acc.connectedCount == 0 ? "Accessories" : "Accessories: \(acc.connectedCount) connected, up to " + String(format: "%.1f W", acc.maxWatts))
        .popover(isPresented: $show, arrowEdge: .bottom) { popover.padding(16).frame(width: 480) }
        .task(id: model.snapshot.system.storageDevices.count) {
            while !Task.isCancelled {
                await acc.load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: show) { _, open in if open { message = nil; Task { await acc.load() } } }
    }

    private var popover: some View {
        let b = store.battery
        let usb = acc.usb, loaded = acc.loaded, bluetooth = acc.bluetooth
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Accessories").font(.headline)
                Spacer()
                if acc.connectedCount > 0 {
                    Text("\(acc.connectedCount) connected · up to " + String(format: "%.1f W", acc.maxWatts))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            section("Power adapter") {
                row("powerplug", store.hasBattery ? (b.onAC ? (b.adapterName ?? "Power adapter") : "Not connected") : "Built-in power supply",
                    detail: store.hasBattery && b.onAC ? "Supplies power to the Mac" : "",
                    value: store.hasBattery && b.onAC ? (b.adapterWatts.map { "\($0) W rated" } ?? "") : "")
            }
            section("Wired · \(acc.wired.count)") {
                if !loaded { ProgressView().controlSize(.small) }
                else if usb.isEmpty { Text("Nothing plugged in.").foregroundStyle(.secondary) }
                ForEach(usb) { usbRow($0, depth: 0) }
            }
            section("Bluetooth · \(bluetooth.filter(\.connected).count)") {
                if bluetooth.isEmpty { Text(loaded ? "Nothing connected." : "").foregroundStyle(.secondary) }
                ForEach(bluetooth) { d in
                    let battery = store.bluetooth.first { $0.name == d.name }.map { "\($0.percent)% charged" } ?? ""
                    HStack(spacing: 10) {
                        Image(systemName: d.type.symbol).frame(width: 18).foregroundStyle(d.connected ? Color.blue : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name)
                            HStack(spacing: 4) {
                                Menu {
                                    Picker("Type", selection: Binding(get: { d.type }, set: { setType($0, for: d) })) {
                                        ForEach(BluetoothType.allCases) { t in Label(t.title, systemImage: t.symbol).tag(t) }
                                    }
                                    .pickerStyle(.inline)
                                } label: {
                                    Text(d.type.title + (d.typeIsGuess ? " (guessed)" : ""))
                                }
                                .menuStyle(.borderlessButton).fixedSize()
                                .help("What this device is. Apex uses it to estimate the device’s power use.")
                                if !d.connected { Text("· not connected") }
                                if !battery.isEmpty { Text("· " + battery) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(d.connected ? (d.type.estimateText ?? "varies") : "—")
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            .help("Estimate: typical power for a \(d.type.title.lowercased()) in use. macOS doesn’t measure it.")
                        if working.contains(d.id) { ProgressView().controlSize(.small) }
                        else {
                            Button(d.connected ? "Disconnect" : "Connect") { setBluetooth(d, !d.connected) }.controlSize(.small)
                        }
                        Menu {
                            Button("Remove from Accessories") { acc.remove(d) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Remove it from this list. It stays paired with the Mac (System Settings › Bluetooth), and comes back if you start using it regularly again.")
                    }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Text("macOS doesn’t measure each accessory’s real power use: USB figures are the most each device asked for and was allowed (current × 5 V). Stop pauses a drive without unplugging it (Reconnect also brings back a drive that was ejected), Bluetooth figures are estimates for the device type you pick. Bluetooth lists what's connected plus devices you use regularly (connected on 3 different days in 2 weeks). Other USB devices can’t be paused by apps, and no Mac lets apps switch a USB port’s power off.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A device, or a hub that opens into what's plugged into it.
    private func usbRow(_ d: USBAccessory, depth: Int) -> AnyView {
        let drive = storage(for: d)
        let line = HStack(spacing: 10) {
            Image(systemName: d.isHub ? "rectangle.connected.to.line.below" : (drive != nil ? "externaldrive" : "cable.connector"))
                .frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.name)
                Text(([d.vendor, d.speed] + (d.isHub ? ["\(d.children.count) device\(d.children.count == 1 ? "" : "s")"] : []))
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(d.isHub ? String(format: "up to %.1f W in all", d.totalWatts) : (d.milliamps > 0 ? String(format: "up to %.1f W", d.maxWatts) : "Own power"))
                .monospacedDigit().foregroundStyle(.secondary)
                .help("\(d.milliamps) mA allocated of \(d.availableMilliamps) mA the port offers")
            if drive == nil, acc.drives.contains(d.serial) {
                // A drive that's plugged in but ejected: re-detect it to bring it back.
                if working.contains(d.serial) { ProgressView().controlSize(.small) }
                else {
                    Button("Reconnect") { reconnect(d) }.controlSize(.small)
                        .help("It was ejected but is still plugged in. Reconnect brings it back without unplugging it.")
                }
            }
            if let drive {
                let stopped = drive.volumes.isEmpty
                if working.contains(drive.id) { ProgressView().controlSize(.small) }
                else {
                    Button(stopped ? "Resume" : "Stop") { setDrive(drive, stop: !stopped) }
                        .controlSize(.small)
                        .help(stopped ? "Mount it again; it's still connected" : "Unmount it: it stays connected but stops reading and writing until you resume it")
                }
            }
        }
        if d.isHub && !d.children.isEmpty {
            return AnyView(DisclosureGroup(isExpanded: Binding(get: { expanded.contains(d.id) },
                                                               set: { if $0 { expanded.insert(d.id) } else { expanded.remove(d.id) } })) {
                VStack(alignment: .leading, spacing: 8) { ForEach(d.children) { usbRow($0, depth: depth + 1) } }
                    .padding(.leading, 6).padding(.top, 4)
            } label: { line })
        }
        return AnyView(line)
    }

    /// The plugged-in drive behind a USB device (same serial number), if any.
    private func storage(for d: USBAccessory) -> StorageDevice? {
        guard !d.serial.isEmpty else { return nil }
        return model.snapshot.system.storageDevices.first { $0.serial == d.serial }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ icon: String, _ name: String, detail: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func setDrive(_ d: StorageDevice, stop: Bool) {
        working.insert(d.id); message = nil
        let disk = d.id, name = d.name
        Task {
            let err = await Task.detached { stop ? AccessoryControl.stopDrive(disk) : AccessoryControl.resumeDrive(disk) }.value
            DeviceWatcher.shared.bump()
            try? await Task.sleep(for: .seconds(1.5))     // let the next sample show the new state
            message = err ?? (stop ? "“\(name)” stopped. It's still connected; Resume brings it back." : "“\(name)” resumed.")
            working.remove(disk)
        }
    }

    private func reconnect(_ d: USBAccessory) {
        working.insert(d.serial); message = nil
        let serial = d.serial, name = d.name
        Task {
            let err = await Task.detached { AccessoryControl.reconnect(serial: serial) }.value
            DeviceWatcher.shared.bump()
            try? await Task.sleep(for: .seconds(4))       // macOS re-detects and mounts it
            message = err ?? "“\(name)” reconnected."
            working.remove(serial)
            await acc.load()
        }
    }

    private func setBluetooth(_ d: AccessoryControl.BluetoothDevice, _ on: Bool) {
        working.insert(d.id); message = nil
        let address = d.address
        Task {
            let err = await Task.detached { AccessoryControl.setBluetooth(on, address: address) }.value
            await acc.reloadBluetooth()
            if let err { message = err }
            working.remove(address)
        }
    }

    private func setType(_ t: BluetoothType, for d: AccessoryControl.BluetoothDevice) {
        BluetoothTypes.set(t, for: d.address)
        Task { await acc.reloadBluetooth() }
    }
}

/// Listening ports with a one-click "free this port" (quit the owner).
struct PortsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var ports: [ListeningPort] = []
    @State private var filter = ""

    var body: some View {
        let shown = ports.filter { filter.isEmpty || "\($0.port)".hasPrefix(filter) || $0.process.localizedCaseInsensitiveContains(filter) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ports in use").font(.headline)
                Text("\(ports.count) listening").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("Port or app", text: $filter).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
                    HStack(spacing: 10) {
                        Text("\(p.port)").font(.body.monospacedDigit().weight(.semibold)).frame(width: 64, alignment: .leading)
                        Text(p.proto).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                        Image(nsImage: IconCache.shared.icon(forBundle: model.process(p.pid)?.bundlePath ?? ""))
                            .resizable().frame(width: 16, height: 16)
                        Text(p.process).lineLimit(1)
                        Text("PID \(p.pid)").font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Text(p.address).font(.caption).foregroundStyle(.secondary)
                        Button("Free Port") { model.end(pids: [p.pid], force: false) }
                            .controlSize(.small)
                            .help("Quit \(p.process) to release port \(p.port)")
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(i % 2 == 1 ? Color.primary.opacity(0.035) : .clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            Text("Shows your apps’ ports. System services’ ports need administrator rights to list.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .task {
            while !Task.isCancelled {
                let procs = model.snapshot.processes
                ports = await Task.detached(priority: .utility) { FDInspector.listeningPorts(procs) }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// "What's using this file / folder / disk?" — e.g. when a disk won't eject.
struct WhoIsUsingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var target: URL?
    @State private var users: [OpenFileUse]?
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What’s Using This?").font(.title2).bold()
            Text("Choose or drop a file, folder or disk to see which apps have it open — for example when a disk won’t eject or a file can’t be deleted.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose…", action: choose)
                if let target {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: target.path)).resizable().frame(width: 20, height: 20)
                    Text(target.path).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let t = target, (try? t.resourceValues(forKeys: [.volumeIsRemovableKey]).volumeIsRemovable) == true || t.path.hasPrefix("/Volumes/") {
                    Button("Eject") {
                        do { try NSWorkspace.shared.unmountAndEjectDevice(at: t); dismiss() }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                }
            }
            Group {
                if let users {
                    if users.isEmpty {
                        Label("Nothing of yours is using it.", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        let byPid = Dictionary(grouping: users, by: \.pid)
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(byPid.keys.sorted().enumerated()), id: \.element) { i, pid in
                                    let list = byPid[pid]!
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(nsImage: IconCache.shared.icon(forBundle: model.process(pid)?.bundlePath ?? ""))
                                            .resizable().frame(width: 20, height: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(list[0].process).fontWeight(.medium)
                                            ForEach(list.prefix(3)) { u in
                                                Text(u.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                            }
                                            if list.count > 3 { Text("+ \(list.count - 3) more").font(.caption).foregroundStyle(.tertiary) }
                                        }
                                        Spacer()
                                        Button("Quit") { model.end(pids: [pid], force: false); Task { await rescan() } }
                                    }
                                    .padding(8)
                                    .background(i % 2 == 1 ? Color.primary.opacity(0.035) : .clear)
                                }
                            }
                        }
                        .frame(maxHeight: 340)
                    }
                } else if target != nil {
                    ProgressView()
                } else {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                        .foregroundStyle(dropping ? Color.accentColor : .secondary.opacity(0.5))
                        .frame(height: 120)
                        .overlay(Text("Drop a file, folder or disk here").foregroundStyle(.secondary))
                }
            }
            Text("Only your own apps can be checked without administrator rights.").font(.caption).foregroundStyle(.tertiary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 560)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in target = url; await rescan() } }
            }
            return true
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard p.runModal() == .OK, let url = p.url else { return }
        target = url
        Task { await rescan() }
    }

    private func rescan() async {
        guard let target else { return }
        users = nil
        try? await Task.sleep(for: .milliseconds(300))
        let procs = model.snapshot.processes, path = target.path
        users = await Task.detached(priority: .userInitiated) { FDInspector.users(of: path, procs) }.value
    }
}

/// Green / yellow / red for whole-Mac power draw, like memory pressure.
enum PowerLevel {
    /// (moderate, high) watts. Laptops sip power; desktops have more headroom.
    static func limits(laptop: Bool) -> (moderate: Double, high: Double) { laptop ? (10, 20) : (40, 80) }
    static func color(_ w: Double, _ l: (moderate: Double, high: Double)) -> Color {
        w >= l.high ? .red : (w >= l.moderate ? .yellow : .green)
    }
    static func label(_ w: Double, _ l: (moderate: Double, high: Double)) -> String {
        w >= l.high ? "High" : (w >= l.moderate ? "Moderate" : "Normal")
    }
}

/// Energy with Advanced graph on: where the power comes from and goes, over
/// time. Lines: the whole Mac, the charger's input, and the battery charging
/// or draining (all from the battery controller's own telemetry).
private struct PowerDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.graphTimeline) private var timeline
    let store: HardwareStore
    let appsWatts: Double

    var body: some View {
        let h = model.history, s = model.snapshot.system
        let series: [GraphSeries] = [
            .init(values: h.power, color: .green, name: "Mac uses"),
            .init(values: h.chargerIn, color: .blue, fill: false, name: "From charger"),
            .init(values: h.batteryCharging, color: .teal, fill: false, name: "Battery charging"),
            .init(values: h.batteryDraining, color: .orange, fill: false, name: "Battery draining"),
        ].filter { s in s.name == "Mac uses" || s.values.contains { $0 > 0.05 } }
        let mac = s.systemPower ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("POWER IN DETAIL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                RangeCaption()
            }
            HStack(spacing: 16) {
                chip("Mac uses", mac, .green)
                if let c = s.chargerPower, c > 0.05 { chip("From charger", c, .blue) }
                if let f = s.batteryFlow, abs(f) > 0.05 { chip(f > 0 ? "Battery charging" : "Battery draining", abs(f), f > 0 ? .teal : .orange) }
            }
            LineGraph(series: series, maxValue: nil)
                .environment(\.graphUnit, .watts)
                .frame(height: 190)
            // Where it goes: apps' CPU work (measured per app) vs everything else.
            if mac > 0 {
                let apps = min(appsWatts, mac)
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { g in
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.green).frame(width: max(2, g.size.width * apps / mac))
                            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.35))
                        }
                    }
                    .frame(height: 10)
                    Text(String(format: "Apps’ CPU work %.1f W · the rest (display, chip, memory, Wi-Fi, other parts) %.1f W", apps, mac - apps))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text("From the battery controller’s own measurements. On power, the charger feeds the Mac and the battery; on battery, the battery feeds everything.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func chip(_ label: String, _ w: Double, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            Text(String(format: "%.1f W", w)).monospacedDigit().fontWeight(.medium)
        }
        .font(.callout)
    }
}
