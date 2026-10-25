import Foundation

/// The last 10 minutes of network traffic per app, for the traffic detail
/// window: a speed reading every snapshot and every server each app talked
/// to (closed connections included). Kept in memory only, recorded only
/// while Apex's window is on screen, and anything older than 10 minutes is
/// dropped.
@MainActor @Observable
final class TrafficHistory {
    static let shared = TrafficHistory()
    init() {}
    static let window: TimeInterval = 600

    struct Point: Sendable, Equatable { let date: Date; let inRate: Double; let outRate: Double }

    struct Peer: Identifiable, Sendable, Equatable {
        let id: String              // the connection's key
        let app: String
        let remoteHost: String
        let remotePort: String
        let proto: String
        var firstSeen: Date
        var lastSeen: Date
        var received: UInt64 = 0    // since Apex first saw it
        var sent: UInt64 = 0
        var open = true
    }

    private(set) var points: [String: [Point]] = [:]     // by app name
    private(set) var peers: [String: Peer] = [:]         // by connection key
    @ObservationIgnored private var lastBytes: [String: (UInt64, UInt64)] = [:]

    /// One snapshot (connections with their current rates).
    func record(_ conns: [NetConnection], at now: Date = Date()) {
        let byApp = Dictionary(grouping: conns, by: \.process)
        for app in Set(points.keys).union(byApp.keys) {
            let list = byApp[app] ?? []
            points[app, default: []].append(Point(date: now, inRate: list.reduce(0) { $0 + $1.inPerSec },
                                                  outRate: list.reduce(0) { $0 + $1.outPerSec }))
        }
        let seen = Set(conns.map(\.key))
        for c in conns {
            var p = peers[c.key] ?? Peer(id: c.key, app: c.process, remoteHost: c.remoteHost, remotePort: c.remotePort,
                                         proto: c.proto, firstSeen: now, lastSeen: now)
            if let last = lastBytes[c.key] {
                p.received += c.bytesIn > last.0 ? c.bytesIn - last.0 : 0
                p.sent += c.bytesOut > last.1 ? c.bytesOut - last.1 : 0
            }
            p.lastSeen = now; p.open = true
            peers[c.key] = p
            lastBytes[c.key] = (c.bytesIn, c.bytesOut)
        }
        for (k, p) in peers where p.open && !seen.contains(k) { peers[k]?.open = false; lastBytes[k] = nil }
        prune(now)
    }

    /// Drops everything older than 10 minutes.
    func prune(_ now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.window)
        for (app, list) in points {
            let kept = list.filter { $0.date >= cutoff }
            if kept.isEmpty || kept.allSatisfy({ $0.inRate == 0 && $0.outRate == 0 }) && !(peers.values.contains { $0.app == app && $0.lastSeen >= cutoff }) {
                points[app] = nil
            } else if kept.count != list.count {
                points[app] = kept
            }
        }
        for (k, p) in peers where p.lastSeen < cutoff { peers[k] = nil; lastBytes[k] = nil }
    }

    func peers(of app: String) -> [Peer] {
        peers.values.filter { $0.app == app }.sorted { ($0.received + $0.sent) > ($1.received + $1.sent) }
    }

    /// One row per server (all the app's connections to it together).
    struct Server: Identifiable, Sendable, Equatable {
        var id: String { "\(proto)|\(remoteHost)|\(remotePort)" }
        let remoteHost: String
        let remotePort: String
        let proto: String
        var connections: Int
        var received: UInt64
        var sent: UInt64
        var firstSeen: Date
        var lastSeen: Date
        var open: Bool
    }

    /// Pure: tested.
    nonisolated static func servers(_ peers: [Peer]) -> [Server] {
        var by: [String: Server] = [:]
        for p in peers {
            let k = "\(p.proto)|\(p.remoteHost)|\(p.remotePort)"
            if var s = by[k] {
                s.connections += 1; s.received += p.received; s.sent += p.sent
                s.firstSeen = min(s.firstSeen, p.firstSeen); s.lastSeen = max(s.lastSeen, p.lastSeen); s.open = s.open || p.open
                by[k] = s
            } else {
                by[k] = Server(remoteHost: p.remoteHost, remotePort: p.remotePort, proto: p.proto, connections: 1,
                               received: p.received, sent: p.sent, firstSeen: p.firstSeen, lastSeen: p.lastSeen, open: p.open)
            }
        }
        return by.values.sorted { ($0.received + $0.sent, $0.lastSeen) > ($1.received + $1.sent, $1.lastSeen) }
    }

    /// Total received / sent by an app in the window.
    func totals(of app: String) -> (received: UInt64, sent: UInt64) {
        peers(of: app).reduce((0, 0)) { ($0.0 + $1.received, $0.1 + $1.sent) }
    }
}
