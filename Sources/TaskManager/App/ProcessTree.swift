import Foundation

/// One row in the Processes outline: a section ("Apps"), an app or same-name
/// group, or a single process.
struct ProcRow: Identifiable, Hashable, OutlineRow {
    enum Kind: Hashable { case section(ProcessKind), group, process }

    let id: String
    let kind: Kind
    let name: String
    let iconPath: String
    let pids: [pid_t]
    let user: String
    let cpu: Double
    let memory: UInt64
    let disk: Double
    let net: Double
    let gpu: Double
    let threads: Int
    let restricted: Bool
    let isApp: Bool
    var children: [ProcRow]?

    var pid: pid_t? { kind == .process || (kind == .group && isApp) ? pids.first : nil }
    var pidSort: Int { Int(pid ?? -1) }
    var count: Int { children?.count ?? 0 }
    var isSection: Bool { if case .section = kind { return true } else { return false } }

    var optimized = false
    var paused = false
}

/// "View" filter for the Processes list.
enum ProcessFilter: String, CaseIterable, Identifiable {
    case all, mine, apps, background, system, otherUsers, active, optimized, paused
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All Processes"
        case .mine: return "My Processes"
        case .apps: return "Apps"
        case .background: return "Background Processes"
        case .system: return "System Processes"
        case .otherUsers: return "Other Users’ Processes"
        case .active: return "Active Now"
        case .optimized: return "Optimized"
        case .paused: return "Paused"
        }
    }

    func includes(_ p: ProcessInfoSample, me: uid_t = getuid()) -> Bool {
        switch self {
        case .all: return true
        case .mine: return p.uid == me
        case .apps: return p.kind == .app || p.isRegularApp
        case .background: return p.kind == .background
        case .system: return p.kind == .system
        case .otherUsers: return p.uid != me
        case .active: return p.cpu >= 0.5 || p.netPerSec > 0 || p.diskReadPerSec + p.diskWritePerSec > 0
        case .optimized: return p.background
        case .paused: return p.state == .stopped
        }
    }
}

enum ProcessTree {
    /// Builds Apps / Background / System sections. Apps absorb their helper
    /// processes (anything running from inside the same .app bundle); other
    /// processes with the same name are grouped together.
    /// Set for the duration of `build` (single-threaded, main actor).
    nonisolated(unsafe) private static var optimizedPIDs = Set<pid_t>()

    static func build(_ procs: [ProcessInfoSample], search: String, cpuScale: Double,
                      sortKey: String, ascending: Bool, optimized: Set<pid_t> = [],
                      filter: ProcessFilter = .all) -> [ProcRow] {
        optimizedPIDs = optimized
        let procs = filter == .all ? procs : procs.filter { filter.includes($0) }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ p: ProcessInfoSample) -> Bool {
            q.isEmpty || p.name.lowercased().contains(q) || String(p.pid).hasPrefix(q) || p.user.lowercased() == q
        }

        let appBundles = Set(procs.filter(\.isRegularApp).map(\.bundlePath).filter { !$0.isEmpty })
        var helpers: [String: [ProcessInfoSample]] = [:]
        var loose: [ProcessKind: [ProcessInfoSample]] = [:]
        for p in procs {
            if !p.isRegularApp, !p.bundlePath.isEmpty, appBundles.contains(p.bundlePath) {
                helpers[p.bundlePath, default: []].append(p)
            } else if !p.isRegularApp {
                loose[p.kind, default: []].append(p)
            }
        }

        var sections: [ProcRow] = []
        for kind in ProcessKind.allCases {
            var rows: [ProcRow] = []
            if kind == .app {
                for app in procs where app.isRegularApp {
                    let kids = helpers[app.bundlePath] ?? []
                    let appMatches = matches(app)
                    let shownKids = appMatches ? kids : kids.filter(matches)
                    guard appMatches || !shownKids.isEmpty else { continue }
                    rows.append(group(id: "a:\(app.pid)", name: app.name, iconPath: app.bundlePath,
                                      lead: app, members: [app] + kids,
                                      children: shownKids.map { row($0, cpuScale) }, cpuScale: cpuScale, isApp: true))
                }
            } else {
                let byName = Dictionary(grouping: (loose[kind] ?? []).filter(matches), by: \.name)
                for (name, members) in byName {
                    if members.count == 1 {
                        rows.append(row(members[0], cpuScale))
                    } else {
                        rows.append(group(id: "n:\(kind.rawValue):\(name)", name: name,
                                          iconPath: members[0].bundlePath, lead: members[0], members: members,
                                          children: members.map { row($0, cpuScale) }, cpuScale: cpuScale, isApp: false))
                    }
                }
            }
            guard !rows.isEmpty else { continue }
            rows = sorted(rows, key: sortKey, ascending: ascending)
            sections.append(sectionRow(kind, rows))
        }
        return sections
    }

    /// The rows for this sample, built once: SwiftUI re-renders the view for
    /// many reasons (selection, hover, sheets), and rebuilding ~600 rows each
    /// time was most of Apex's memory churn on this page.
    @MainActor private static var memo: (key: String, rows: [ProcRow])?

    @MainActor static func cached(_ s: Snapshot, search: String, cpuScale: Double, sortKey: String, ascending: Bool,
                                  optimized: Set<pid_t>, filter: ProcessFilter) -> [ProcRow] {
        let key = "\(s.date.timeIntervalSinceReferenceDate)|\(search)|\(cpuScale)|\(sortKey)|\(ascending)|\(optimized.count)|\(optimized.hashValue)|\(filter.rawValue)"
        if let m = memo, m.key == key { return m.rows }
        let rows = build(s.processes, search: search, cpuScale: cpuScale, sortKey: sortKey, ascending: ascending,
                         optimized: optimized, filter: filter)
        memo = (key, rows)
        return rows
    }

    static func pids(for selection: Set<String>, in procs: [ProcessInfoSample]) -> [pid_t] {
        var out: [pid_t] = []
        for id in selection {
            if id.hasPrefix("p:") || id.hasPrefix("a:"), let pid = pid_t(id.dropFirst(2)) {
                out.append(pid)
            } else if id.hasPrefix("n:") {
                let parts = id.split(separator: ":", maxSplits: 2)
                if parts.count == 3, let raw = Int(parts[1]) {
                    out += procs.filter { $0.kind.rawValue == raw && $0.name == parts[2] && !$0.isRegularApp }.map(\.pid)
                }
            }
        }
        return out
    }

    // MARK: Builders

    private static func row(_ p: ProcessInfoSample, _ scale: Double) -> ProcRow {
        var r = ProcRow(id: "p:\(p.pid)", kind: .process, name: p.name, iconPath: p.bundlePath, pids: [p.pid],
                user: p.user, cpu: p.cpu * scale, memory: p.memory, disk: p.diskReadPerSec + p.diskWritePerSec,
                net: p.netPerSec, gpu: p.gpu, threads: Int(p.threads), restricted: p.restricted,
                isApp: p.isRegularApp, children: nil)
        r.optimized = optimizedPIDs.contains(p.pid)
        r.paused = p.state == .stopped
        return r
    }

    private static func group(id: String, name: String, iconPath: String, lead: ProcessInfoSample,
                              members: [ProcessInfoSample], children: [ProcRow],
                              cpuScale: Double, isApp: Bool) -> ProcRow {
        var cpu = 0.0, mem: UInt64 = 0, disk = 0.0, net = 0.0, gpu = 0.0, threads = 0
        for m in members {
            cpu += m.cpu; mem += m.memory; disk += m.diskReadPerSec + m.diskWritePerSec
            net += m.netPerSec; gpu += m.gpu; threads += Int(m.threads)
        }
        var r = ProcRow(id: id, kind: .group, name: name, iconPath: iconPath,
                       pids: isApp ? [lead.pid] : members.map(\.pid), user: lead.user,
                       cpu: cpu * cpuScale, memory: mem, disk: disk, net: net, gpu: min(100, gpu),
                       threads: threads, restricted: lead.restricted, isApp: isApp,
                       children: children.isEmpty ? nil : children)
        r.optimized = members.allSatisfy { optimizedPIDs.contains($0.pid) }
        r.paused = lead.state == .stopped
        return r
    }

    private static func sectionRow(_ kind: ProcessKind, _ rows: [ProcRow]) -> ProcRow {
        var cpu = 0.0, mem: UInt64 = 0, disk = 0.0, net = 0.0, gpu = 0.0, threads = 0
        for r in rows { cpu += r.cpu; mem += r.memory; disk += r.disk; net += r.net; gpu += r.gpu; threads += r.threads }
        return ProcRow(id: "s:\(kind.rawValue)", kind: .section(kind), name: kind.title, iconPath: "",
                       pids: [], user: "", cpu: cpu, memory: mem, disk: disk, net: net, gpu: min(100, gpu),
                       threads: threads, restricted: false, isApp: false, children: rows)
    }

    private static func sorted(_ rows: [ProcRow], key: String, ascending: Bool) -> [ProcRow] {
        let less = comparator(key)
        let by: (ProcRow, ProcRow) -> Bool = { a, b in
            if less(a, b) { return ascending }
            if less(b, a) { return !ascending }
            return a.id < b.id      // stable order so rows don't jitter
        }
        return rows.sorted(by: by).map { r in
            var r = r
            if let c = r.children { r.children = c.sorted(by: by) }
            return r
        }
    }

    static func comparator(_ key: String) -> (ProcRow, ProcRow) -> Bool {
        switch key {
        case "name": return { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "memory": return { $0.memory < $1.memory }
        case "disk": return { $0.disk < $1.disk }
        case "network": return { $0.net < $1.net }
        case "gpu": return { $0.gpu < $1.gpu }
        case "threads": return { $0.threads < $1.threads }
        case "pid": return { $0.pidSort < $1.pidSort }
        case "user": return { $0.user < $1.user }
        default: return { $0.cpu < $1.cpu }
        }
    }
}
