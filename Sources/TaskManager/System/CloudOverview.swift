import Foundation

/// Cloud Disks › Overview: every service at once, in plain words: what's
/// backed up and what isn't, why uploads are stuck, what takes the space,
/// and what to free. Pure: built from what the scans already found; tested.
enum CloudOverview {
    enum Level: Int, Comparable, Sendable {
        case ok, info, notice, warning
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    enum Action: Hashable, Sendable {
        case makeOnlineOnly(String)      // service id: its files not opened lately
        case checkUploads(String)
        case openService(String)
        case openICloudSettings
    }

    struct Suggestion: Identifiable, Hashable, Sendable {
        var id: String
        var level: Level
        var title: String
        var detail: String
        var bytes: UInt64 = 0
        var action: Action? = nil
        var actionTitle = ""
    }

    struct Totals: Equatable, Sendable {
        var onMac: UInt64 = 0
        var onlineOnlyFiles = 0
        var notUploaded = 0
        var notUploadedBytes: UInt64 = 0
        var untouchedBytes: UInt64 = 0
    }

    static func totals(_ usage: [CloudUsage]) -> Totals {
        usage.reduce(into: Totals()) { t, u in
            t.onMac += u.onMacBytes
            t.onlineOnlyFiles += u.onlineOnly
            t.notUploaded += u.notUploaded
            t.notUploadedBytes += u.notUploadedBytes
            t.untouchedBytes += u.untouched.reduce(0) { $0 + $1.bytes }
        }
    }

    /// Space on this Mac by kind of file, across every service, biggest first.
    static func kinds(_ usage: [CloudUsage]) -> [(kind: String, bytes: UInt64)] {
        var all: [String: UInt64] = [:]
        for u in usage { for (k, b) in u.kinds { all[k, default: 0] += b } }
        return all.filter { $0.value > 0 }.map { ($0.key, $0.value) }.sorted { $0.bytes > $1.bytes }
    }

    /// Below this, files not opened lately aren't worth a suggestion.
    static let worthFreeing: UInt64 = 500_000_000

    static func suggestions(services: [CloudService], usage: [String: CloudUsage], quota: [String: CloudQuota],
                            appProblem: [String: CloudUpload.AppProblem], serverDown: [String: Bool],
                            folders: [(name: String, inCloud: String?)], hasTimeMachine: Bool) -> [Suggestion] {
        var out: [Suggestion] = []
        for s in services {
            let name = s.name
            if let u = usage[s.id], u.notUploaded > 0 {
                let files = "\(u.notUploaded) file\(u.notUploaded == 1 ? "" : "s")"
                var why: String?
                if let p = appProblem[s.id] { why = CloudUpload.appMessage(p, service: name) }
                else if serverDown[s.id] == true { why = "Apex can’t reach \(name)’s server, so nothing can upload." }
                else if let top = u.uploadIssues.max(by: { $0.value < $1.value }) {
                    why = top.key + (u.uploadIssues.count > 1 ? " (and other reasons)" : "")
                }
                if let why {
                    out.append(Suggestion(id: "stuck:" + s.id, level: .warning,
                                          title: "\(files) in \(name) aren’t backed up: uploads are stuck",
                                          detail: why + " Until they upload, they’re only on this Mac.",
                                          bytes: u.notUploadedBytes, action: .checkUploads(s.id), actionTitle: "Check Uploads"))
                } else {
                    out.append(Suggestion(id: "waiting:" + s.id, level: .info,
                                          title: "\(files) in \(name) are still uploading",
                                          detail: "They’re only on this Mac until the upload finishes. Keep \(name) open and online.",
                                          bytes: u.notUploadedBytes, action: .checkUploads(s.id), actionTitle: "Check Uploads"))
                }
            }
            if let u = usage[s.id], s.kind != .webdav {
                let bytes = u.untouched.reduce(0) { $0 + $1.bytes }
                if bytes >= worthFreeing {
                    out.append(Suggestion(id: "untouched:" + s.id, level: .notice,
                                          title: "Free \(Fmt.diskBytes(bytes)) on this Mac from \(name)",
                                          detail: "\(u.untouched.count) file\(u.untouched.count == 1 ? "" : "s") you haven’t opened in \(Cloud.untouchedDays / 30) months \(u.untouched.count == 1 ? "is" : "are") already in \(name). Making them online-only frees the space; they download again when you open them.",
                                          bytes: bytes, action: .makeOnlineOnly(s.id), actionTitle: "Make Online-Only…"))
                }
            }
            if let q = quota[s.id], let total = q.total, total > 0 {
                let full = Double(q.used) / Double(total)
                if full >= 0.9 {
                    out.append(Suggestion(id: "full:" + s.id, level: full >= 0.97 ? .warning : .notice,
                                          title: "\(name)’s online storage is \(Int(full * 100))% full",
                                          detail: "When it’s full, nothing new can upload. Making files online-only doesn’t free online space: delete what you don’t need from \(name) (and empty its online trash), or get a bigger plan.",
                                          action: .openService(s.id), actionTitle: "Show \(name)"))
                }
            }
        }
        let outside = folders.filter { $0.inCloud == nil }.map(\.name)
        if !outside.isEmpty {
            let names = outside.joined(separator: " and ")
            let verb = outside.count == 1 ? "isn’t" : "aren’t"
            out.append(Suggestion(id: "folders", level: hasTimeMachine ? .info : .warning,
                                  title: "\(names) \(verb) in any cloud",
                                  detail: hasTimeMachine
                                    ? "Time Machine backs \(outside.count == 1 ? "it" : "them") up, but only to your backup drive. To have \(outside.count == 1 ? "it" : "them") everywhere, turn on Desktop & Documents Folders in iCloud Drive."
                                    : "Nothing backs \(outside.count == 1 ? "it" : "them") up: if this Mac is lost or breaks, \(outside.count == 1 ? "it’s" : "they’re") gone. Turn on Desktop & Documents Folders in iCloud Drive, or set up Time Machine.",
                                  action: .openICloudSettings, actionTitle: "iCloud Settings…"))
        }
        // The all-clear only once every cloud disk with a folder has been checked.
        let unchecked = services.filter { !$0.path.isEmpty && usage[$0.id] == nil }.map(\.name)
        let allChecked = unchecked.isEmpty
        if !allChecked {
            out.append(Suggestion(id: "checking", level: .info,
                                  title: "Checking " + ListFormatter.localizedString(byJoining: unchecked) + "…",
                                  detail: "A big cloud folder takes a minute or so. Nothing is downloaded."))
        }
        if out.isEmpty, !usage.isEmpty, allChecked {
            let limited = usage.values.contains(where: \.uploadCheckLimited)
            out.append(Suggestion(id: "ok", level: .ok, title: "Everything you changed lately is backed up",
                                  detail: (limited ? "The \(Cloud.uploadCheckLimit) files you changed most recently in each cloud folder are"
                                                   : "Every file you changed in the last \(Cloud.uploadCheckDays) days is")
                                    + " in the cloud (older files uploaded when they changed), and nothing big has gone unopened for months."))
        }
        return out.sorted { $0.level > $1.level }
    }
}
