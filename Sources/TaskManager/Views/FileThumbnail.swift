import AppKit
import QuickLookThumbnailing
import SwiftUI

/// What a file or folder looks like, so a list isn't just names: an app's own
/// icon, a document's icon, and for photos, videos and PDFs stored on this Mac
/// a real thumbnail. A file that's only online keeps its type's icon (a
/// thumbnail would download it). Thumbnails are kept while Apex runs.
struct FileThumbnail: View {
    let path: String
    var size: CGFloat = 28
    @State private var image: NSImage?

    @MainActor private static let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 600; return c }()

    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: path))
            .resizable().aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: image == nil ? 0 : size * 0.12, style: .continuous))
            .task(id: path) {
                if let hit = Self.cache.object(forKey: path as NSString) { image = hit; return }
                guard Self.wantsThumbnail(path) else { return }
                let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: size, height: size),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
                if let t = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                    Self.cache.setObject(t.nsImage, forKey: path as NSString)
                    image = t.nsImage
                }
            }
    }

    /// Photos, videos and PDFs that are on this Mac (not only online). Pure apart from reading the file's details.
    static func wantsThumbnail(_ path: String) -> Bool {
        guard InPlaceCompressor.kind(of: URL(fileURLWithPath: path)) != nil else { return false }
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        let onDisk = v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0
        return onDisk > 0 || (v?.fileSize ?? 0) == 0
    }
}
