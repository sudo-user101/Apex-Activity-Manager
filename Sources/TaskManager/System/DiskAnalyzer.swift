import Foundation

// Analyze: start from the big
// locations, then drill into any folder to see what takes the space.

struct DiskEntry: Identifiable, Sendable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var size: UInt64?            // nil while measuring
    var partial = false          // some contents couldn't be read
    var note = ""                // e.g. ">3 months"
}

enum DiskAnalyzer {
    private static let home = NSHomeDirectory()

    /// The overview: the big locations first.
    static func roots() -> [DiskEntry] {
        var r: [DiskEntry] = [
            .init(name: "Home", path: home, isDirectory: true),
            .init(name: "User Library", path: home + "/Library", isDirectory: true),
            .init(name: "Applications", path: "/Applications", isDirectory: true),
            .init(name: "System Library", path: "/Library", isDirectory: true),
            .init(name: "Old Downloads (90 days+)", path: oldDownloadsKey, isDirectory: true, note: ">3 months"),
        ]
        for v in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        where v.path.hasPrefix("/Volumes/") {
            r.append(.init(name: v.lastPathComponent, path: v.path, isDirectory: true, note: "drive"))
        }
        return r
    }

    static let oldDownloadsKey = "apex://old-downloads"

    /// Children of a folder (largest first), measured on the caller's thread.
    static func children(of path: String) -> [DiskEntry] {
        let fm = FileManager.default
        if path == oldDownloadsKey { return oldDownloads() }
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return names.map { n in
            let full = (path as NSString).appendingPathComponent(n)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            let pkg = isDir.boolValue && NSWorkspaceBridge.isPackage(full)
            return DiskEntry(name: n, path: full, isDirectory: isDir.boolValue && !pkg)
        }
    }

    static func oldDownloads() -> [DiskEntry] {
        let dir = URL(fileURLWithPath: home + "/Downloads")
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey, .isDirectoryKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard let d = v?.addedToDirectoryDate ?? v?.contentModificationDate, d < cutoff else { return nil }
            return DiskEntry(name: u.lastPathComponent, path: u.path, isDirectory: v?.isDirectory ?? false,
                             note: d.formatted(date: .abbreviated, time: .omitted))
        }
    }

    /// Allocated size on disk (what Finder's "on disk" shows), and whether
    /// anything inside couldn't be read.
    static func measure(_ path: String, cancelled: () -> Bool = { false }) -> (UInt64, Bool) {
        if path == oldDownloadsKey {
            var total: UInt64 = 0, partial = false
            for e in oldDownloads() { let (s, p) = measure(e.path, cancelled: cancelled); total += s; partial = partial || p }
            return (total, partial)
        }
        guard FileManager.default.fileExists(atPath: path) else { return (0, true) }
        let r = withoutActuallyEscaping(cancelled) { c in FastSize.allocated(path, cancelled: c) }
        return (r.bytes, r.partial)
    }
}

import AppKit
enum NSWorkspaceBridge {
    static func isPackage(_ path: String) -> Bool { NSWorkspace.shared.isFilePackage(atPath: path) }
}
