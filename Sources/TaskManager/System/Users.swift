import Darwin
import Foundation

struct UserSummary: Identifiable, Hashable, Sendable {
    var id: uid_t { uid }
    let uid: uid_t
    let name: String
    let fullName: String
    let status: String
    let cpu: Double
    let memory: UInt64
    let processes: Int
    let isCurrent: Bool
}

enum Users {
    /// Users with a login session (console or terminal), from utmpx.
    static func loggedIn() -> [String: Int] {
        var sessions: [String: Int] = [:]
        setutxent()
        defer { endutxent() }
        while let e = getutxent() {
            guard e.pointee.ut_type == USER_PROCESS else { continue }
            let name = String(cTuple: e.pointee.ut_user)
            if !name.isEmpty { sessions[name, default: 0] += 1 }
        }
        return sessions
    }

    /// Aggregates the current process sample per user. Status distinguishes
    /// real logged-in people from system service accounts.
    static func summarize(_ procs: [ProcessInfoSample], sessions: [String: Int]) -> [UserSummary] {
        let me = getuid()
        var agg: [uid_t: (name: String, cpu: Double, mem: UInt64, n: Int)] = [:]
        for p in procs {
            var a = agg[p.uid] ?? (p.user, 0, 0, 0)
            a.cpu += p.cpu; a.mem += p.memory; a.n += 1
            agg[p.uid] = a
        }
        return agg.map { uid, a in
            let status: String
            if let n = sessions[a.name] { status = n > 1 ? "Logged in (\(n) sessions)" : "Logged in" }
            else if uid == 0 { status = "System (root)" }
            else if uid < 500 || a.name.hasPrefix("_") { status = "Service account" }
            else { status = "Not logged in" }
            var full = ""
            if let pw = getpwuid(uid), let g = pw.pointee.pw_gecos { full = String(cString: g) }
            return UserSummary(uid: uid, name: a.name, fullName: full, status: status, cpu: a.cpu,
                               memory: a.mem, processes: a.n, isCurrent: uid == me)
        }
        .sorted { ($0.isCurrent ? 0 : 1, -$0.processes) < ($1.isCurrent ? 0 : 1, -$1.processes) }
    }
}
