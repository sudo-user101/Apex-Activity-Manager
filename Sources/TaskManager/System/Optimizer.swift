import AppKit
import Foundation

// Optimize: bounded maintenance tasks,
// each explained, each reporting applied / unchanged / skipped with a reason.
// Nothing here deletes your files; admin tasks share one password prompt.

struct OptimizeTask: Identifiable, Sendable, Hashable {
    enum ID: String, CaseIterable, Sendable { case quicklook, iconCache, dns, databases, quarantine, launchServices, fileCache }
    let id: ID
    var title: String
    var detail: String
    var needsAdmin: Bool
    var defaultOn: Bool

    static let all: [OptimizeTask] = [
        .init(id: .quicklook, title: "Refresh Quick Look previews",
              detail: "Rebuilds the thumbnail and preview cache, which fixes blank or wrong previews in Finder.", needsAdmin: false, defaultOn: true),
        .init(id: .iconCache, title: "Refresh app icons",
              detail: "Clears your icon cache so wrong or missing app icons are redrawn. The Dock restarts.", needsAdmin: false, defaultOn: true),
        .init(id: .dns, title: "Refresh the network name cache (DNS)",
              detail: "Fixes websites that won’t load after a network or VPN change. Skipped while a VPN is on.", needsAdmin: true, defaultOn: true),
        .init(id: .databases, title: "Compact app databases",
              detail: "Checks and shrinks Safari history and Mail’s message index so they stay fast. Apps that are open are skipped.", needsAdmin: false, defaultOn: true),
        .init(id: .quarantine, title: "Clear the download history log",
              detail: "macOS keeps a record of every file you’ve downloaded. Clearing it is private and harmless.", needsAdmin: false, defaultOn: false),
        .init(id: .launchServices, title: "Rebuild the “Open With” list",
              detail: "Removes duplicate or missing apps in the Open With menu. Takes a minute.", needsAdmin: false, defaultOn: false),
        .init(id: .fileCache, title: "Clear file cache (purge)",
              detail: "Empties macOS’s file cache. Things may feel slower for a moment while it refills.", needsAdmin: true, defaultOn: false),
    ]
}

enum OptimizeOutcome: Sendable, Equatable {
    case applied(String), unchanged(String), skipped(String), failed(String)
    var text: String {
        switch self { case .applied(let s), .unchanged(let s), .skipped(let s), .failed(let s): return s }
    }
}

/// "Performance diagnosis" lines, from what Apex already measures.
struct Diagnosis: Sendable, Hashable { var ok: Bool; var text: String }

enum Optimizer {
    private static let home = NSHomeDirectory()

    @MainActor static func diagnose() -> [Diagnosis] {
        let s = AppModel.shared.snapshot.system
        var out: [Diagnosis] = []
        let hourAgo = Date().addingTimeInterval(-3600)
        let cpu = EventLog.shared.events.filter { $0.rule == .appCPU && $0.kind != .spike && $0.date > hourAgo }
        out.append(cpu.isEmpty ? .init(ok: true, text: "No app has been stuck on high CPU in the last hour")
                               : .init(ok: false, text: "High CPU in the last hour: " + Set(cpu.compactMap(\.subject)).sorted().joined(separator: ", ")))
        let p = s.memory.pressureLevel
        out.append(.init(ok: p == .normal, text: "Memory pressure is \(p.title.lowercased())" + (p == .normal ? "" : "; quitting unused apps helps more than any clean-up")))
        let free = Double(s.disk.available) / Double(max(1, s.disk.capacity))
        out.append(.init(ok: free >= 0.1, text: "\(Fmt.diskBytes(s.disk.available)) free on \(s.disk.volumeName) (\(Int(free * 100))%)"))
        if let r = DriveHealthStore.shared.startup {
            let a = DriveHealthRules.assess(r)
            out.append(.init(ok: a.status == .good || a.status == .learning, text: "Startup drive health: \(a.status.title.lowercased())"))
        }
        let swap = s.memory.swapUsed
        if swap > s.memory.total / 2 { out.append(.init(ok: false, text: "\(Fmt.bytes(swap)) of swap in use; a restart clears it")) }
        return out
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static var vpnActive: Bool {
        // A VPN adds a utun/ipsec interface with an IPv4 address to the primary service.
        guard let store = SCDynamicStoreCreate(nil, "Apex" as CFString, nil, nil),
              let g = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let iface = g["PrimaryInterface"] as? String else { return false }
        return iface.hasPrefix("utun") || iface.hasPrefix("ipsec") || iface.hasPrefix("ppp")
    }

    /// Runs the chosen tasks; admin ones together under one prompt.
    static func run(_ ids: Set<OptimizeTask.ID>, progress: @escaping @Sendable (OptimizeTask.ID, OptimizeOutcome?) -> Void) {
        for t in OptimizeTask.all where ids.contains(t.id) && !t.needsAdmin {
            progress(t.id, nil)
            progress(t.id, runUser(t.id))
        }
        var admin: [(OptimizeTask.ID, String)] = []
        if ids.contains(.dns) {
            if vpnActive { progress(.dns, .skipped("Skipped: a VPN is connected, and refreshing could drop it.")) }
            else { admin.append((.dns, "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")) }
        }
        if ids.contains(.fileCache) { admin.append((.fileCache, "/usr/sbin/purge")) }
        guard !admin.isEmpty else { return }
        for (id, _) in admin { progress(id, nil) }
        let r = Shell.runAsAdmin(admin.map(\.1).joined(separator: "; "),
                                 prompt: "Apex Activity Manager wants to run maintenance: " + admin.map { id, _ in OptimizeTask.all.first { $0.id == id }!.title.lowercased() }.joined(separator: ", ") + ".")
        for (id, _) in admin {
            if r.status == 0 { progress(id, .applied(id == .dns ? "DNS cache refreshed" : "File cache cleared")) }
            else { progress(id, Shell.isUserCancelled(r) ? .skipped("Skipped: no administrator approval.") : .failed("Failed: " + r.stderr.prefix(160))) }
        }
    }

    private static func runUser(_ id: OptimizeTask.ID) -> OptimizeOutcome {
        let fm = FileManager.default
        switch id {
        case .quicklook:
            let a = Shell.run("/usr/bin/qlmanage", ["-r", "cache"]), b = Shell.run("/usr/bin/qlmanage", ["-r"])
            return a.status == 0 || b.status == 0 ? .applied("Quick Look previews refreshed") : .failed("Quick Look didn’t respond")
        case .iconCache:
            let dirs = [home + "/Library/Caches/com.apple.iconservices.store", home + "/Library/Caches/com.apple.iconservices"]
            var removed = 0
            for d in dirs where fm.fileExists(atPath: d) { if (try? fm.trashItem(at: URL(fileURLWithPath: d), resultingItemURL: nil)) != nil { removed += 1 } }
            _ = Shell.run("/usr/bin/killall", ["Dock"])
            return .applied(removed > 0 ? "Icon cache cleared; Dock restarted" : "Icons refreshed (no user icon cache to clear)")
        case .databases:
            var dbs: [(path: String, app: String, bundle: String)] = [
                (home + "/Library/Safari/History.db", "Safari", "com.apple.Safari"),
            ]
            if let mail = try? fm.contentsOfDirectory(atPath: home + "/Library/Mail") {
                for v in mail where v.hasPrefix("V") { dbs.append((home + "/Library/Mail/\(v)/MailData/Envelope Index", "Mail", "com.apple.mail")) }
            }
            var saved: Int64 = 0, done: [String] = [], skipped: [String] = []
            for db in dbs where fm.isReadableFile(atPath: db.path) {
                if isRunning(db.bundle) { skipped.append(db.app); continue }
                let before = (try? fm.attributesOfItem(atPath: db.path)[.size] as? NSNumber)?.int64Value ?? 0
                let check = Shell.run("/usr/bin/sqlite3", [db.path, "PRAGMA integrity_check;"])
                guard check.status == 0, check.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else { skipped.append(db.app + " (check failed)"); continue }
                guard Shell.run("/usr/bin/sqlite3", [db.path, "VACUUM;"]).status == 0 else { skipped.append(db.app); continue }
                let after = (try? fm.attributesOfItem(atPath: db.path)[.size] as? NSNumber)?.int64Value ?? before
                saved += max(0, before - after); done.append(db.app)
            }
            if done.isEmpty && skipped.isEmpty { return .unchanged("No app databases Apex can reach (Full Disk Access may be needed)") }
            if done.isEmpty { return .skipped("Skipped: close " + skipped.joined(separator: ", ") + " first") }
            return .applied("Compacted " + done.joined(separator: ", ") + (saved > 0 ? ", saved \(Fmt.diskBytes(UInt64(saved)))" : ", already compact")
                            + (skipped.isEmpty ? "" : "; skipped " + skipped.joined(separator: ", ")))
        case .quarantine:
            let db = home + "/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
            guard fm.fileExists(atPath: db) else { return .unchanged("No download history kept") }
            let count = Shell.run("/usr/bin/sqlite3", [db, "SELECT COUNT(*) FROM LSQuarantineEvent;"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if count == "0" { return .unchanged("Download history is already empty") }
            let r = Shell.run("/usr/bin/sqlite3", [db, "DELETE FROM LSQuarantineEvent; VACUUM;"])
            return r.status == 0 ? .applied("Cleared \(count) download records") : .failed("Couldn’t clear it (Full Disk Access may be needed)")
        case .launchServices:
            let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            let r = Shell.run(tool, ["-kill", "-r", "-domain", "local", "-domain", "user"])
            return r.status == 0 ? .applied("Open With list rebuilt") : .failed("Rebuild failed")
        case .dns, .fileCache:
            return .skipped("")
        }
    }
}

import SystemConfiguration
