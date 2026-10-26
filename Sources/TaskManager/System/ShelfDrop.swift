import AppKit
import UniformTypeIdentifiers

/// Reads a drop onto a shelf straight from the drag pasteboard, the way the
/// leading shelf app does: files; files an app only hands over on drop
/// (Photos, Mail, Messages, a browser's pictures: "file promises"); pictures
/// with no file; web links (saved as .webloc) and text (saved as .txt).
/// Nothing fails silently: what couldn't be taken is counted, and
/// `Outcome.message` says so in plain words.
@MainActor enum ShelfDrop {
    /// What a SwiftUI drop zone accepts. `.item` too, so a drop of something
    /// a shelf can't keep still lands and is told why, instead of bouncing back.
    static let types: [UTType] = [.fileURL, .url, .image, .text, .item]

    static let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    /// What AppKit drop targets (the menu bar icons) register for.
    static let pasteboardTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .png, .tiff, .string, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)] + promiseTypes

    /// Something a shelf can keep is on the pasteboard. Pure (given the pasteboard): tested.
    static func canAccept(_ pb: NSPasteboard) -> Bool {
        guard let t = pb.types, !t.isEmpty else { return false }
        return !Set(t).isDisjoint(with: pasteboardTypes) || pb.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
    }

    /// Bumped on every drop, so the floating shelf stays up to show what happened.
    private(set) static var drops = 0

    struct Outcome: Equatable, Sendable {
        /// Ready to go on the shelf: the dropped files, or Apex's own copies of
        /// promised files, pictures, links and text.
        var files: [URL] = []
        /// Names of dropped files that aren't on the disk (moved or deleted mid-drag).
        var missing: [String] = []
        /// Names of files Apex isn't allowed to open.
        var unreadable: [String] = []
        /// Promised by the app, but never handed over (or handed over empty).
        var notDelivered = 0
        /// Nothing a shelf can keep (e.g. a custom app-only drag).
        var unsupported = false
        /// Already on the shelf (filled in by whoever adds the files).
        var duplicates = 0
        /// The app dragged from, for the message ("Photos didn't hand over…").
        var source: String? = nil

        /// What the shelf says after the drop; nil when everything went on.
        /// `added`: how many really went on the shelf. Pure: tested.
        func message(added: Int) -> String? {
            if unsupported, added == 0 { return "That can’t go on a shelf. Drop files, pictures, links or text." }
            var parts: [String] = []
            if let one = missing.first {
                parts.append(missing.count == 1 ? "“\(one)” isn’t on the disk any more." : "\(missing.count) files aren’t on the disk any more.")
            }
            if let one = unreadable.first {
                parts.append(unreadable.count == 1 ? "Apex isn’t allowed to open “\(one)”." : "Apex isn’t allowed to open \(unreadable.count) files.")
            }
            if notDelivered > 0 {
                let what = notDelivered == 1 ? "the file" : "\(notDelivered) files"
                parts.append("\(source ?? "The app") didn’t hand over \(what). Try again, or save it to a folder first.")
            }
            if duplicates > 0 {
                if parts.isEmpty, added == 0 {
                    parts.append(duplicates == 1 ? "Already on this shelf." : "All \(duplicates) are already on this shelf.")
                } else {
                    parts.append(duplicates == 1 ? "1 was already on this shelf." : "\(duplicates) were already on this shelf.")
                }
            }
            guard !parts.isEmpty else { return nil }
            if added > 0 { parts.insert("Added \(added).", at: 0) }
            return parts.joined(separator: " ")
        }
    }

    /// "Getting 3 files from Photos…", while promised files are on their way. Pure: tested.
    static func waitingMessage(_ n: Int, source: String?) -> String {
        "Getting \(n == 1 ? "the file" : "\(n) files") from \(source ?? "the app")…"
    }

    /// Reads the drop. `folder`: where Apex keeps its own files for that shelf.
    /// `done` runs on the main actor: at once, or once promised files have
    /// arrived (or after `promiseTimeout`). Returns how many promised files
    /// are still on their way (0: `done` has already run).
    @discardableResult
    static func receive(_ pb: NSPasteboard, into folder: URL, source: String? = sourceApp(),
                        done: @escaping @MainActor (Outcome) -> Void) -> Int {
        drops += 1
        var out = Outcome(source: source)
        // 1. Files (Finder, the desktop, most apps; also file links from editors).
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { check(urls, into: &out); done(out); return 0 }
        // 2. Files the app writes only when they're dropped.
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            return receive(promises, into: folder, out, done)
        }
        // 3. A picture with no file, 4. web links, 5. text.
        if let u = saveImage(pb, in: folder) {
            out.files = [u]
        } else if let links = saveLinks(pb, in: folder), !links.isEmpty {
            out.files = links
        } else if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            // A path typed or copied somewhere (e.g. Terminal): that file.
            let path = (text as NSString).expandingTildeInPath
            if !text.contains("\n"), path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
                check([URL(fileURLWithPath: path)], into: &out)
            } else if let u = save(Data(text.utf8), named: title(forText: text), ext: "txt", in: folder) {
                out.files = [u]
            } else {
                out.notDelivered = 1
            }
        } else {
            out.unsupported = true
        }
        done(out)
        return 0
    }

    /// The app the drag came from: the one in front (the shelf never takes
    /// the focus), unless that's Apex itself.
    nonisolated static func sourceApp() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app.localizedName
    }

    /// Files that are really there and readable; the rest are counted.
    static func check(_ urls: [URL], into out: inout Outcome) {
        let fm = FileManager.default
        for u in urls {
            guard fm.fileExists(atPath: u.path) else { out.missing.append(u.lastPathComponent); continue }
            guard fm.isReadableFile(atPath: u.path) else { out.unreadable.append(u.lastPathComponent); continue }
            // Only a placeholder of a cloud file (iCloud Drive, Nextcloud…): fetch it now,
            // so dragging it out later hands over the real file.
            if (try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus == .notDownloaded {
                try? fm.startDownloadingUbiquitousItem(at: u)
            }
            out.files.append(u)
        }
    }

    // MARK: Promised files

    /// Long enough for Photos to fetch a video from iCloud; after that the files still missing are reported.
    static var promiseTimeout: TimeInterval = 120

    private final class Pending {
        var out: Outcome
        var left: Int
        var finished = false
        let done: @MainActor (Outcome) -> Void
        init(_ out: Outcome, left: Int, done: @escaping @MainActor (Outcome) -> Void) { self.out = out; self.left = left; self.done = done }

        @MainActor func arrived(_ url: URL?) {
            guard !finished else {
                // More files than announced, after the rest: still put them on the shelf.
                var late = Outcome(source: out.source)
                if let url { late.files = [url] } else { late.notDelivered = 1 }
                done(late); return
            }
            if let url { out.files.append(url) } else { out.notDelivered += 1 }
            left -= 1
            if left <= 0 { finish() }
        }

        @MainActor func finish() {
            guard !finished else { return }
            finished = true
            out.notDelivered += max(0, left)
            done(out)
        }
    }

    private static func receive(_ promises: [NSFilePromiseReceiver], into folder: URL, _ start: Outcome,
                                _ done: @escaping @MainActor (Outcome) -> Void) -> Int {
        let expected = promises.reduce(0) { $0 + max(1, $1.fileNames.count) }
        // Each drop in its own folder, so two files with the same name never meet.
        let dest = folder.appendingPathComponent("Dropped \(UUID().uuidString.prefix(8))", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)) != nil else {
            var o = start; o.notDelivered = expected; done(o); return 0
        }
        let pending = Pending(start, left: expected, done: done)
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for p in promises {
            p.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: queue) { url, error in
                // An empty file is a promise the app didn't keep.
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let ok = error == nil && (v?.isDirectory == true || (v?.fileSize ?? 0) > 0)
                Task { @MainActor in pending.arrived(ok ? url : nil) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + promiseTimeout) { MainActor.assumeIsolated { pending.finish() } }
        return expected
    }

    // MARK: Pictures, links and text with no file: Apex saves them

    /// The picture's own bytes when they're a common format (nothing re-encoded), otherwise PNG.
    static func saveImage(_ pb: NSPasteboard, in folder: URL) -> URL? {
        let name = "Image \(stamp())"
        for (t, ext) in [(UTType.png, "png"), (.jpeg, "jpg"), (.heic, "heic"), (.gif, "gif")] {
            if let d = pb.data(forType: .init(t.identifier)), NSImage(data: d) != nil { return save(d, named: name, ext: ext, in: folder) }
        }
        guard pb.canReadItem(withDataConformingToTypes: [UTType.image.identifier]),
              let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return save(png, named: name, ext: "png", in: folder)
    }

    /// Web links as .webloc files (double-click opens the page), named after
    /// the page title the browser gave, or the site.
    static func saveLinks(_ pb: NSPasteboard, in folder: URL) -> [URL]? {
        var out: [URL] = []
        for item in pb.pasteboardItems ?? [] {
            let raw = item.string(forType: .URL) ?? item.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto", "ftp"].contains(scheme) else { continue }
            let title = item.string(forType: .init("public.url-name")) ?? url.host ?? "Link"
            let plist = ["URL": url.absoluteString]
            guard let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                  let u = save(d, named: title, ext: "webloc", in: folder) else { continue }
            out.append(u)
        }
        return out
    }

    /// A file name from the text's first line ("Meeting notes for Monday"), or "Text <date>". Pure: tested.
    nonisolated static func title(forText text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = first.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return "Text \(stamp())" }
        return clean.count > 40 ? String(clean.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : clean
    }

    nonisolated static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    /// Writes into the shelf's folder under a free name ("Link", "Link 2"…).
    static func save(_ data: Data, named base: String, ext: String, in folder: URL) -> URL? {
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let url = freeName(safeName(base), ext: ext, in: folder)
        return (try? data.write(to: url, options: .withoutOverwriting)) != nil ? url : nil
    }

    /// No "/" or ":" (not allowed in a Mac file name), no leading ".", not too long. Pure: tested.
    nonisolated static func safeName(_ s: String) -> String {
        var n = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while n.hasPrefix(".") { n.removeFirst() }
        if n.utf8.count > 200 { n = String(n.prefix(100)) }
        return n.isEmpty ? "Dropped" : n
    }

    nonisolated static func freeName(_ base: String, ext: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext); n += 1
        }
        return url
    }
}
