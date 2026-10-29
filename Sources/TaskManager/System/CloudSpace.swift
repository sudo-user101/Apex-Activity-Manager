import Foundation

/// One file in a synced folder, as the folder scan read it (metadata only:
/// nothing is downloaded).
struct CloudEntry: Sendable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let bytes: UInt64              // its size (online-only files included)
    let onMac: UInt64              // what it takes on this Mac
    var lastUsed: Date?            // opened or changed
    var name: String { (path as NSString).lastPathComponent }
    var onlineOnly: Bool { bytes > 0 && onMac == 0 }
}

/// Cloud Disks › what fills a service's online storage (online-only files
/// count: they're what it holds) and what could be removed to free some:
/// extra copies, old installers, big files unused for a year. Pure apart
/// from `sameContent` (passed in): tested.
struct CloudSpace: Sendable, Equatable {
    struct Folder: Sendable, Equatable, Identifiable {
        var id: String { path }
        let name: String
        let path: String
        var bytes: UInt64 = 0
        var files = 0
    }
    enum Kind: String, Sendable, CaseIterable { case duplicates, installers, unused }
    struct Suggestion: Sendable, Equatable, Identifiable {
        var id: String { kind.rawValue }
        let kind: Kind
        let items: [CloudEntry]
        var bytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
    }
    var folders: [Folder] = []
    var largest: [CloudEntry] = []
    var suggestions: [Suggestion] = []
    var totalBytes: UInt64 = 0

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "msi", "exe", "apk", "appimage", "deb", "rpm"]
    static let unusedAfter: TimeInterval = 365 * 86400
    static let unusedMinBytes: UInt64 = 100_000_000
    static let installerAfter: TimeInterval = 30 * 86400
    static let bigEnough: UInt64 = 1_000_000

    /// Built one file at a time during the folder walk; only files of 1 MB or
    /// more are kept for the lists, so memory stays small on big folders.
    struct Builder {
        let root: String
        let now: Date
        private var o = CloudSpace()
        private var folders: [String: Folder] = [:]
        private var big: [CloudEntry] = []

        /// The same folder as the walk reports it (links resolved: /var → /private/var).
        private let realRoot: String

        init(root: String, realRoot: String? = nil, now: Date = Date()) {
            func trim(_ r: String) -> String { r.count > 1 && r.hasSuffix("/") ? String(r.dropLast()) : r }
            self.root = trim(root); self.realRoot = trim(realRoot ?? root); self.now = now
        }

        mutating func add(_ e: CloudEntry) {
            o.totalBytes += e.bytes
            // The first folder under the root (files at the top level together).
            let rel = e.path.hasPrefix(root + "/") ? String(e.path.dropFirst(root.count + 1))
                : e.path.hasPrefix(realRoot + "/") ? String(e.path.dropFirst(realRoot.count + 1)) : e.name
            let first = rel.split(separator: "/", maxSplits: 1)
            let key = first.count > 1 ? String(first[0]) : ""
            var f = folders[key] ?? Folder(name: key.isEmpty ? "Files at the top level" : key, path: key.isEmpty ? root : root + "/" + key)
            f.bytes += e.bytes; f.files += 1
            folders[key] = f
            if e.bytes >= CloudSpace.bigEnough, big.count < 50_000, !CloudSpace.isInsideSomething(rel) { big.append(e) }
        }

        /// `sameContent`: true/false when both copies can be compared on this
        /// Mac, nil when either is online-only (then the same name and size counts).
        func finish(sameContent: (CloudEntry, CloudEntry) -> Bool?) -> CloudSpace {
            var o = self.o
            o.folders = folders.values.sorted { $0.bytes > $1.bytes }
            o.largest = Array(big.sorted { $0.bytes > $1.bytes }.prefix(12))

            var taken = Set<String>()
            let dups = CloudSpace.duplicates(big, sameContent: sameContent)
            taken.formUnion(dups.map(\.path))
            let installers = big.filter { e in
                !taken.contains(e.path) && CloudSpace.installerExtensions.contains((e.path as NSString).pathExtension.lowercased())
                    && (e.lastUsed.map { now.timeIntervalSince($0) > CloudSpace.installerAfter } ?? true)
            }.sorted { $0.bytes > $1.bytes }
            taken.formUnion(installers.map(\.path))
            let unused = big.filter { e in
                !taken.contains(e.path) && e.bytes >= CloudSpace.unusedMinBytes
                    && (e.lastUsed.map { now.timeIntervalSince($0) > CloudSpace.unusedAfter } ?? false)
            }.sorted { $0.bytes > $1.bytes }
            o.suggestions = [Suggestion(kind: .duplicates, items: dups), Suggestion(kind: .installers, items: installers),
                             Suggestion(kind: .unused, items: Array(unused.prefix(50)))].filter { !$0.items.isEmpty }
            return o
        }
    }

    /// Extra copies (the one kept is left out): files of the same size whose
    /// contents match, or, when they can't be compared here, also have the
    /// same name ("Report (1).pdf" and "Report 2.pdf" count as "Report.pdf").
    static func duplicates(_ files: [CloudEntry], sameContent: (CloudEntry, CloudEntry) -> Bool?) -> [CloudEntry] {
        var extras: [CloudEntry] = []
        for (_, group) in Dictionary(grouping: files, by: \.bytes) where group.count > 1 {
            // Shortest path first: usually the original.
            var left = group.sorted { ($0.path.count, $0.path) < ($1.path.count, $1.path) }
            while let keep = left.first {
                left.removeFirst()
                let same = left.filter { other in
                    sameContent(keep, other) ?? (baseName(keep.name) == baseName(other.name))
                }
                extras += same
                left.removeAll { e in same.contains { $0.path == e.path } }
            }
        }
        return extras.sorted { $0.bytes > $1.bytes }
    }

    /// Inside an app, a library or package, a project's hidden or build
    /// folders: removing one file there breaks the whole thing, and copies
    /// there are normal. Counted in the sizes, never suggested. Pure: tested.
    static func isInsideSomething(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").dropLast()
        let packages = ["app", "framework", "bundle", "photoslibrary", "musiclibrary", "tvlibrary", "xcodeproj", "xcworkspace",
                        "pkg", "plugin", "kext", "appex", "xpc", "fcpbundle", "logicx", "band", "sparsebundle", "photolibrary"]
        let folders: Set<String> = ["node_modules", "Pods", "DerivedData", "build", ".build", "dist", "target", "vendor", "__pycache__", "venv"]
        return parts.contains { p in
            p.hasPrefix(".") || folders.contains(String(p)) || packages.contains((String(p) as NSString).pathExtension.lowercased())
        }
    }

    /// "Report (1).PDF", "Report 2.pdf", "Report copy.pdf" → "report.pdf". Pure: tested.
    static func baseName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        var stem = (name as NSString).deletingPathExtension.lowercased()
        for pattern in [#" \(\d+\)$"#, #" \d+$"#, #" copy( \d+)?$"#, #"-\d+$"#] {
            if let r = stem.range(of: pattern, options: .regularExpression) { stem.removeSubrange(r); break }
        }
        return ext.isEmpty ? stem : stem + "." + ext
    }

    /// Byte-for-byte, for two files stored on this Mac (nil if either isn't:
    /// comparing would download it). Blocking.
    static func sameContent(_ a: CloudEntry, _ b: CloudEntry) -> Bool? {
        guard !a.onlineOnly, !b.onlineOnly, a.bytes == b.bytes,
              let fa = FileHandle(forReadingAtPath: a.path), let fb = FileHandle(forReadingAtPath: b.path) else { return nil }
        defer { try? fa.close(); try? fb.close() }
        while true {
            let x = (try? fa.read(upToCount: 1 << 20)) ?? Data()
            let y = (try? fb.read(upToCount: 1 << 20)) ?? Data()
            if x != y { return false }
            if x.isEmpty { return true }
        }
    }

    /// `sameContent` with a reading budget per scan, so a folder full of
    /// big same-size files doesn't take minutes: files over `maxFile` and
    /// pairs past `budget` bytes read get nil (then the same name and size count).
    final class Comparer: @unchecked Sendable {
        private var left: UInt64
        private let maxFile: UInt64
        init(budget: UInt64 = 2_000_000_000, maxFile: UInt64 = 512_000_000) { left = budget; self.maxFile = maxFile }
        func callAsFunction(_ a: CloudEntry, _ b: CloudEntry) -> Bool? {
            guard a.bytes <= maxFile, 2 * a.bytes <= left else { return nil }
            left -= 2 * a.bytes
            return CloudSpace.sameContent(a, b)
        }
    }

}
