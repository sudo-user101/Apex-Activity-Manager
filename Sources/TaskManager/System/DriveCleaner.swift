import Foundation

/// Space you can safely get back on a plugged-in drive. Only two kinds of
/// things are offered for removal, both listed for review first:
///  * the drive's own Trash (`.Trashes/<uid>`): files you already deleted;
///    they still take space until it's emptied,
///  * macOS helper files (`._name`) that macOS writes next to every file on
///    drives that can't store Finder info natively (exFAT, FAT, NTFS…).
/// Everything else is shown in Analyze for the user to decide.
enum DriveCleaner {
    struct Item: Hashable, Sendable { var path: String; var size: UInt64 }
    struct Scan: Sendable {
        var trash: [Item] = []
        var helpers: [Item] = []
        var helpersApply = false      // false on APFS / Mac OS Extended
        var writable = true
        var trashSize: UInt64 { trash.reduce(0) { $0 + $1.size } }
        var helperSize: UInt64 { helpers.reduce(0) { $0 + $1.size } }
    }

    /// Formats that keep Finder info natively, so `._` files aren't expected.
    static func nativeMetadata(_ format: String) -> Bool {
        let f = format.lowercased()
        return f.contains("apfs") || f.contains("mac os") || f.contains("hfs")
    }

    /// Folders macOS manages on every drive; never touched or counted.
    static let systemFolders: Set<String> = [".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100", "System Volume Information", "$RECYCLE.BIN"]

    static func isHelperFile(_ name: String) -> Bool { name.hasPrefix("._") && name.count > 2 }

    /// `isHelper` is swappable for tests: APFS turns `._` files into extended
    /// attributes, so they can't be created in a temporary folder.
    static func scan(volume: String, format: String, isHelper: (String) -> Bool = isHelperFile,
                     cancelled: () -> Bool = { false }) -> Scan {
        let fm = FileManager.default
        var s = Scan()
        s.writable = fm.isWritableFile(atPath: volume)
        let trashDir = volume + "/.Trashes/\(getuid())"
        if let names = try? fm.contentsOfDirectory(atPath: trashDir) {
            s.trash = names.map { n in
                let p = trashDir + "/" + n
                return Item(path: p, size: DiskAnalyzer.measure(p, cancelled: cancelled).0)
            }
        }
        s.helpersApply = !nativeMetadata(format)
        guard s.helpersApply else { return s }
        let url = URL(fileURLWithPath: volume)
        let keys: [URLResourceKey] = [.fileAllocatedSizeKey, .isRegularFileKey]
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return s }
        for case let u as URL in e {
            if cancelled() { break }
            let name = u.lastPathComponent
            if systemFolders.contains(name) { e.skipDescendants(); continue }
            guard isHelper(name), let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            s.helpers.append(Item(path: u.path, size: UInt64(v.fileAllocatedSize ?? 0)))
        }
        return s
    }

    /// Deletes the given items for good (they're in the Trash already, or are
    /// helper files). Returns bytes freed and the names that failed.
    static func remove(_ items: [Item]) -> (freed: UInt64, failed: [String]) {
        var freed: UInt64 = 0, failed: [String] = []
        for i in items {
            do { try FileManager.default.removeItem(atPath: i.path); freed += i.size }
            catch { failed.append((i.path as NSString).lastPathComponent) }
        }
        return (freed, failed)
    }
}
