import SwiftUI

/// A row in the Performance sidebar: a fixed resource or a plugged-in device.
enum PerfItem: Hashable {
    case resource(Resource)
    case disk(String)
    case net(String)

    var key: String {
        switch self {
        case .resource(let r): return r.rawValue
        case .disk(let id): return "disk:" + id
        case .net(let id): return "net:" + id
        }
    }
    init(key: String) {
        if key.hasPrefix("disk:") { self = .disk(String(key.dropFirst(5))) }
        else if key.hasPrefix("net:") { self = .net(String(key.dropFirst(4))) }
        else { self = .resource(Resource(rawValue: key) ?? .cpu) }
    }

    /// Sidebar order: each device sits right under its kind (Disk, Network).
    static func all(_ s: SystemSnapshot) -> [PerfItem] {
        var out: [PerfItem] = []
        for r in Resource.allCases {
            out.append(.resource(r))
            if r == .disk { out += s.storageDevices.map { .disk($0.id) } }
            if r == .network { out += s.networkDevices.map { .net($0.id) } }
        }
        return out
    }
}

extension StorageDevice {
    var symbol: String {
        switch connection {
        case "SD card": return "sdcard"
        case "Thunderbolt": return "bolt.horizontal"
        default: return isInternal ? "internaldrive" : "externaldrive"
        }
    }
    var subtitleLine: String {
        [usb?.short ?? connection, model, size > 0 ? Fmt.diskBytes(size) : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension NetworkDevice {
    var symbol: String { name.localizedCaseInsensitiveContains("iPhone") ? "iphone" : kind == "Wi-Fi" ? "wifi" : "cable.connector" }
    var linkText: String {
        guard linkSpeed > 0 else { return "" }
        if linkSpeed >= 1_000_000_000 { return String(format: "%g Gb/s", Double(linkSpeed) / 1e9) }
        return String(format: "%g Mb/s", Double(linkSpeed) / 1e6)
    }
}

/// Graph timeline for a device's own samples.
private func deviceTimeline(_ series: DeviceSeries?, minutes: Double) -> GraphTimeline? {
    guard let s = series, let end = s.times.last else { return nil }
    return GraphTimeline(times: s.times, window: minutes * 60, end: end)
}

struct DeviceCard: View {
    @Environment(AppModel.self) private var model
    let item: PerfItem

    var body: some View {
        let s = model.snapshot.system
        let series = model.history.devices[item.key]
        HStack(spacing: 10) {
            LineGraph(series: [.init(values: series?.a ?? [], color: isDisk ? .green : .orange),
                               .init(values: series?.b ?? [], color: isDisk ? .red : .blue, fill: false)],
                      maxValue: nil, gridLines: false, cornerRadius: 4)
                .environment(\.graphTimeline, deviceTimeline(series, minutes: model.graphMinutes))
                .frame(width: 64, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: symbol(s)).font(.caption).foregroundStyle(.secondary)
                    Text(title(s)).font(.headline).lineLimit(1)
                }
                Text(summary(s)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .help(isDisk ? "Plugged-in drive" : "Plugged-in network adapter")
    }

    private var isDisk: Bool { if case .disk = item { return true }; return false }

    private func title(_ s: SystemSnapshot) -> String {
        switch item {
        case .disk(let id): return s.storageDevices.first { $0.id == id }?.name ?? "Drive"
        case .net(let id): return s.networkDevices.first { $0.id == id }?.name ?? id
        case .resource(let r): return r.title
        }
    }
    private func symbol(_ s: SystemSnapshot) -> String {
        switch item {
        case .disk(let id): return s.storageDevices.first { $0.id == id }?.symbol ?? "externaldrive"
        case .net(let id): return s.networkDevices.first { $0.id == id }?.symbol ?? "cable.connector"
        case .resource: return "circle"
        }
    }
    private func summary(_ s: SystemSnapshot) -> String {
        switch item {
        case .disk(let id):
            guard let d = s.storageDevices.first(where: { $0.id == id }) else { return "" }
            return "R \(Fmt.rate(d.readPerSec))  W \(Fmt.rate(d.writePerSec))"
        case .net(let id):
            guard let d = s.networkDevices.first(where: { $0.id == id }) else { return "" }
            return d.isUp ? "↓ \(Fmt.rate(d.inPerSec))  ↑ \(Fmt.rate(d.outPerSec))" : "Not connected"
        case .resource: return ""
        }
    }
}

// MARK: Detail pages

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

/// A USB 3 device stuck at USB 2 speed.
private func slowWarning(_ u: USBLink) -> some View {
    Label("Running at \(u.connectedAs) although it supports \(u.supports). Try another port, or a USB 3 cable or hub.",
          systemImage: "tortoise.fill")
        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
}

/// `extraAt` puts `extra` before that item (default: at the end).
private func statsGrid(_ items: [(String, String)], extra: AnyView? = nil, extraAt: Int? = nil) -> some View {
    let split = min(extraAt ?? items.count, items.count)
    return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .topLeading)], alignment: .leading, spacing: 12) {
        ForEach(items[..<split], id: \.0) { statCell($0) }
        if let extra { extra }
        ForEach(items[split...], id: \.0) { statCell($0) }
    }
    .padding(14)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
}

private func statCell(_ item: (String, String)) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(item.0).font(.caption).foregroundStyle(.secondary)
        Text(item.1).font(.body.weight(.medium)).monospacedDigit().lineLimit(1).truncationMode(.middle)
    }
}

/// Same layout as the Disk page, for one plugged-in or secondary drive.
struct StorageDeviceDetail: View {
    @Environment(AppModel.self) private var model
    let device: StorageDevice
    @State private var ejectError: String?
    @State private var ejecting = false
    @State private var tools: Bool?          // nil closed; false Format; true Make Bootable
    @State private var showHealth = false
    @State private var showDoctor = false

    var body: some View {
        let d = device
        let series = model.history.devices["disk:" + d.id]
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: d.name, subtitle: d.subtitleLine, accessory: AnyView(headerButtons))
            if let e = ejectError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let u = d.usb, u.slowerThanItCould { slowWarning(u) }
            HStack { legend([("Read", .green), ("Write", .red)]); Spacer(); RangeCaption() }
            LineGraph(series: [.init(values: series?.a ?? [], color: .green, name: "Read"),
                               .init(values: series?.b ?? [], color: .red, fill: false, name: "Write")], maxValue: nil)
                .environment(\.graphTimeline, deviceTimeline(series, minutes: model.graphMinutes))
                .environment(\.graphUnit, .rate)
                .frame(height: 180)
            if d.capacity > 0 {
                StackedBar(parts: [.init(value: Double(d.capacity > d.available ? d.capacity - d.available : 0), color: .green)],
                           total: Double(d.capacity))
            }
            statsGrid([
                ("Reading", Fmt.rate(d.readPerSec)), ("Writing", Fmt.rate(d.writePerSec)),
                ("Reads per second", Fmt.count(d.readOpsPerSec)), ("Writes per second", Fmt.count(d.writeOpsPerSec)),
                ("Read since plugged in", "\(Fmt.diskBytes(d.totalRead)) · \(Fmt.compactCount(d.totalReadOps)) reads"),
                ("Written since plugged in", "\(Fmt.diskBytes(d.totalWritten)) · \(Fmt.compactCount(d.totalWriteOps)) writes"),
                ("Connection", d.usb?.connectedAs ?? d.connection),
                ("Supports", d.usb.map { $0.supports.isEmpty ? "—" : $0.supports } ?? "—"),
                ("Model", d.model.isEmpty ? "—" : d.model),
                // Drive health sits here, where Size was (the user asked; Capacity says it).
                ("Capacity", d.capacity > 0 ? Fmt.diskBytes(d.capacity) : (d.size > 0 ? Fmt.diskBytes(d.size) : "—")),
                ("Available", d.capacity > 0 ? Fmt.diskBytes(d.available) : "—"),
            ], extra: AnyView(DriveHealthStat(title: d.name, record: DriveHealthStore.shared.record(for: d),
                                              volumes: d.volumes.map { ($0.name, $0.path) }, show: $showHealth)),
               extraAt: 9)
            VStack(alignment: .leading, spacing: 8) {
                Text(d.volumes.count == 1 ? "Volume" : "Volumes").font(.subheadline).foregroundStyle(.secondary)
                if d.volumes.isEmpty {
                    Text("Nothing on this drive is mounted (it may be unformatted or still mounting).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(d.volumes, id: \.path) { v in
                    HStack(spacing: 10) {
                        Image(systemName: d.symbol).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(v.name)
                            Text([v.format, "\(Fmt.diskBytes(v.available)) free of \(Fmt.diskBytes(v.capacity))"].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: v.path)) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Open in Finder")
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Text("Which apps are reading or writing this drive isn’t reported separately by macOS; the Disk page’s top processes cover every drive.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: toolsSheet) {
            if tools == true { BootableCreatorView(deviceID: device.id) }
            else { DriveToolsView(startBootable: false, deviceID: device.id) }
        }
        .sheet(isPresented: $showDoctor) {
            DriveDoctorView(title: device.name, record: DriveHealthStore.shared.record(for: device), usb: device.usb,
                            capacity: device.capacity, available: device.available,
                            volumes: device.volumes.map { ($0.name, $0.path) })
        }

        .onAppear {
            // APEX_OPEN_DRIVE_TOOLS=1 opens the window straight away (for checking the layout).
            if ProcessInfo.processInfo.environment["APEX_OPEN_DRIVE_TOOLS"] == "1", tools == nil { tools = true }
            // APEX_OPEN=doctor|creator opens Drive Doctor or the Bootable Media Creator.
            switch ProcessInfo.processInfo.environment["APEX_OPEN"] {
            case "doctor": showDoctor = true
            case "creator": if tools == nil { tools = true }
            default: break
            }
        }
    }

    private var toolsSheet: Binding<Bool> { Binding(get: { tools != nil }, set: { if !$0 { tools = nil } }) }

    /// Format, Make Bootable and Eject, side by side in the header.
    private var headerButtons: some View {
        HStack(spacing: 8) {
            TransfersButton(volumes: device.volumes.map(\.path))
            Button { showDoctor = true } label: { Image(systemName: "stethoscope") }
                .buttonStyle(.bordered).help("Drive Doctor: find and fix drive problems…")
            if let v = device.volumes.first {
                Button { model.openStorage(volume: v.path) } label: { FreeSpaceIcon() }
                    .buttonStyle(.bordered).help("Free up space on “\(v.name)”: analyze it and empty its Trash…")
            }
            if !DriveTools.eligible([device]).isEmpty {
                Button { tools = false } label: { Image(systemName: "eraser") }
                    .buttonStyle(.bordered).help("Format “\(device.name)”…")
                Button { tools = true } label: { Image(systemName: "opticaldiscdrive") }
                    .buttonStyle(.bordered).help("Bootable Media Creator: make “\(device.name)” a USB installer…")
            }
            if device.ejectable || !device.isInternal { ejectButton }
        }
    }

    private var ejectButton: some View {
        Button {
            ejecting = true
            ejectError = DeviceActions.eject(device)
            ejecting = false
        } label: { Image(systemName: "eject") }
        .buttonStyle(.bordered)
        .disabled(ejecting || device.volumes.isEmpty)
        .help("Eject “\(device.name)”")
    }
}

/// Network page for one plugged-in adapter (USB / Thunderbolt Ethernet, iPhone…).
struct NetworkDeviceDetail: View {
    @Environment(AppModel.self) private var model
    let device: NetworkDevice

    var body: some View {
        let d = device
        let series = model.history.devices["net:" + d.id]
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: d.name,
                       subtitle: [d.usb?.short ?? d.connection, d.kind, d.isUp ? d.linkText : "not connected"].filter { !$0.isEmpty }.joined(separator: " · "),
                       subtitleColor: d.isUp ? .secondary : .orange)
            if let u = d.usb, u.slowerThanItCould { slowWarning(u) }
            HStack { legend([("Received", .orange), ("Sent", .blue)]); Spacer(); RangeCaption() }
            LineGraph(series: [.init(values: series?.a ?? [], color: .orange, name: "Received"),
                               .init(values: series?.b ?? [], color: .blue, fill: false, name: "Sent")], maxValue: nil)
                .environment(\.graphTimeline, deviceTimeline(series, minutes: model.graphMinutes))
                .environment(\.graphUnit, .rate)
                .frame(height: 180)
            statsGrid([
                ("Receiving", Fmt.rate(d.inPerSec)), ("Sending", Fmt.rate(d.outPerSec)),
                ("Received since plugged in", Fmt.diskBytes(d.totalIn)), ("Sent since plugged in", Fmt.diskBytes(d.totalOut)),
                ("Status", d.isUp ? "Connected" : "Not connected"), ("Link speed", d.linkText.isEmpty ? "—" : d.linkText),
                ("IP address", d.address.isEmpty ? "—" : d.address), ("Hardware address", d.hardwareAddress.isEmpty ? "—" : d.hardwareAddress),
                ("Interface", d.id), ("Connection", d.usb?.connectedAs ?? d.connection),
                ("Supports", d.usb.map { $0.supports.isEmpty ? "—" : $0.supports } ?? "—"),
            ])
            if !d.isUp {
                Text("The adapter is plugged in but has no network link. Check the cable or the other end.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Drive health

extension DriveHealthStatus {
    var color: Color {
        switch self { case .learning: return .yellow; case .good: return .messageGreen; case .watch: return .orange; case .poor: return .red }
    }
    var symbol: String {
        switch self {
        case .learning: return "hourglass"
        case .good: return "checkmark.seal.fill"
        case .watch: return "exclamationmark.triangle.fill"
        case .poor: return "xmark.octagon.fill"
        }
    }
}

/// Health, usage and performance for one drive (the Disk page and each drive's page).
struct DriveHealthCard: View {
    let record: DriveRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = record {
                let a = DriveHealthRules.assess(r)
                HStack(spacing: 10) {
                    Image(systemName: a.status.symbol).font(.title2).foregroundStyle(a.status.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Drive health").font(.caption).foregroundStyle(.secondary)
                        Text(a.status.title).font(.title3.weight(.semibold)).foregroundStyle(a.status.color)
                    }
                    Spacer()
                    Text(DriveHealthRules.usage(r).title).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 320, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(a.reasons, id: \.self) { Text("• " + $0).font(.callout).fixedSize(horizontal: false, vertical: true) }
                }
                Divider()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                    if let s = r.smart {
                        item("Lifespan used", "\(s.percentageUsed)%")
                        item("Spare blocks", "\(s.availableSpare)%")
                        item("Data errors", "\(s.mediaErrors)")
                        item("Temperature", "\(s.temperatureC) °C")
                        item("Powered on", Fmt.duration(TimeInterval(s.powerOnHours) * 3600))
                        if !r.isStartup {
                            item("Written in its lifetime", Fmt.diskBytes(s.dataWrittenBytes))
                            item("Read in its lifetime", Fmt.diskBytes(s.dataReadBytes))
                        }
                        item("Unexpected shutdowns", "\(s.unsafeShutdowns)")
                    }
                    if !r.isStartup {
                        item("Connected", "\(Fmt.duration(r.secondsConnected)) over \(r.sessions) \(r.sessions == 1 ? "time" : "times")")
                        item("Busy", Fmt.duration(r.activeSeconds))
                    }
                    item(r.isStartup ? "Moved while watched" : "Data moved", "\(Fmt.diskBytes(UInt64(r.bytesRead))) read · \(Fmt.diskBytes(UInt64(r.bytesWritten))) written")
                    item("Large transfers", r.transfers.isEmpty ? "None yet" : "\(r.transfers.count)")
                    if r.bestReadMBps > 0 { item("Best read speed", String(format: "%.0f MB/s", r.bestReadMBps)) }
                    if r.bestWriteMBps > 0 { item("Best write speed", String(format: "%.0f MB/s", r.bestWriteMBps)) }
                    if let t = r.transfers.last {
                        item("Last transfer", String(format: "%.0f MB at %.0f MB/s", t.megabytes, max(t.readMBps, t.writeMBps)))
                    }
                    if let l = r.latencyMs { item("Response time", String(format: "%.2f ms per operation", l)) }
                    if r.reportsErrors { item("Errors seen", r.errors == 0 ? "None" : "\(Int(r.errors))") }
                    item("Watching since", r.firstSeen.formatted(date: .abbreviated, time: .omitted))
                }
                if r.transfers.count >= 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Speed of recent large transfers").font(.caption).foregroundStyle(.secondary)
                        LineGraph(series: [.init(values: r.transfers.map { max($0.readMBps, $0.writeMBps) * 1_000_000 }, color: .green, name: "Speed")],
                                  maxValue: nil, gridLines: true)
                            .environment(\.graphTimeline, nil)
                            .environment(\.graphUnit, .rate)
                            .frame(height: 70)
                    }
                }
            } else {
                Label("Apex will start learning about this drive now.", systemImage: "hourglass").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func item(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium)).monospacedDigit().lineLimit(2)
        }
    }
}

// MARK: Health check (stethoscope)

/// "Free up space" icon: a drive with a sparkle (cleaning), not a diagnosis.
struct FreeSpaceIcon: View {
    var body: some View {
        // The sparkle sits inside the label's own frame (padding, not offset),
        // so it can't poke out of the button onto its neighbours.
        Image(systemName: "internaldrive")
            .padding(.trailing, 5)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "sparkle").font(.system(size: 7, weight: .bold)).offset(y: -1)
            }
            .foregroundStyle(Color.secondary)
    }
}

/// Read-only First Aid check (`diskutil verifyVolume`), no admin needed.
enum DriveCheck {
    struct Result: Sendable, Hashable { var volume: String; var ok: Bool; var summary: String }

    static func verify(_ volumes: [(name: String, path: String)]) -> [Result] {
        volumes.map { v in
            let r = Shell.run("/usr/sbin/diskutil", ["verifyVolume", v.path])
            let text = r.stdout + r.stderr
            let ok = r.status == 0 && (text.contains("appears to be OK") || text.contains("exit code is 0"))
            let line = text.split(separator: "\n").map(String.init).last { $0.contains("appears to be") || $0.contains("error") || $0.contains("Error") }
            return Result(volume: v.name, ok: ok,
                          summary: ok ? "No problems found" : (line ?? "The check reported a problem (exit \(r.status)). Run First Aid in Disk Utility to repair it."))
        }
    }
}

/// A small "Drive health" cell for the stats grid: a coloured icon and one word.
/// Click it for the details, like the swap popover.
struct DriveHealthStat: View {
    let title: String
    let record: DriveRecord?
    let volumes: [(name: String, path: String)]
    @Binding var show: Bool

    var body: some View {
        let status = record.map { DriveHealthRules.assess($0).status } ?? .learning
        Button { show.toggle() } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Drive health").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: status.symbol).foregroundStyle(status.color)
                    Text(status.title).font(.body.weight(.medium))
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Drive health details and error check")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            DriveHealthPanel(title: title, record: record, volumes: volumes).padding(16).frame(width: 640)
        }
    }
}

/// Everything about a drive's health, plus a read-only error check.
struct DriveHealthPanel: View {
    let title: String
    let record: DriveRecord?
    let volumes: [(name: String, path: String)]
    @State private var checking = false
    @State private var results: [DriveCheck.Result] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "stethoscope").font(.title2).foregroundStyle(.tint)
                Text("Drive Health · \(title)").font(.title2).bold()
                Spacer()
            }
            ScrollView { DriveHealthCard(record: record) }.frame(maxHeight: 420)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for errors").font(.headline)
                        Text("Runs macOS First Aid in read-only mode: it looks for file-system damage without changing anything. Takes about 10 seconds per volume.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(checking ? "Checking…" : (results.isEmpty ? "Check Now" : "Check Again")) { check() }
                        .disabled(checking || volumes.isEmpty)
                }
                if checking { ProgressView().progressViewStyle(.linear) }
                ForEach(results, id: \.self) { r in
                    Label("\(r.volume): \(r.summary)", systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.ok ? Color.green : Color.orange)
                }
                if !results.isEmpty, results.contains(where: { !$0.ok }) {
                    Button("Open Disk Utility") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")) }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func check() {
        checking = true; results = []
        let v = volumes
        Task {
            results = await Task.detached(priority: .userInitiated) { DriveCheck.verify(v) }.value
            checking = false
        }
    }
}
