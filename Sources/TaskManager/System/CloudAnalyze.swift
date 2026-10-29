import Foundation

/// Analyze inside a cloud folder (iCloud Drive, a service's folder): sizes
/// count everything, online-only files included, and each item says where
/// it is: only online, on this Mac, partly, or still syncing. Folders whose
/// contents are only online are listed too (that asks the server), each
/// given a few seconds so an unreachable server can't hold Analyze up.
enum CloudAnalyze {
    struct Status: Sendable, Equatable {
        var total: UInt64 = 0          // everything, online-only included
        var onMac: UInt64 = 0          // what's stored on this Mac
        var syncing = 0                // files not uploaded yet
        var unlisted = 0               // folders the server didn't list in time
        enum Where: Sendable { case onMac, online, partly, syncing }
        /// Pure: tested.
        var place: Where {
            if syncing > 0 { return .syncing }
            if total > 0 && onMac == 0 { return .online }
            if onMac + 4096 < total { return .partly }
            return .onMac
        }
    }

    /// Inside iCloud Drive or a service's folder in ~/Library/CloudStorage.
    static func isCloud(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        path.hasPrefix(home + "/Library/CloudStorage/") || path.hasPrefix(home + "/Library/Mobile Documents/")
    }

    /// Seconds a folder that's only online gets to be listed by the server.
    static let listWait: TimeInterval = 4
    /// Upload state is read (≈2 ms a file) for files changed in the last week only.
    static let recent: TimeInterval = 7 * 86400

    /// A folder's names, waiting at most `listWait` when its contents are
    /// only online. Nil when it couldn't be listed in time.
    static func list(_ dir: String) -> [String]? {
        guard Dataless.folder(dir) else { return try? FileManager.default.contentsOfDirectory(atPath: dir) }
        final class Box: @unchecked Sendable { var names: [String]? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { box.names = try? FileManager.default.contentsOfDirectory(atPath: dir); done.signal() }
        return done.wait(timeout: .now() + listWait) == .success ? box.names : nil
    }

    /// One item: a file's sizes and state, or a folder walked (depth-first, at
    /// most `budget` seconds of server waits in total).
    static func measure(_ path: String, cancelled: () -> Bool = { false }, now: Date = Date()) -> Status {
        var s = Status()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey]
        var checked = 0
        var waited: TimeInterval = 0
        func file(_ url: URL, _ v: URLResourceValues) {
            s.total += UInt64(v.fileSize ?? 0)
            s.onMac += UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            if checked < 500, let m = v.contentModificationDate, now.timeIntervalSince(m) < recent {
                checked += 1
                if (try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]))?.ubiquitousItemIsUploaded == false { s.syncing += 1 }
            }
        }
        func walk(_ dir: String, depth: Int) {
            if cancelled() || depth > 40 { return }
            let start = Date()
            let names: [String]?
            if Dataless.folder(dir) {
                if waited > 20 { s.unlisted += 1; return }              // enough waiting on the server for one item
                names = list(dir)
                waited += Date().timeIntervalSince(start)
            } else {
                names = try? FileManager.default.contentsOfDirectory(atPath: dir)
            }
            guard let names else { s.unlisted += 1; return }
            for n in names {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(n)
                guard let v = try? url.resourceValues(forKeys: keys), v.isSymbolicLink != true else { continue }
                if v.isDirectory == true { walk(url.path, depth: depth + 1) } else { file(url, v) }
            }
        }
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: keys) else { return s }
        if v.isDirectory == true { walk(path, depth: 0) } else { file(url, v) }
        return s
    }
}
