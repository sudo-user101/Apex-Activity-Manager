import Foundation
import UniformTypeIdentifiers

/// Analyze › Compress in place (e.g. the Screenshots folder): photos, videos
/// and PDFs are compressed next to themselves, and only once every smaller
/// copy is safely written are the originals swapped out (to the Trash, or
/// deleted), keeping their names. Online-only files are counted up front
/// (they download first).
enum InPlaceCompressor {
    /// What can be compressed in place (Office documents are already zipped inside: they don't shrink).
    enum Kind: String, Sendable, CaseIterable, Hashable { case photo, video, pdf }
    /// One file to compress (photo, video or PDF).
    struct Photo: Sendable, Hashable {
        let url: URL; let size: UInt64; let onlineOnly: Bool
        var kind: Kind { InPlaceCompressor.kind(of: url) ?? .photo }
    }

    struct Plan: Sendable {
        var photos: [Photo] = []
        /// Folders whose contents are only online (not listed unless asked: listing asks the server).
        var unlistedFolders = 0
        /// In a cloud folder (online-only files, or folders only online).
        var isCloud: Bool { !online.isEmpty || unlistedFolders > 0 }
        var local: [Photo] { photos.filter { !$0.onlineOnly } }
        var online: [Photo] { photos.filter(\.onlineOnly) }
        var localBytes: UInt64 { local.reduce(0) { $0 + $1.size } }
        var onlineBytes: UInt64 { online.reduce(0) { $0 + $1.size } }
        func of(_ kinds: Set<Kind>) -> Plan { var p = self; p.photos = photos.filter { kinds.contains($0.kind) }; return p }
        func count(_ k: Kind) -> Int { photos.filter { $0.kind == k }.count }
        func bytes(_ k: Kind) -> UInt64 { photos.filter { $0.kind == k }.reduce(0) { $0 + $1.size } }
    }

    /// A smaller copy, written next to its original but not yet swapped in.
    struct Copy: Sendable, Hashable { let original: URL; let copy: URL; let finalURL: URL; let before: UInt64; let after: UInt64 }

    static let photoExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp"]
    /// What AVFoundation can re-encode (not AVI / MKV).
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let documentExtensions: Set<String> = ["pdf"]

    /// Photo, video, PDF, or nil for anything else. Pure: tested.
    static func kind(of url: URL) -> Kind? {
        let e = url.pathExtension.lowercased()
        return photoExtensions.contains(e) ? .photo : videoExtensions.contains(e) ? .video : documentExtensions.contains(e) ? .pdf : nil
    }

    /// The photos at `paths` (files, or folders searched one level of
    /// subfolders deep at most 10,000 files). Pure apart from reading the folder.
    /// `wholeOnlineFolder`: also go into folders whose contents are only
    /// online (macOS asks the server for each; slow, and needs the connection).
    static func plan(_ paths: [String], wholeOnlineFolder: Bool = false) -> Plan {
        var out = Plan()
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .ubiquitousItemDownloadingStatusKey, .isHiddenKey]
        func add(_ url: URL) {
            guard kind(of: url) != nil, !url.lastPathComponent.hasPrefix(".apex-") else { return }
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { return }
            out.photos.append(Photo(url: url, size: UInt64(v?.fileSize ?? 0), onlineOnly: isOnlineOnly(url, v)))
        }
        for p in paths {
            let url = URL(fileURLWithPath: p)
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &dir) else { continue }
            if !dir.boolValue { add(url); continue }
            guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let f as URL in e {
                if e.level > 2 { e.skipDescendants(); continue }
                if Dataless.folder(f.path) {
                    out.unlistedFolders += 1
                    if !wholeOnlineFolder { e.skipDescendants(); continue }       // listing it would ask the server
                }
                add(f)
                if out.photos.count >= 10_000 { break }
            }
        }
        return out
    }

    /// Not on this Mac yet (iCloud or another cloud placeholder).
    static func isOnlineOnly(_ url: URL, _ v: URLResourceValues?) -> Bool {
        if let s = v?.ubiquitousItemDownloadingStatus, s == .notDownloaded { return true }
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// Where the smaller copy ends up: same name, the new format's extension
    /// when it changes, never over another existing file. Pure: tested.
    static func finalURL(for original: URL, compressedExtension ext: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        let sameKind = original.pathExtension.lowercased() == ext.lowercased()
            || (["jpg", "jpeg"].contains(original.pathExtension.lowercased()) && ["jpg", "jpeg"].contains(ext.lowercased()))
        if sameKind { return original }
        let base = original.deletingPathExtension()
        var candidate = base.appendingPathExtension(ext)
        var n = 2
        while exists(candidate.path) { candidate = URL(fileURLWithPath: base.path + " \(n)").appendingPathExtension(ext); n += 1 }
        return candidate
    }

    /// Free space where `folder` is (what macOS would give for important use).
    static func freeSpace(at folder: URL) -> UInt64 {
        let v = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(max(0, v?.volumeAvailableCapacityForImportantUsage ?? 0))
    }

    /// Step 1: smaller copies next to each photo (`.apex-…` hidden names).
    /// Originals untouched. Copies that aren't smaller are dropped.
    static func makeCopies(_ photos: [Photo], keepDetails: Bool, progress: @escaping @Sendable (Int, Int) -> Void,
                           cancelled: @escaping @Sendable () -> Bool) async -> (copies: [Copy], skipped: [(String, String)]) {
        var copies: [Copy] = [], skipped: [(String, String)] = []
        for (i, p) in photos.enumerated() {
            if cancelled() { break }
            progress(i, photos.count)
            let dir = p.url.deletingLastPathComponent()
            let ext = MediaCompressor.compressedType(for: p.url).preferredFilenameExtension ?? p.url.pathExtension
            let tmp = dir.appendingPathComponent(".apex-\(UUID().uuidString).\(ext)")
            do {
                let r = try await MediaCompressor.compress(p.url, keepMetadata: keepDetails, output: tmp)
                let after = MediaCompressor.fileSize(r.url)
                let before = MediaCompressor.fileSize(p.url)
                guard after > 0, after < before, r.url.standardizedFileURL != p.url.standardizedFileURL else {
                    // Not smaller. Videos and PDFs then hand back the original itself: never delete that.
                    if r.url.standardizedFileURL != p.url.standardizedFileURL { try? FileManager.default.removeItem(at: r.url) }
                    try? FileManager.default.removeItem(at: tmp)
                    skipped.append((p.url.lastPathComponent, r.unchangedNote == nil ? "already as small as it gets" : "already as small as it gets (text, or already-compressed pictures)"))
                    continue
                }
                copies.append(Copy(original: p.url, copy: r.url, finalURL: finalURL(for: p.url, compressedExtension: r.url.pathExtension), before: before, after: after))
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                skipped.append((p.url.lastPathComponent, error.localizedDescription))
            }
        }
        progress(photos.count, photos.count)
        return (copies, skipped)
    }

    /// Step 2 (Done): each smaller copy takes its original's place; the
    /// original goes to the Trash, or is deleted for good (`permanently`).
    /// Never leaves a photo missing: a new name is put in place before the
    /// original goes; for the same name the original is moved aside first and
    /// put back if the swap fails. Returns what was left as it was.
    static func swapIn(_ copies: [Copy], permanently: Bool = false) -> [String] {
        let fm = FileManager.default
        func dispose(_ url: URL) throws {
            if permanently { try fm.removeItem(at: url) } else { try fm.trashItem(at: url, resultingItemURL: nil) }
        }
        var failed: [String] = []
        for c in copies {
            do {
                if c.finalURL != c.original {
                    try fm.moveItem(at: c.copy, to: c.finalURL)                 // the new file first…
                    do { try dispose(c.original) }                               // …then the old one
                    catch { try? fm.moveItem(at: c.finalURL, to: c.copy); throw error }
                } else {
                    // Same name: the original aside (hidden, beside it), the copy in, then the original goes.
                    let aside = c.original.deletingLastPathComponent().appendingPathComponent(".apex-original-\(UUID().uuidString)")
                    try fm.createDirectory(at: aside, withIntermediateDirectories: false)
                    defer { try? fm.removeItem(at: aside) }                       // empty by then (or put back)
                    let held = aside.appendingPathComponent(c.original.lastPathComponent)
                    try fm.moveItem(at: c.original, to: held)
                    do { try fm.moveItem(at: c.copy, to: c.finalURL) }
                    catch { try? fm.moveItem(at: held, to: c.original); throw error }
                    do { try dispose(held) }
                    catch { try? fm.moveItem(at: c.finalURL, to: c.copy); try? fm.moveItem(at: held, to: c.original); throw error }
                }
            } catch {
                failed.append(c.original.lastPathComponent)
            }
        }
        return failed
    }

    /// Cancel / Close without Done: the copies are removed, originals untouched.
    static func discard(_ copies: [Copy]) { for c in copies { try? FileManager.default.removeItem(at: c.copy) } }
}
