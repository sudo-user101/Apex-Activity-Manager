import Foundation

/// Space used on disk by a file or folder tree (allocated size, like Finder's
/// "on disk"). Folders are measured in parallel: the top-level items are
/// split across all CPU cores, each walked with Foundation's enumerator
/// (which reads directories in bulk).
enum FastSize {
    private static let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
    private static let keySet = Set(keys)

    /// Allocated bytes, and whether anything inside couldn't be read.
    static func allocated(_ path: String, cancelled: @escaping () -> Bool = { false }) -> (bytes: UInt64, partial: Bool) {
        split(URL(fileURLWithPath: path), depth: 0, cancelled: cancelled)
    }

    /// Folders near the top are split into their children (two levels), so one
    /// huge subfolder doesn't end up on a single core.
    private static func split(_ url: URL, depth: Int, cancelled: @escaping () -> Bool) -> (bytes: UInt64, partial: Bool) {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return (0, true) }
        if v.isDirectory != true || v.isSymbolicLink == true {
            return (UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0), false)
        }
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys + [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return (0, true)
        }
        var sizes = [UInt64](repeating: 0, count: children.count)
        var partials = [Bool](repeating: false, count: children.count)
        sizes.withUnsafeMutableBufferPointer { s in
            partials.withUnsafeMutableBufferPointer { p in
                DispatchQueue.concurrentPerform(iterations: children.count) { i in
                    (s[i], p[i]) = depth < 1 ? split(children[i], depth: depth + 1, cancelled: cancelled)
                                             : walk(children[i], cancelled: cancelled)
                }
            }
        }
        return (sizes.reduce(0, &+), partials.contains(true))
    }

    /// One item: a file's size, or a folder walked on this thread.
    private static func walk(_ url: URL, cancelled: () -> Bool) -> (UInt64, Bool) {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if v?.isDirectory != true || v?.isSymbolicLink == true {
            return (UInt64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0), v == nil)
        }
        var partial = false
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                     errorHandler: { _, _ in partial = true; return true }) else { return (0, true) }
        var total: UInt64 = 0, n = 0
        for case let u as URL in e {
            n += 1
            if n & 4095 == 0, cancelled() { return (total, true) }
            guard let r = try? u.resourceValues(forKeys: keySet), r.isRegularFile == true else { continue }
            total &+= UInt64(r.totalFileAllocatedSize ?? r.fileAllocatedSize ?? 0)
        }
        return (total, partial)
    }

    /// Sizes several paths at once.
    static func allocated(_ paths: [String]) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: paths.count)
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in buf[i] = allocated(paths[i]).bytes }
        }
        return out
    }
}
