import AppKit
import Observation

/// Shared icon cache. Icons are resolved OFF the main thread (NSWorkspace icon
/// lookups hit the disk and were causing hitches when switching views); until
/// one is ready a generic icon is shown. `version` bumps when new icons land so
/// SwiftUI views and the native tables refresh just the affected rows.
@MainActor
@Observable
final class IconCache {
    static let shared = IconCache()
    nonisolated static let didUpdate = Notification.Name("IconCacheDidUpdate")

    private(set) var version = 0
    @ObservationIgnored private var cache: [String: NSImage] = [:]
    @ObservationIgnored private var pending = Set<String>()
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private let queue = DispatchQueue(label: "taskmanager.icons", qos: .utility, autoreleaseFrequency: .workItem)

    @ObservationIgnored lazy var executable: NSImage = Self.sized(NSWorkspace.shared.icon(for: .unixExecutable))
    @ObservationIgnored lazy var generic: NSImage = Self.sized(NSWorkspace.shared.icon(for: .applicationBundle))

    func icon(forBundle path: String) -> NSImage {
        guard !path.isEmpty else { return executable }
        _ = version   // dependency so SwiftUI redraws when icons arrive
        if let i = cache[path] { return i }
        if !pending.contains(path) {
            pending.insert(path)
            queue.async { [weak self] in
                let img = Box(Self.sized(NSWorkspace.shared.icon(forFile: path)))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.store(path, img.value) }
                }
            }
        }
        return path.hasSuffix(".app") ? generic : executable
    }

    private func store(_ path: String, _ img: NSImage) {
        if cache.count > 300 { cache.removeAll(keepingCapacity: true) }
        cache[path] = img
        pending.remove(path)
        // Coalesce a burst of icon loads into one refresh.
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushScheduled = false
                self.version &+= 1
                NotificationCenter.default.post(name: Self.didUpdate, object: nil)
            }
        }
    }

    /// NSWorkspace icons carry every size up to 1024 px (several MB each).
    /// Keep one 32×32 pt (64 px @2x) bitmap instead.
    nonisolated private static func sized(_ image: NSImage) -> NSImage {
        let px = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            image.size = NSSize(width: 32, height: 32); return image
        }
        rep.size = NSSize(width: 32, height: 32)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let small = NSImage(size: NSSize(width: 32, height: 32))
        small.addRepresentation(rep)
        return small
    }

    /// Drops cached icons (they reload in the background when next shown).
    func purge() {
        cache.removeAll()
        pending.removeAll()
    }

    private final class Box: @unchecked Sendable { let value: NSImage; init(_ v: NSImage) { value = v } }
}
