import AppKit
import SwiftUI

/// Every network connection on this Mac, grouped by app, with filters.
/// Snapshot every 5 s (~0.15 s of CPU) and only while this panel is visible.
struct NetworkTrafficPanel: View {
    @Environment(AppModel.self) private var model
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
                Toggle(isOn: $paused) { Label(paused ? "Paused" : "Live", systemImage: paused ? "pause.fill" : "dot.radiowaves.left.and.right") }
                    .toggleStyle(.button).controlSize(.small)
                    .help(paused ? "Resume live updates" : "Pause updates")
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
                onDoubleClick: { id in if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } },
                menu: { ids in menu(ids, shown) })
            .frame(height: 420)
            .overlay { if connections.isEmpty { ProgressView().controlSize(.small) } }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .task {
            while !Task.isCancelled {
                if !paused { await refresh() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func filtered() -> [NetConnection] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return connections.filter { c in
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

    private func refresh() async {
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
        connections = list
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
            items.append(ClosureMenuItem(title: "Quit App") { model.end(pids: [pid], force: false) })
            items.append(ClosureMenuItem(title: "Show in Processes") { model.reveal(pid: pid) })
        }
        return NSMenu.build(items)
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
