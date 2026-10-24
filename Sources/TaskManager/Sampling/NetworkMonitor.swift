import Foundation

/// Per-process network throughput.
///
/// macOS has no public per-process network API, so this runs a single
/// `nettop` snapshot (`-L 1`, ~10 ms of CPU) per sampling tick and diffs the
/// cumulative byte counters. (A long-lived streaming nettop was measured at
/// >100 % of a core — it busy-waits between samples — so it is never used.)
/// Only called while the Processes view is visible. Not thread-safe: owned by
/// `Sampler`'s queue.
final class NetworkMonitor {
    private var previous: [pid_t: UInt64] = [:]
    private var previousTime: UInt64 = 0

    func reset() { previous.removeAll(); previousTime = 0 }

    /// "name.pid,bytes_in,bytes_out," lines -> cumulative bytes per pid.
    static func parseTotals(_ out: String) -> [pid_t: UInt64] {
        var totals: [pid_t: UInt64] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, let dot = f[0].lastIndex(of: "."),
                  let pid = pid_t(f[0][f[0].index(after: dot)...]) else { continue }
            totals[pid, default: 0] += (UInt64(f[1]) ?? 0) + (UInt64(f[2]) ?? 0)
        }
        return totals
    }

    /// Bytes/second per pid since the previous call.
    func sample() -> [pid_t: Double] {
        guard let out = Shell.capture("/usr/bin/nettop", ["-P", "-x", "-L", "1", "-J", "bytes_in,bytes_out"]) else { return [:] }
        let now = DispatchTime.now().uptimeNanoseconds
        let totals = Self.parseTotals(out)
        defer { previous = totals; previousTime = now }
        guard previousTime > 0 else { return [:] }
        let secs = Double(now - previousTime) / 1e9
        guard secs > 0 else { return [:] }
        var rates: [pid_t: Double] = [:]
        for (pid, t) in totals {
            if let p = previous[pid], t > p { rates[pid] = Double(t - p) / secs }
        }
        return rates
    }
}

/// One socket, from a `nettop` connection snapshot.
struct NetConnection: Identifiable, Sendable, Hashable {
    var id: String { key }
    let key: String
    let process: String
    let pid: pid_t
    let proto: String        // tcp4, tcp6, udp4, udp6
    let local: String
    let remoteHost: String
    let remotePort: String
    let interface: String
    let state: String
    let bytesIn: UInt64
    let bytesOut: UInt64
    var inPerSec: Double = 0
    var outPerSec: Double = 0
    var isTCP: Bool { proto.hasPrefix("tcp") }
    var isLocal: Bool {
        interface == "lo0" || remoteHost.hasPrefix("127.") || remoteHost == "::1"
            || remoteHost.hasPrefix("fe80") || remoteHost.hasPrefix("ff0") || remoteHost.hasPrefix("224.")
    }
}

enum Connections {
    /// Every socket with an interface or traffic (~0.15 s of CPU; the Network
    /// page calls it every few seconds while visible).
    static func snapshot() -> [NetConnection] {
        guard let out = Shell.capture("/usr/bin/nettop", ["-L", "1", "-x", "-n", "-J", "interface,state,bytes_in,bytes_out"]) else { return [] }
        return parse(out)
    }

    static func parse(_ out: String) -> [NetConnection] {
        var result: [NetConnection] = []
        var process = "", pid: pid_t = 0
        for line in out.split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, !f[0].isEmpty else { continue }
            if let arrow = f[0].range(of: "<->") {
                // "tcp4 172.16.0.100:55775<->17.57.146.183:5223"
                let head = f[0][..<arrow.lowerBound]
                let parts = head.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let proto = String(parts[0])
                let remote = String(f[0][arrow.upperBound...])
                guard remote != "*:*", remote != "*.*" else { continue }
                let (host, port) = split(remote, v6: proto.hasSuffix("6"))
                let bin = UInt64(f[3]) ?? 0, bout = UInt64(f[4]) ?? 0
                if f[1].isEmpty && bin == 0 && bout == 0 { continue }
                result.append(NetConnection(key: "\(pid)|\(f[0])", process: process, pid: pid, proto: proto,
                                            local: String(parts[1]), remoteHost: host, remotePort: port,
                                            interface: f[1], state: f[2].isEmpty ? (proto.hasPrefix("udp") ? "—" : "") : f[2],
                                            bytesIn: bin, bytesOut: bout))
            } else if let dot = f[0].lastIndex(of: "."), let p = pid_t(f[0][f[0].index(after: dot)...]) {
                process = String(f[0][..<dot]); pid = p
            }
        }
        return result
    }

    /// "1.2.3.4:443" -> ("1.2.3.4", "443"); IPv6 uses a final "." before the port.
    private static func split(_ s: String, v6: Bool) -> (String, String) {
        let sep: Character = v6 ? "." : ":"
        guard let i = s.lastIndex(of: sep) else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }
}
