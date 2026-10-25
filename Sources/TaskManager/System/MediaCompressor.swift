import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Compress and convert files on the shelf: images and videos re-encoded,
/// PDFs slimmed, anything else (documents, folders, apps) zipped. The original
/// is never changed: results are saved next to it ("Name (compressed).heic"),
/// or in Downloads when that folder can't be written.
enum MediaCompressor {
    enum Kind { case image, video, pdf, other }

    struct Result: Sendable {
        let url: URL
        let before: UInt64
        let after: UInt64
        var unchangedNote: String? = nil     // why nothing smaller was made, when it wasn't
        var saved: Double { before > 0 ? 1 - Double(after) / Double(before) : 0 }
        var summary: String {
            let pct = Int((saved * 100).rounded())
            let sizes = "\(Fmt.diskBytes(before)) → \(Fmt.diskBytes(after))"
            if url.pathExtension == "zip" {
                return pct > 0 ? "Saved \(url.lastPathComponent), \(pct)% smaller (\(sizes))."
                               : "Saved \(url.lastPathComponent) (\(sizes)). What's inside was already compressed."
            }
            if pct >= 50 { return "\(pct)% smaller (\(sizes))" }
            if pct > 0 { return "\(pct)% smaller (\(sizes)). It was already well compressed." }
            return unchangedNote ?? "Already as small as it gets without losing quality (\(Fmt.diskBytes(before)))."
        }
    }

    static func kind(_ url: URL) -> Kind {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        return .other
    }

    static let target = 0.5   // aim for at least 50 % smaller

    /// The shelf's right-click wording for each kind of file.
    static func compressTitle(_ kind: Kind) -> String {
        switch kind {
        case .image, .video: return "Compress…"            // asks about photo / video details first
        case .pdf: return "Compress PDF"
        case .other: return "Compress to ZIP"
        }
    }

    /// Compresses whatever the file is: the one entry point the shelf uses.
    static func compress(_ url: URL, keepMetadata: Bool, output: URL) async throws -> Result {
        switch kind(url) {
        case .video: return try await compressVideo(url, keepMetadata: keepMetadata, output: output)
        case .image: return try await Task.detached(priority: .userInitiated) { try compressImage(url, keepMetadata: keepMetadata, output: output) }.value
        case .pdf: return try await Task.detached(priority: .userInitiated) { try compressPDF(url, output: output) }.value
        case .other: return try await Task.detached(priority: .userInitiated) { try zip(url, output: output) }.value
        }
    }

    // MARK: Images

    /// Format a compressed image is saved in: JPEG stays JPEG, everything else
    /// (PNG screenshots, TIFF, HEIC) becomes HEIC, which keeps transparency.
    static func compressedType(for url: URL) -> UTType {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg"].contains(ext) ? .jpeg : .heic
    }

    /// Steps tried in order until the file is at least 50 % smaller:
    /// (quality, scale). Resolution only drops at the very end, and only a little.
    static let imageSteps: [(Double, Double)] = [(0.8, 1), (0.7, 1), (0.6, 1), (0.6, 0.85)]

    static func compressImage(_ url: URL, keepMetadata: Bool, output: URL) throws -> Result {
        let before = fileSize(url)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw err("Couldn’t read the image.") }
        let type = compressedType(for: url)
        var best: Data?
        // Small files never lose resolution: there's little space to gain.
        let steps = before < 512 * 1024 ? imageSteps.filter { $0.1 == 1 } : imageSteps
        for (q, scale) in steps {
            guard let d = encode(src, as: type, quality: q, scale: scale, keepMetadata: keepMetadata) else { continue }
            if best == nil || d.count < best!.count { best = d }
            if Double(d.count) <= Double(before) * (1 - target) { break }
        }
        guard let data = best else { throw err("This image format can’t be compressed here.") }
        // Never hand back something bigger than the original.
        guard UInt64(data.count) < before else { return Result(url: url, before: before, after: before) }
        // Keep the file's own spelling (".jpg" stays ".jpg").
        let same = UTType(filenameExtension: url.pathExtension.lowercased()) == type
        let out = output.deletingPathExtension().appendingPathExtension(same ? url.pathExtension : (type.preferredFilenameExtension ?? "heic"))
        try data.write(to: out, options: .atomic)
        return Result(url: out, before: before, after: UInt64(data.count))
    }

    static func encode(_ src: CGImageSource, as type: UTType, quality: Double, scale: Double, keepMetadata: Bool) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        if scale < 1 {
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            let thumb: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceThumbnailMaxPixelSize: Int(Double(max(w, h)) * scale)]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, thumb as CFDictionary) else { return nil }
            if keepMetadata {
                var p = props; p[kCGImagePropertyOrientation] = 1      // the transform is already applied
                p[kCGImagePropertyPixelWidth] = img.width; p[kCGImagePropertyPixelHeight] = img.height
                opts.merge(p) { a, _ in a }
            }
            CGImageDestinationAddImage(dest, img, opts as CFDictionary)
        } else if keepMetadata {
            CGImageDestinationAddImageFromSource(dest, src, 0, opts as CFDictionary)
        } else {
            guard let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            // Only the orientation survives, so the picture still shows the right way up.
            if let o = props[kCGImagePropertyOrientation] { opts[kCGImagePropertyOrientation] = o }
            CGImageDestinationAddImage(dest, img, opts as CFDictionary)
        }
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Converts an image to another format (best quality, metadata kept).
    static func convertImage(_ url: URL, to type: UTType, output: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let data = encode(src, as: type, quality: 0.92, scale: 1, keepMetadata: true) else {
            throw err("Couldn’t convert to \(type.localizedDescription ?? "that format").")
        }
        let out = output.deletingPathExtension().appendingPathExtension(type.preferredFilenameExtension ?? "img")
        try data.write(to: out, options: .atomic)
        return out
    }

    static let imageFormats: [(String, UTType)] = [("JPEG", .jpeg), ("PNG", .png), ("HEIC", .heic), ("TIFF", .tiff)]

    // MARK: Videos

    /// HEVC at the highest quality; if that isn't 50 % smaller and the video is
    /// bigger than 1080p, a 1080p HEVC version.
    static func compressVideo(_ url: URL, keepMetadata: Bool, output: URL) async throws -> Result {
        let before = fileSize(url)
        let asset = AVURLAsset(url: url)
        let out = output.deletingPathExtension().appendingPathExtension("mov")
        try await export(asset, preset: AVAssetExportPresetHEVCHighestQuality, type: .mov, to: out, keepMetadata: keepMetadata)
        var after = fileSize(out)
        if Double(after) > Double(before) * (1 - target),
           let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), max(abs(size.width), abs(size.height)) > 1920 {
            let smaller = output.deletingPathExtension().appendingPathExtension("1080p.mov")
            try await export(asset, preset: AVAssetExportPresetHEVC1920x1080, type: .mov, to: smaller, keepMetadata: keepMetadata)
            let s = fileSize(smaller)
            if s < after { try? FileManager.default.removeItem(at: out); try FileManager.default.moveItem(at: smaller, to: out); after = s }
            else { try? FileManager.default.removeItem(at: smaller) }
        }
        guard after < before else {
            try? FileManager.default.removeItem(at: out)
            return Result(url: url, before: before, after: before)
        }
        return Result(url: out, before: before, after: after)
    }

    static let videoFormats: [(String, String, AVFileType)] = [
        ("MP4 (H.264, plays everywhere)", AVAssetExportPresetHighestQuality, .mp4),
        ("MOV (HEVC, smaller)", AVAssetExportPresetHEVCHighestQuality, .mov),
    ]

    static func convertVideo(_ url: URL, preset: String, type: AVFileType, output: URL) async throws -> URL {
        let ext = type == .mp4 ? "mp4" : "mov"
        let out = output.deletingPathExtension().appendingPathExtension(ext)
        try await export(AVURLAsset(url: url), preset: preset, type: type, to: out, keepMetadata: true)
        return out
    }

    private static func export(_ asset: AVURLAsset, preset: String, type: AVFileType, to out: URL, keepMetadata: Bool) async throws {
        try? FileManager.default.removeItem(at: out)
        guard let s = AVAssetExportSession(asset: asset, presetName: preset) else { throw err("This video can’t be converted here.") }
        s.outputURL = out
        s.outputFileType = type
        s.shouldOptimizeForNetworkUse = true
        if keepMetadata {
            s.metadata = (try? await asset.load(.metadata)) ?? []
        } else {
            s.metadata = []
            s.metadataItemFilter = .forSharing()      // drops location and device details
        }
        await s.export()
        if s.status != .completed { throw err(s.error?.localizedDescription ?? "The video couldn’t be exported.") }
    }

    // MARK: PDFs

    /// Pictures inside the PDF re-saved as JPEG at screen resolution; text and
    /// drawings stay sharp. Kept only if it came out smaller.
    static func compressPDF(_ url: URL, output: URL) throws -> Result {
        let before = fileSize(url)
        guard let doc = PDFDocument(url: url) else { throw err("Couldn’t read the PDF.") }
        if doc.isLocked { throw err("This PDF is password-protected. Open it once to unlock it, then try again.") }
        let out = output.deletingPathExtension().appendingPathExtension("pdf")
        guard doc.write(to: out, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) else {
            throw err("Couldn’t save the smaller PDF.")
        }
        let after = fileSize(out)
        guard after > 0, after < before else {
            try? FileManager.default.removeItem(at: out)
            return Result(url: url, before: before, after: before,
                          unchangedNote: "This PDF is already as small as it gets (\(Fmt.diskBytes(before))): it’s text, or its pictures are already compressed. Nothing was changed.")
        }
        return Result(url: out, before: before, after: after)
    }

    // MARK: Anything else: ZIP

    /// A .zip next to it, the same as Finder's Compress (folders and apps too).
    static func zip(_ url: URL, output: URL) throws -> Result {
        let before = itemSize(url)
        let out = output.deletingPathExtension().appendingPathExtension("zip")
        let r = Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, out.path])
        guard r.status == 0, FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: out)
            throw err("Couldn’t make the ZIP" + (r.stderr.isEmpty ? "." : ": " + r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return Result(url: out, before: before, after: fileSize(out))
    }

    /// A file's size, or everything inside a folder / app.
    static func itemSize(_ url: URL) -> UInt64 {
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue else { return fileSize(url) }
        var total: UInt64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: { _, _ in true })
        while let u = e?.nextObject() as? URL { total += fileSize(u) }
        return total
    }

    // MARK: Helpers

    /// "Photo.png" → "Photo (compressed)" next to it, or in `fallback` when
    /// that folder isn't writable; never overwrites an existing file.
    static func outputURL(for url: URL, suffix: String, fallback: URL) -> URL {
        let dir = FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) ? url.deletingLastPathComponent() : fallback
        let base = url.deletingPathExtension().lastPathComponent + " (\(suffix))"
        var candidate = dir.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension))
                || (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.contains(where: { $0.hasPrefix(candidate.lastPathComponent + ".") }) == true {
            candidate = dir.appendingPathComponent(base + " \(n)"); n += 1
        }
        return url.pathExtension.isEmpty ? candidate : candidate.appendingPathExtension(url.pathExtension)
    }

    static func fileSize(_ url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "Apex", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}
