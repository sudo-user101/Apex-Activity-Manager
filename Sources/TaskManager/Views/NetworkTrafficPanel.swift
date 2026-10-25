import AppKit
import SwiftUI

/// Every network connection on this Mac, grouped by app, with filters.
/// Snapshot every 5 s (~0.15 s of CPU) and only while this panel is visible.
struct NetworkTrafficPanel: View {
    @Environment(AppModel.self) private var model
    /// Only connections on this interface (the Network page's tab); nil = all.
    var interface: String? = nil
    @State private var connections: [NetConnection] = []
    @State private var previous: [String: (UInt64, UInt64)] = [:]
    @State private var previousAt: Date?
    @State private var hostnames: [String: String] = [:]
    @State private var resolving = Set<String>()
    @State private var search = ""
    @State private var proto = "All"
    @State private var hideLocal = true
    @State private var activeOnly = false
    @State private var paused = false
    @State private var pausedAt: Date?
    @State private var detail: TrafficAppRef?
    @State private var expanded = Set<String>()
    @State private var selection = Set<String>()
    @AppStorage("trafficSortKey") private var sortKey = "in"
    @AppStorage("trafficSortAscending") private var sortAscending = false

    var body: some View {
        let shown = filtered()
        let rows = TrafficRow.build(shown, hostnames: hostnames, processes: model.snapshot.processes,
                                    sortKey: sortKey, ascending: sortAscending)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Traffic").font(.headline)
                Text("\(rows.count) apps · \(shown.count) connections").font(.caption).foregroundStyle(.secondary)
                Spacer()
                LiveIndicator(pausedAt: pausedAt)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        paused.toggle()
                        pausedAt = paused ? Date() : nil
                    }
                    if !paused { Task { await refresh() } }
                } label: {
                    Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                }
                .controlSize(.small)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .help(paused ? "Back to live updates (⇧⌘P)"
                      : "Freeze the list so something that just appeared stays there to click on (⇧⌘P)")
            }
            HStack(spacing: 10) {
                TextField("Filter by app, address or port", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Picker("", selection: $proto) {
                    Text("All").tag("All"); Text("TCP").tag("TCP"); Text("UDP").tag("UDP")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle("Hide local", isOn: $hideLocal).toggleStyle(.checkbox)
                    .help("Hide loopback, link-local and multicast traffic")
                Toggle("Active only", isOn: $activeOnly).toggleStyle(.checkbox)
                    .help("Only connections that sent or received data in the last few seconds")
                Spacer()
            }
            NativeOutline(
                rows: rows, columns: TrafficRow.columns, autosaveName: "TrafficOutline.v1",
                selection: selection, sortKey: sortKey, sortAscending: sortAscending,
                isExpanded: { !search.isEmpty || expanded.contains($0) },
                onSelect: { selection = $0 },
                onSort: { sortKey = $0; sortAscending = $1 },
                onExpand: { id, open in if open { expanded.insert(id) } else { expanded.remove(id) } },
                onDoubleClick: { id in openDetail(id, shown) },
                menu: { ids in menu(ids, shown) })
            .frame(height: 420)
            .overlay { if connections.isEmpty { ProgressView().controlSize(.small) } }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .task {
            while !Task.isCancelled {
                // Recorded for the detail window only while Apex is on screen; the
                // list itself stays still while paused.
                if model.isWindowVisible { await refresh(updateList: !paused) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .sheet(item: $detail) { ref in
            AppTrafficSheet(ref: ref, hostnames: hostnames)
        }
    }

    /// Double-click an app (or one of its connections): its traffic details.
    private func openDetail(_ id: String, _ list: [NetConnection]) {
        let pid: pid_t? = id.hasPrefix("app:") ? pid_t(id.dropFirst(4)) : list.first { $0.key == id }?.pid
        guard let pid, let c = list.first(where: { $0.pid == pid }) else { return }
        let p = model.snapshot.processes.first { $0.pid == pid }
        detail = TrafficAppRef(pid: pid, name: c.process, displayName: p?.name ?? c.process,
                               path: p.map { $0.bundlePath.isEmpty ? $0.path : $0.bundlePath } ?? "")
    }

    private func filtered() -> [NetConnection] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return connections.filter { c in
            if let interface, c.interface != interface { return false }
            if hideLocal && c.isLocal { return false }
            if proto == "TCP" && !c.isTCP { return false }
            if proto == "UDP" && c.isTCP { return false }
            if activeOnly && c.inPerSec + c.outPerSec < 1 { return false }
            if q.isEmpty { return true }
            return c.process.lowercased().contains(q) || c.remoteHost.lowercased().contains(q)
                || c.remotePort == q || (hostnames[c.remoteHost]?.lowercased().contains(q) ?? false)
                || String(c.pid) == q
        }
    }

    private func refresh(updateList: Bool = true) async {
        var list = await Task.detached(priority: .utility) { Connections.snapshot() }.value
        let now = Date()
        if let at = previousAt {
            let secs = now.timeIntervalSince(at)
            for i in list.indices {
                if let p = previous[list[i].key], secs > 0 {
                    list[i].inPerSec = list[i].bytesIn >= p.0 ? Double(list[i].bytesIn - p.0) / secs : 0
                    list[i].outPerSec = list[i].bytesOut >= p.1 ? Double(list[i].bytesOut - p.1) / secs : 0
                }
            }
        }
        previous = Dictionary(list.map { ($0.key, ($0.bytesIn, $0.bytesOut)) }, uniquingKeysWith: { a, _ in a })
        previousAt = now
        TrafficHistory.shared.record(list.filter { !$0.isLocal }, at: now)
        if updateList { connections = list }
        resolveHosts(list)
    }

    /// Reverse DNS in the background, a handful at a time, cached for the session.
    private func resolveHosts(_ list: [NetConnection]) {
        let todo = Set(list.filter { !$0.isLocal && $0.remoteHost != "*" }.map(\.remoteHost))
            .subtracting(hostnames.keys).subtracting(resolving).prefix(24)
        for host in todo {
            resolving.insert(host)
            Task {
                let name = await Task.detached(priority: .background) { ReverseDNS.lookup(host) }.value
                hostnames[host] = name ?? ""
                resolving.remove(host)
            }
        }
    }

    private func menu(_ ids: [String], _ list: [NetConnection]) -> NSMenu? {
        guard let id = ids.first else { return nil }
        var items: [NSMenuItem] = []
        if let c = list.first(where: { $0.key == id }) {
            let addr = c.remoteHost + (c.remotePort.isEmpty ? "" : ":\(c.remotePort)")
            items.append(ClosureMenuItem(title: "Copy Address \(addr)") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(addr, forType: .string)
            })
            if let h = hostnames[c.remoteHost], !h.isEmpty {
                items.append(ClosureMenuItem(title: "Copy Host Name") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(h, forType: .string)
                })
            }
            items.append(.separator())
            items.append(ClosureMenuItem(title: "Quit \(c.process)") { model.end(pids: [c.pid], force: false) })
        } else if id.hasPrefix("app:"), let pid = pid_t(id.dropFirst(4)) {
            items.append(ClosureMenuItem(title: "Details…") { openDetail(id, list) })
            items.append(ClosureMenuItem(title: "Quit App") { model.end(pids: [pid], force: false) })
            items.append(ClosureMenuItem(title: "Show in Processes") { model.reveal(pid: pid) })
        }
        return NSMenu.build(items)
    }
}

/// "● Live" (pulsing) or "Paused at 09:41:05 · the list stays still".
struct LiveIndicator: View {
    let pausedAt: Date?
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(pausedAt == nil ? Color.green : Color.orange).frame(width: 7, height: 7)
                .opacity(pausedAt == nil && pulse ? 0.35 : 1)
                .animation(pausedAt == nil ? .easeInOut(duration: 0.9).repeatForever() : .default, value: pulse)
                .onAppear { pulse = true }
            if let at = pausedAt {
                Text("Paused at \(at.formatted(date: .omitted, time: .standard)) · the list stays still")
            } else {
                Text("Live")
            }
        }
        .font(.caption).foregroundStyle(pausedAt == nil ? Color.secondary : Color.orange)
        .contentTransition(.opacity)
    }
}

/// Outline row: an app (with its connections as children) or one connection.
struct TrafficRow: OutlineRow {
    let id: String
    let name: String
    let detail: String       // protocol
    let state: String
    let interface: String
    let bytesIn: UInt64
    let bytesOut: UInt64
    let inPerSec: Double
    let outPerSec: Double
    let iconPath: String?
    let isApp: Bool
    var children: [TrafficRow]?

    static func build(_ conns: [NetConnection], hostnames: [String: String], processes: [ProcessInfoSample],
                      sortKey: String, ascending: Bool) -> [TrafficRow] {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let less = comparator(sortKey)
        func sorted(_ r: [TrafficRow]) -> [TrafficRow] {
            r.sorted { a, b in less(a, b) ? ascending : (less(b, a) ? !ascending : a.id < b.id) }
        }
        let groups = Dictionary(grouping: conns, by: \.pid)
        return sorted(groups.map { pid, list in
            let p = byPid[pid]
            let kids = list.map { c -> TrafficRow in
                let host = hostnames[c.remoteHost].flatMap { $0.isEmpty ? nil : $0 } ?? c.remoteHost
                let name = host + (c.remotePort.isEmpty ? "" : ":\(c.remotePort)")
                return TrafficRow(id: c.key, name: name, detail: c.proto.uppercased(), state: c.state,
                                  interface: c.interface, bytesIn: c.bytesIn, bytesOut: c.bytesOut,
                                  inPerSec: c.inPerSec, outPerSec: c.outPerSec, iconPath: nil, isApp: false, children: nil)
            }
            return TrafficRow(id: "app:\(pid)", name: p?.name ?? list[0].process,
                              detail: "\(list.count) connection\(list.count == 1 ? "" : "s")", state: "",
                              interface: Set(list.map(\.interface)).filter { !$0.isEmpty }.sorted().joined(separator: ", "),
                              bytesIn: list.reduce(0) { $0 + $1.bytesIn }, bytesOut: list.reduce(0) { $0 + $1.bytesOut },
                              inPerSec: list.reduce(0) { $0 + $1.inPerSec }, outPerSec: list.reduce(0) { $0 + $1.outPerSec },
                              iconPath: p?.bundlePath ?? "", isApp: true, children: sorted(kids))
        })
    }

    static func comparator(_ key: String) -> (TrafficRow, TrafficRow) -> Bool {
        switch key {
        case "name": return { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "received": return { $0.bytesIn < $1.bytesIn }
        case "sent": return { $0.bytesOut < $1.bytesOut }
        case "out": return { $0.outPerSec < $1.outPerSec }
        case "state": return { $0.state < $1.state }
        default: return { $0.inPerSec < $1.inPerSec }
        }
    }

    @MainActor static let columns: [OutlineColumn<TrafficRow>] = [
        OutlineColumn(id: "name", title: "App / Remote host", width: 300, minWidth: 160, alignment: .left,
                      defaultAscending: true, canHide: false, text: { $0.name },
                      icon: { r in r.isApp ? IconCache.shared.icon(forBundle: r.iconPath ?? "") : nil },
                      bold: { $0.isApp }),
        OutlineColumn(id: "proto", title: "Protocol", width: 110, alignment: .left, text: { $0.detail }, secondary: true),
        OutlineColumn(id: "state", title: "State", width: 90, alignment: .left, defaultAscending: true,
                      text: { $0.state }, secondary: true),
        OutlineColumn(id: "iface", title: "Interface", width: 70, alignment: .left, text: { $0.interface }, secondary: true),
        OutlineColumn(id: "in", title: "↓ /s", width: 76, text: { Fmt.rate($0.inPerSec) }),
        OutlineColumn(id: "out", title: "↑ /s", width: 76, text: { Fmt.rate($0.outPerSec) }),
        OutlineColumn(id: "received", title: "Received", width: 80, text: { Fmt.diskBytes($0.bytesIn) }),
        OutlineColumn(id: "sent", title: "Sent", width: 80, text: { Fmt.diskBytes($0.bytesOut) }),
    ]
}

enum ReverseDNS {
    /// PTR lookup via getnameinfo (system resolver, respects your DNS settings).
    static func lookup(_ ip: String) -> String? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: 0, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        return String(cString: host)
    }
}

struct TrafficAppRef: Identifiable, Hashable {
    var id: String { name }
    let pid: pid_t
    let name: String          // as nettop names it (the key in TrafficHistory)
    let displayName: String
    let path: String
}

/// One app's network traffic: where the app is, its last 10 minutes of
/// speed, and every server it talked to in that time.
struct AppTrafficSheet: View {
    let ref: TrafficAppRef
    let hostnames: [String: String]
    @Environment(\.dismiss) private var dismiss
    private let history = TrafficHistory.shared

    var body: some View {
        let pts = history.points[ref.name] ?? []
        let peers = history.peers(of: ref.name)
        let servers = TrafficHistory.servers(peers)
        let totals = history.totals(of: ref.name)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: IconCache.shared.icon(forBundle: ref.path)).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ref.displayName).font(.title3.weight(.semibold))
                    Text(ref.path.isEmpty ? "Process \(ref.pid)" : ref.path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                if !ref.path.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref.path)]) }
                }
            }
            HStack(spacing: 24) {
                stat("Received", Fmt.diskBytes(totals.received))
                stat("Sent", Fmt.diskBytes(totals.sent))
                stat("Now ↓", Fmt.rate(pts.last?.inRate ?? 0))
                stat("Now ↑", Fmt.rate(pts.last?.outRate ?? 0))
                stat("Servers", "\(servers.count)")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("LAST 10 MINUTES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                LineGraph(series: [GraphSeries(values: pts.map(\.inRate), color: .blue, name: "Received"),
                                   GraphSeries(values: pts.map(\.outRate), color: .orange, name: "Sent")], maxValue: nil)
                    .environment(\.graphUnit, .rate)
                    .environment(\.graphTimeline, GraphTimeline(times: pts.map(\.date), window: TrafficHistory.window, end: Date()))
                    .frame(height: 110)
                HStack(spacing: 12) {
                    Label("Received", systemImage: "circle.fill").foregroundStyle(.blue)
                    Label("Sent", systemImage: "circle.fill").foregroundStyle(.orange)
                }
                .font(.caption2).labelStyle(.titleAndIcon)
            }
            Text("SERVERS IT TALKED TO").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Table(servers) {
                TableColumn("Server") { p in
                    let host = hostnames[p.remoteHost].flatMap { $0.isEmpty ? nil : $0 } ?? p.remoteHost
                    HStack(spacing: 6) {
                        Circle().fill(p.open ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                            .help(p.open ? "Still connected" : "Closed")
                        Text(host + (p.remotePort.isEmpty ? "" : ":\(p.remotePort)")).lineLimit(1).truncationMode(.middle)
                        if p.connections > 1 { Text("×\(p.connections)").font(.caption).foregroundStyle(.secondary).help("\(p.connections) connections") }
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("Protocol") { p in Text(p.proto.uppercased()).foregroundStyle(.secondary) }.width(60)
                TableColumn("Received") { p in Text(Fmt.diskBytes(p.received)).monospacedDigit() }.width(70)
                TableColumn("Sent") { p in Text(Fmt.diskBytes(p.sent)).monospacedDigit() }.width(70)
                TableColumn("Seen") { p in
                    Text(p.firstSeen.formatted(date: .omitted, time: .shortened) + "–" + (p.open ? "now" : p.lastSeen.formatted(date: .omitted, time: .shortened)))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 90, ideal: 110)
            }
            .frame(height: 200)
            HStack {
                Text("Recorded only while Apex’s window is open on screen, kept for 10 minutes, never saved.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
    }
}
