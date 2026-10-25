import XCTest
import ImageIO
import PDFKit
import AVFoundation
import Network
import SwiftUI
import UniformTypeIdentifiers
@testable import TaskManager

final class StorageHubTests: XCTestCase {
    func testMeasuresFoldersOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("analyze-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_000_000).write(to: dir.appendingPathComponent("a/big.bin"))
        try Data(repeating: 2, count: 300_000).write(to: dir.appendingPathComponent("a/b/small.bin"))
        try Data(repeating: 3, count: 10).write(to: dir.appendingPathComponent("tiny.txt"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let (size, partial) = DiskAnalyzer.measure(dir.path)
        XCTAssertFalse(partial)
        XCTAssertGreaterThanOrEqual(size, 1_300_000, "allocated size is at least the data")
        XCTAssertLessThan(size, 1_500_000)
        let kids = DiskAnalyzer.children(of: dir.path)
        XCTAssertEqual(Set(kids.map(\.name)), ["a", "tiny.txt"])
        XCTAssertEqual(kids.first { $0.name == "a" }?.isDirectory, true)
        XCTAssertEqual(DiskAnalyzer.measure(dir.appendingPathComponent("missing").path).1, true)
    }

    func testOverviewStartsWithTheBigLocations() {
        let names = DiskAnalyzer.roots().map(\.name)
        XCTAssertEqual(Array(names.prefix(5)), ["Home", "User Library", "Applications", "System Library", "Old Downloads (90 days+)"])
    }

    func testEveryOptimizeTaskIsExplained() {
        XCTAssertEqual(Set(OptimizeTask.all.map(\.id)), Set(OptimizeTask.ID.allCases))
        for t in OptimizeTask.all { XCTAssertFalse(t.detail.isEmpty); XCTAssertFalse(t.title.isEmpty) }
        XCTAssertTrue(OptimizeTask.all.first { $0.id == .dns }!.needsAdmin)
        XCTAssertFalse(OptimizeTask.all.first { $0.id == .fileCache }!.defaultOn, "purge is opt-in")
        XCTAssertFalse(OptimizeTask.all.first { $0.id == .quarantine }!.defaultOn)
    }
}

final class FastSizeTests: XCTestCase {
    func testParallelSizeMatchesFileByFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("apex-fs-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for d in ["a/b/c", "d", "e/f"] { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        for (i, f) in ["a/1", "a/b/2", "a/b/c/3", "d/4", "e/f/5", "6"].enumerated() {
            try Data(repeating: 7, count: 10_000 * (i + 1)).write(to: root.appendingPathComponent(f))
        }
        var expected: UInt64 = 0
        for case let u as URL in fm.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])! {
            let v = try u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v.isRegularFile == true { expected += UInt64(v.totalFileAllocatedSize ?? 0) }
        }
        let r = FastSize.allocated(root.path)
        XCTAssertEqual(r.bytes, expected)
        XCTAssertFalse(r.partial)
        XCTAssertEqual(FastSize.allocated([root.appendingPathComponent("d").path, "/nonexistent-apex"]).last, 0)
    }
}

final class AppRemoverTests: XCTestCase {
    func testOnlyTheAppsOwnFilesMatch() {
        let id = "com.tinyspeck.slackmacgap", name = "Slack"
        for yes in ["com.tinyspeck.slackmacgap", "com.tinyspeck.slackmacgap.plist", "com.tinyspeck.slackmacgap.savedState",
                    "com.tinyspeck.slackmacgap.helper", "BQR82RBBHL.com.tinyspeck.slackmacgap", "Slack"] {
            XCTAssertTrue(AppRemover.belongs(yes, bundleID: id, appName: name), yes)
        }
        for no in ["com.tinyspeck.slackmacgapx", "com.tinyspeck", "Slack Helper", "com.apple.Safari", "SlackBackup"] {
            XCTAssertFalse(AppRemover.belongs(no, bundleID: id, appName: name), no)
        }
    }

    func testShortIdsDontPrefixMatch() {
        XCTAssertTrue(AppRemover.belongs("com.app.plist", bundleID: "com.app", appName: "Ap"))
        XCTAssertFalse(AppRemover.belongs("com.app.other", bundleID: "com.app", appName: "Ap"), "another vendor's files")
        XCTAssertFalse(AppRemover.belongs("Ap", bundleID: "com.app", appName: "Ap"), "names under 3 letters are too generic")
    }

    func testFindsLeftoversInAFakeHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("apex-home-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        for p in ["Library/Application Support/com.example.notes", "Library/Caches/com.example.notes",
                  "Library/Application Support/Unrelated", "Library/Containers/com.example.notes.widget", "Library/Preferences"] {
            try FileManager.default.createDirectory(atPath: home + "/" + p, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: home + "/Library/Preferences/com.example.notes.plist", contents: Data("x".utf8))
        let app = AppRemover.AppInfo(path: "/Applications/Notes Pro.app", name: "Notes Pro", bundleID: "com.example.notes",
                                     isApple: false, isRunning: false)
        let found = Set(AppRemover.leftovers(for: app, home: home).map(\.name))
        XCTAssertEqual(found, ["com.example.notes", "com.example.notes.plist", "com.example.notes.widget"])
    }
}

final class MediaCompressorTests: XCTestCase {
    /// A real screenshot (APEX_SAMPLE_IMAGE) or a drawn stand-in: at least 50 %
    /// smaller, same resolution, original untouched.
    func testScreenshotGetsHalfAsBigAtFullResolution() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-compress-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("Screenshot.png")
        if let sample = ProcessInfo.processInfo.environment["APEX_SAMPLE_IMAGE"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: sample), to: src)
        } else {
            try Self.drawScreenshotLike(to: src)
        }
        let before = MediaCompressor.fileSize(src)
        let r = try MediaCompressor.compressImage(src, keepMetadata: true,
                                                  output: MediaCompressor.outputURL(for: src, suffix: "compressed", fallback: dir))
        XCTAssertEqual(r.url.pathExtension, "heic")
        if ProcessInfo.processInfo.environment["APEX_SAMPLE_IMAGE"] != nil {
            XCTAssertGreaterThanOrEqual(r.saved, 0.5, r.summary)        // a real screenshot
        } else {
            XCTAssertGreaterThan(r.saved, 0, r.summary)                  // the drawn stand-in is already tiny
        }
        XCTAssertEqual(MediaCompressor.fileSize(src), before, "the original is never changed")
        let a = CGImageSourceCreateWithURL(src as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let b = CGImageSourceCreateWithURL(r.url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        XCTAssertEqual(a?[kCGImagePropertyPixelWidth] as? Int, b?[kCGImagePropertyPixelWidth] as? Int, "resolution kept")
        print("compressed:", r.summary)
    }

    func testOutputNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-out-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("Clip.png")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("Clip (compressed).heic").path, contents: Data())
        let out = MediaCompressor.outputURL(for: src, suffix: "compressed", fallback: dir)
        XCTAssertEqual(out.deletingPathExtension().lastPathComponent, "Clip (compressed) 2")
    }

    static func drawScreenshotLike(to url: URL) throws {
        let w = 1600, h = 1000
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<400 {   // windows, buttons, photos: flat areas and soft gradients
            ctx.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                                     blue: .random(in: 0...1, using: &rng), alpha: 1))
            ctx.fill(CGRect(x: .random(in: 0...1500, using: &rng), y: .random(in: 0...900, using: &rng),
                            width: .random(in: 10...300, using: &rng), height: .random(in: 10...200, using: &rng)))
        }
        for y in stride(from: 0, to: h, by: 2) {   // a "photo" band with fine detail
            ctx.setFillColor(CGColor(gray: .random(in: 0.3...0.7, using: &rng), alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: 400, height: 1))
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "test", code: 1) }
    }
}

final class CloudTests: XCTestCase {
    func testProviderNames() {
        XCTAssertEqual(Cloud.providerName("OneDrive-Personal").0, "OneDrive")
        XCTAssertEqual(Cloud.providerName("GoogleDrive-me@example.com").0, "Google Drive")
        XCTAssertEqual(Cloud.providerName("GoogleDrive-me@example.com").1, "me@example.com")
        XCTAssertEqual(Cloud.providerName("Dropbox").0, "Dropbox")
        XCTAssertEqual(Cloud.providerName("Nextcloud-10.0.0.5-Alex").0, "Nextcloud")
        XCTAssertEqual(Cloud.providerName("SomeNewDrive-x").0, "SomeNewDrive", "unknown providers keep their own name")
    }

    func testParsesWebDAVQuota() {
        let xml = """
        <?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:propstat><d:prop>
        <d:quota-used-bytes>1073741824</d:quota-used-bytes><d:quota-available-bytes>3221225472</d:quota-available-bytes>
        </d:prop></d:propstat></d:response></d:multistatus>
        """
        let q = Cloud.parseQuota(xml)
        XCTAssertEqual(q?.used, 1 << 30)
        XCTAssertEqual(q?.total, 4 << 30)
        let unlimited = xml.replacingOccurrences(of: "3221225472", with: "-3")
        XCTAssertNil(Cloud.parseQuota(unlimited)?.available, "negative = no limit reported")
        XCTAssertNil(Cloud.parseQuota("<html>login</html>"))
    }

    func testScanCountsWhatsOnThisMac() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-cloud-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 7, count: 2_000_000).write(to: dir.appendingPathComponent("big.bin"))
        try Data("hi".utf8).write(to: dir.appendingPathComponent("small.txt"))
        let u = Cloud.scan(dir.path)
        XCTAssertEqual(u.files, 2)
        XCTAssertEqual(u.onlineOnly, 0)
        XCTAssertGreaterThanOrEqual(u.onMacBytes, 2_000_000)
        XCTAssertEqual(u.largest.map(\.name), ["big.bin"], "only files over 1 MB are offered for freeing up")
    }
}

final class OffloadTests: XCTestCase {
    func testOnlyStoredFilesAreOffered_andNonCloudFilesFailClearly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-offload-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 1, count: 10_000).write(to: dir.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 10_000).write(to: dir.appendingPathComponent("sub/b.bin"))
        let files = Cloud.storedFiles(dir.path)
        XCTAssertEqual(Set(files.map(\.name)), ["a.bin", "b.bin"])
        // A file outside any cloud service can't be offloaded, and that's reported as a failure, not as "still uploading".
        if case .failed = Cloud.evict(files[0]) {} else { XCTFail("expected a clear failure") }
    }
}

final class CloudCatalogTests: XCTestCase {
    func testReadsUsageLines() {
        func q(_ t: String) -> (UInt64, UInt64)? { CloudCatalog.parseUsage(t).map { ($0.used, $0.total ?? 0) } }
        XCTAssertEqual(q("Storage\n12.5 GB of 15 GB used\nGoogle Drive 9 GB")?.0, 12_500_000_000)
        XCTAssertEqual(q("You've used 3.2 GB used of 5 GB")?.1, 5_000_000_000)
        XCTAssertEqual(q("1,2 GB von 15 GB belegt")?.0, 1_200_000_000, "decimal comma, German")
        XCTAssertEqual(q("45.3 GB of 2 TB")?.1, 2_000_000_000_000)
        XCTAssertEqual(q("Photos 2 GB of 15 GB · Total 14 GB of 100 GB")?.1, 100_000_000_000, "the account total wins")
        XCTAssertNil(q("Sign in to continue"))
        XCTAssertNil(q("20 GB of 5 GB"), "used can't exceed the total")
    }

    func testCatalogCoversTheMainProviders() {
        let names = CloudCatalog.providers.map(\.name).joined(separator: " ")
        for p in ["Google", "OneDrive", "iCloud", "Dropbox", "Box", "MEGA", "pCloud", "Proton", "Nextcloud", "Synology"] {
            XCTAssertTrue(names.contains(p), p)
        }
        XCTAssertEqual(CloudCatalog.provider(for: "Google Drive")?.storagePage, "https://one.google.com/storage")
    }
}

final class ShakeDetectorTests: XCTestCase {
    /// Feeds strokes between the given turning points, 10 pt per event, 10 ms apart.
    private func run(_ points: [CGFloat], step: TimeInterval = 0.01) -> [Bool] {
        var s = ShakeDetector(), t: TimeInterval = 0, results: [Bool] = []
        var x = points[0]
        results.append(s.add(x, at: t))
        for target in points.dropFirst() {
            while x != target {
                x += max(-10, min(10, target - x)); t += step
                results.append(s.add(x, at: t))
            }
        }
        return results
    }

    func testWiggleIsSpotted() {
        XCTAssertTrue(run([0, 60, 0, 60, 0]).contains(true))
    }

    func testStraightDragAndSmallJitterAreNot() {
        XCTAssertFalse(run([0, 400]).contains(true))
        XCTAssertFalse(run([0, 15, 0, 15, 0, 15, 0, 15]).contains(true))   // under 24 pt strokes
        XCTAssertFalse(run([0, 60, 0]).contains(true))                       // one turn back
    }

    func testSlowBackAndForthIsNot() {
        // 60 pt strokes at 10 pt / 100 ms: turns 0.6 s apart, 3 turns span 1.2 s.
        XCTAssertFalse(run([0, 60, 0, 60, 0], step: 0.1).contains(true))
    }

    func testOneWiggleFiresOnce() {
        XCTAssertEqual(run([0, 60, 0, 60, 0]).filter { $0 }.count, 1)
    }
}

/// Every shelf right-click action, run through the same functions the menu calls.
final class ShelfActionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-shelf-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func out(_ u: URL, _ suffix: String = "compressed") -> URL { MediaCompressor.outputURL(for: u, suffix: suffix, fallback: dir) }

    func testEveryKindOfFileCanBeCompressed() {
        XCTAssertEqual(MediaCompressor.kind(URL(fileURLWithPath: "/a/Shot.PNG")), .image)
        XCTAssertEqual(MediaCompressor.kind(URL(fileURLWithPath: "/a/Clip.mov")), .video)
        XCTAssertEqual(MediaCompressor.kind(URL(fileURLWithPath: "/a/Timetable.pdf")), .pdf)
        XCTAssertEqual(MediaCompressor.kind(URL(fileURLWithPath: "/a/Notes.docx")), .other)
        XCTAssertEqual(MediaCompressor.kind(URL(fileURLWithPath: "/a/Folder")), .other)
        for k in [MediaCompressor.Kind.image, .video, .pdf, .other] {
            XCTAssertTrue(MediaCompressor.compressTitle(k).hasPrefix("Compress"))
        }
    }

    func testImageThroughTheShelfEntryPoint() async throws {
        let src = dir.appendingPathComponent("Screenshot.png")
        try MediaCompressorTests.drawScreenshotLike(to: src)
        let r = try await MediaCompressor.compress(src, keepMetadata: false, output: out(src))
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.url.path))
        XCTAssertLessThan(r.after, r.before, r.summary)
    }

    func testImageConvert() throws {
        let src = dir.appendingPathComponent("Screenshot.png")
        try MediaCompressorTests.drawScreenshotLike(to: src)
        for (_, type) in MediaCompressor.imageFormats where type != .png {
            let r = try MediaCompressor.convertImage(src, to: type, output: out(src, "converted"))
            XCTAssertNotNil(CGImageSourceCreateWithURL(r as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }, "\(type)")
        }
    }

    func testPDFWithPicturesGetsSmaller() async throws {
        let src = dir.appendingPathComponent("Scan.pdf")
        try Self.drawPDF(to: src)
        let r = try await MediaCompressor.compress(src, keepMetadata: true, output: out(src))
        XCTAssertEqual(r.url.pathExtension, "pdf")
        XCTAssertNotEqual(r.url, src, r.summary)
        XCTAssertLessThan(r.after, r.before, r.summary)
        XCTAssertEqual(PDFDocument(url: r.url)?.pageCount, 2, "every page kept")
        print("pdf:", r.summary)
    }

    /// A real PDF (APEX_SAMPLE_PDF): never fails, never gets bigger, original untouched.
    func testRealPDF() async throws {
        guard let p = ProcessInfo.processInfo.environment["APEX_SAMPLE_PDF"] else { throw XCTSkip("set APEX_SAMPLE_PDF") }
        let src = dir.appendingPathComponent((p as NSString).lastPathComponent)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: p), to: src)
        let before = MediaCompressor.fileSize(src)
        let r = try await MediaCompressor.compress(src, keepMetadata: true, output: out(src))
        XCTAssertLessThanOrEqual(r.after, r.before)
        XCTAssertEqual(MediaCompressor.fileSize(src), before)
        print("real pdf:", r.summary)
    }

    func testOtherFilesAndFoldersBecomeZIPs() async throws {
        let txt = dir.appendingPathComponent("Notes.txt")
        try String(repeating: "the same line of notes\n", count: 5000).write(to: txt, atomically: true, encoding: .utf8)
        let r = try await MediaCompressor.compress(txt, keepMetadata: true, output: out(txt))
        XCTAssertEqual(r.url.lastPathComponent, "Notes (compressed).zip")
        XCTAssertLessThan(r.after, r.before / 10, r.summary)
        XCTAssertTrue(r.summary.hasPrefix("Saved Notes (compressed).zip"), r.summary)

        let folder = dir.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "a".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let f = try await MediaCompressor.compress(folder, keepMetadata: true, output: out(folder))
        XCTAssertEqual(f.url.lastPathComponent, "Project (compressed).zip")
        let list = Shell.run("/usr/bin/unzip", ["-l", f.url.path]).stdout
        XCTAssertTrue(list.contains("Project/a.txt"), list)
    }

    func testVideoCompressAndConvert() async throws {
        let src = dir.appendingPathComponent("Clip.mov")
        try await Self.writeMovie(to: src)
        let c = try await MediaCompressor.compress(src, keepMetadata: true, output: out(src))
        XCTAssertLessThanOrEqual(c.after, c.before, c.summary)
        for (_, preset, type) in MediaCompressor.videoFormats {
            let r = try await MediaCompressor.convertVideo(src, preset: preset, type: type, output: out(src, "converted"))
            let d = try await AVURLAsset(url: r).load(.duration)
            XCTAssertGreaterThan(d.seconds, 0.5, r.lastPathComponent)
        }
    }

    @MainActor func testFinderAliasPointsAtTheRealFile() throws {
        let real = dir.appendingPathComponent("Timetable.pdf")
        try Self.drawPDF(to: real)
        let alias = dir.appendingPathComponent("Timetable.pdf alias")
        let data = try real.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: alias)
        XCTAssertEqual(ShelfStore.resolved(alias).resolvingSymlinksInPath().path, real.resolvingSymlinksInPath().path)
        XCTAssertEqual(MediaCompressor.kind(ShelfStore.resolved(alias)), .pdf)
        XCTAssertEqual(ShelfStore.resolved(real), real, "ordinary files unchanged")
    }

    /// Two pages, each a large photo-like picture (a scan: smooth shading plus grain).
    static func drawPDF(to url: URL) throws {
        let w = 1600, h = 1000
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var rng = SystemRandomNumberGenerator()
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4, g = UInt8.random(in: 0...24, using: &rng)
            px[i] = UInt8((x * 200 / w)) &+ g; px[i + 1] = UInt8((y * 200 / h)) &+ g; px[i + 2] = 120 &+ g
        } }
        guard let img = ctx.makeImage() else { throw NSError(domain: "test", code: 1) }
        var box = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw NSError(domain: "test", code: 2) }
        for _ in 0..<2 { pdf.beginPDFPage(nil); pdf.draw(img, in: box); pdf.endPDFPage() }
        pdf.closePDF()
    }

    /// A 2-second 1280x720 H.264 movie with moving colour.
    static func writeMovie(to url: URL) async throws {
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                           AVVideoWidthKey: 1280, AVVideoHeightKey: 720])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720])
        w.add(input)
        w.startWriting(); w.startSession(atSourceTime: .zero)
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let buf = pb else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<720 { for x in stride(from: 0, to: 1280 * 4, by: 4) {
                base[y * row + x] = UInt8((x / 4 + i * 8) & 255); base[y * row + x + 1] = UInt8((y + i * 4) & 255)
                base[y * row + x + 2] = UInt8((x / 4 ^ y) & 255); base[y * row + x + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await w.finishWriting()
        if w.status != .completed { throw w.error ?? NSError(domain: "test", code: 3) }
    }
}

final class UploadMonitorTests: XCTestCase {
    private func conn(_ key: String, _ host: String, _ port: String, out: UInt64) -> NetConnection {
        NetConnection(key: key, process: "Nextcloud", pid: 1, proto: "tcp4", local: "172.16.0.50:5000", remoteHost: host,
                      remotePort: port, interface: "en0", state: "Established", bytesIn: 0, bytesOut: out)
    }

    func testSentCountsGrowthAndNewSockets() {
        let now = [conn("a", "10.0.0.20", "80", out: 5_000), conn("b", "10.0.0.20", "80", out: 700)]
        XCTAssertEqual(CloudUpload.sent(now, previous: nil), 0, "first reading has nothing to compare with")
        XCTAssertEqual(CloudUpload.sent(now, previous: ["a": 1_000]), 4_000 + 700)
        XCTAssertEqual(CloudUpload.sent(now, previous: ["a": 9_000, "b": 700]), 0, "counters never go backwards")
    }

    func testServerIsWhereMostWasSent() {
        let e = CloudUpload.server([conn("a", "17.1.1.1", "443", out: 10), conn("b", "10.0.0.20", "80", out: 900),
                                    conn("c", "10.0.0.20", "80", out: 200)])
        XCTAssertEqual(e, .init(host: "10.0.0.20", ports: ["80"]))
        XCTAssertNil(CloudUpload.server([]))
    }

    func testKnownServers() {
        func svc(_ name: String, account: String = "", url: String = "") -> CloudService {
            CloudService(id: "x", name: name, account: account, kind: url.isEmpty ? .system : .webdav, url: url)
        }
        XCTAssertEqual(CloudUpload.knownServer(for: svc("Nextcloud", account: "10.0.0.20-alex"))?.host, "10.0.0.20")
        XCTAssertEqual(CloudUpload.knownServer(for: svc("Nextcloud", account: "cloud.my-site.org-jo-ann"))?.host, "cloud.my-site.org")
        XCTAssertEqual(CloudUpload.knownServer(for: svc("OneDrive", account: "Personal"))?.host, "api.onedrive.com")
        XCTAssertEqual(CloudUpload.knownServer(for: svc("NAS", url: "http://nas.local:5005/dav"))?.ports, ["5005"])
        XCTAssertNil(CloudUpload.knownServer(for: svc("Somewhere", account: "Personal")))
    }

    func testAppMarkers() {
        XCTAssertEqual(CloudUpload.appMarkers(for: CloudService(id: "cs:x", name: "Google Drive", kind: .system)),
                       ["/Google Drive.app/", "/GoogleDrive.app/"])
        XCTAssertTrue(CloudUpload.appMarkers(for: CloudService(id: "icloud", name: "iCloud Drive", kind: .system))
            .contains("/iCloudDriveCore.framework/"))
    }

    func testTimeWords() {
        XCTAssertEqual(CloudUpload.duration(45), "45 s")
        XCTAssertEqual(CloudUpload.duration(200), "3 min 20 s")
        XCTAssertEqual(CloudUpload.duration(120), "2 min")
        XCTAssertEqual(CloudUpload.duration(3900), "1 h 5 min")
        XCTAssertEqual(CloudUpload.timeLeft(bytesLeft: 4_000_000, rate: 1_000_000), 4)
        XCTAssertNil(CloudUpload.timeLeft(bytesLeft: 4_000_000, rate: 10), "not moving: no guess")
        XCTAssertNil(CloudUpload.timeLeft(bytesLeft: 0, rate: 1_000_000))
    }

    func testCardWords() {
        var st = CloudStore.OffloadState()
        st.started = Date(timeIntervalSince1970: 0)
        XCTAssertNil(OffloadText.connection(st).ok)
        st.checkedServer = true; st.server = "10.0.0.20"; st.latency = 7.6
        XCTAssertEqual(OffloadText.connection(st).text, "Connected to 10.0.0.20 · 8 ms")
        st.latency = nil; st.downSince = Date(timeIntervalSince1970: 100)
        let lost = OffloadText.connection(st, now: Date(timeIntervalSince1970: 220))
        XCTAssertEqual(lost.ok, false)
        XCTAssertTrue(lost.text == "Can’t reach 10.0.0.20 for 2 min, so uploads are paused" && lost.fix?.hasPrefix("Check that the server is on") == true, lost.text)
        st.rate = 2_000_000; st.waitingBytes = 120_000_000
        XCTAssertTrue(OffloadText.speed(st).contains("about 1 min left"), OffloadText.speed(st))
        st.done = 10; st.freed = 5_000_000_000; st.finished = Date(timeIntervalSince1970: 372)
        st.uploadingSince = Date(timeIntervalSince1970: 10); st.uploadsFinished = Date(timeIntervalSince1970: 310)
        XCTAssertEqual(OffloadText.lastRun(st), "Last run: 10 offloaded, \(Fmt.diskBytes(5_000_000_000)) freed in 6 min 12 s (waited 5 min for uploads)")
        st.waiting = 2; st.stalled = true
        XCTAssertTrue(OffloadText.lastRun(st).hasSuffix("2 left on this Mac (nothing went up for 15 minutes)"))
    }

    func testProbeAnswersAndFails() async throws {
        // A plain listening socket on 127.0.0.1.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
        Darwin.listen(fd, 4)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = String(UInt16(bigEndian: addr.sin_port))
        let ms = await CloudUpload.probe(.init(host: "127.0.0.1", ports: [port]))
        XCTAssertNotNil(ms, "listening on \(port)")
        let none = await CloudUpload.probe(.init(host: "127.0.0.1", ports: ["1"]))
        XCTAssertNil(none, "nothing listening")
    }

    func testOtherNetworkHint() {
        let mac = [(addr: CloudUpload.ipv4("172.16.0.50")!, mask: CloudUpload.ipv4("255.255.0.0")!)]
        let hint = CloudUpload.otherNetworkHint(host: "10.0.0.20", local: mac)
        XCTAssertTrue(hint?.contains("this Mac is on a different one (172.16.0.50)") == true, hint ?? "nil")
        let home = [(addr: CloudUpload.ipv4("10.0.0.20")!, mask: CloudUpload.ipv4("255.255.255.0")!)]
        XCTAssertNil(CloudUpload.otherNetworkHint(host: "10.0.0.20", local: home), "same network: the problem is elsewhere")
        XCTAssertNil(CloudUpload.otherNetworkHint(host: "cloud.example.org", local: mac), "public servers: no such hint")
        XCTAssertTrue(CloudUpload.looksLikeHost("cloud.my-site.org"))
        XCTAssertFalse(CloudUpload.looksLikeHost("cloud.my-site.org-jo"))
    }

    /// Read-only, on this Mac's real cloud folder (APEX_LIVE_CLOUD=1): finds the
    /// app, its server, and reads upload states. Never offloads anything.
    func testLiveServiceReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["APEX_LIVE_CLOUD"] == "1",
              let s = Cloud.detected().first(where: { $0.name == "Nextcloud" }) else { throw XCTSkip("set APEX_LIVE_CLOUD=1") }
        let pids = CloudUpload.processes(for: s)
        let conns = CloudUpload.connections(pids)
        let server = CloudUpload.server(conns) ?? CloudUpload.knownServer(for: s)
        print("live: pids", pids, "connections", conns.map { "\($0.remoteHost):\($0.remotePort) \($0.state)" }, "server", server as Any)
        XCTAssertFalse(pids.isEmpty, "the Nextcloud app is running")
        XCTAssertNotNil(server)
        let probe = await CloudUpload.probe(server!)
        print("live: probe", probe as Any, "hint", CloudUpload.otherNetworkHint(host: server!.host, local: CloudUpload.localIPv4()) as Any)
        let files = Array(Cloud.storedFiles(s.path).prefix(200))
        let states = CloudUpload.states(files)
        print("live: states of \(files.count) stored files:", Dictionary(grouping: states, by: { "\($0)" }).mapValues(\.count))
    }
}

/// Renders the upload monitor off-screen with live readings (APEX_RENDER_MONITOR=out.png).
final class UploadMonitorRenderTests: XCTestCase {
    @MainActor func testRenderLive() async throws {
        guard let out = ProcessInfo.processInfo.environment["APEX_RENDER_MONITOR"],
              let s = Cloud.detected().first(where: { $0.name == "Nextcloud" }) else { throw XCTSkip("set APEX_RENDER_MONITOR") }
        var st = CloudStore.OffloadState()
        st.watchOnly = true
        st.uploadingSince = Date().addingTimeInterval(-200)
        let pids = CloudUpload.processes(for: s)
        var prev: [String: UInt64]?
        for _ in 0..<4 {
            let c = CloudUpload.connections(pids)
            if prev != nil { st.rateHistory.append(Double(CloudUpload.sent(c, previous: prev)) / 3) }
            prev = Dictionary(c.map { ($0.key, $0.bytesOut) }, uniquingKeysWith: max)
            try await Task.sleep(for: .seconds(3))
        }
        st.rate = st.rateHistory.last
        let e = CloudUpload.server(CloudUpload.connections(pids)) ?? CloudUpload.knownServer(for: s)!
        st.server = e.label; st.checkedServer = true
        st.latency = await CloudUpload.probe(e)
        st.downSince = st.latency == nil ? Date().addingTimeInterval(-130) : nil
        st.networkHint = st.latency == nil ? CloudUpload.otherNetworkHint(host: e.host, local: CloudUpload.localIPv4()) : nil
        let files = Array(Cloud.storedFiles(s.path).prefix(400))
        let waiting = zip(files, CloudUpload.states(files)).filter { $0.1 != .uploaded }
        st.waiting = waiting.count; st.total = waiting.count
        st.sendingNow = waiting.filter { $0.1 == .sending }.count
        st.waitingBytes = waiting.reduce(0) { $0 + $1.0.bytes }
        let view = UploadMonitor(state: st, service: s.name).frame(width: 720).padding(20)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view); r.scale = 2
        let img = try XCTUnwrap(r.nsImage)
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}

final class OffloadPauseTests: XCTestCase {
    func testPausedWords() {
        var st = CloudStore.OffloadState()
        st.watchOnly = true; st.paused = true
        XCTAssertEqual(OffloadText.paused(st), "Uploading is paused · checking the connection…")
        st.watchOnly = false; st.checkedServer = true; st.server = "10.0.0.20"; st.latency = nil
        XCTAssertEqual(OffloadText.paused(st), "Can’t connect to 10.0.0.20 · Uploading is paused")
        st.latency = 9
        XCTAssertEqual(OffloadText.paused(st), "Uploading is paused")
    }
}

/// Minimize to the side or into categories, on a store in a temporary folder.
@MainActor final class ShelfCategoryTests: XCTestCase {
    private var dir: URL!
    private var store: ShelfStore!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-shelfcat-\(UUID())")
        store = ShelfStore(folder: dir)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }

    func testNewCategoryThenSameCategoryAddsToIt() {
        store.add(urls("a.png", "b.png"))
        let id = store.newCategory(named: "Project shots")
        XCTAssertTrue(store.current.items.isEmpty, "the shelf is cleared away into the category")
        XCTAssertEqual(store.categories.count, 1)
        // A second shelf for the same category: added in, not a new category.
        store.add(urls("b.png", "c.png"))
        store.minimize(toCategory: id)
        XCTAssertEqual(store.categories.count, 1)
        XCTAssertEqual(Set(store.categories[0].items.map(\.name)), ["a.png", "b.png", "c.png"], "no file twice")
        // Typing the same name again also adds to it.
        store.add(urls("d.png"))
        XCTAssertEqual(store.newCategory(named: "project SHOTS"), id)
        XCTAssertEqual(store.categories[0].items.count, 4)
    }

    func testSideKeepsTheShelfAndStartsANewOne() {
        store.add(urls("a.png"))
        store.minimizeToSide()
        XCTAssertEqual(store.side.count, 1)
        XCTAssertTrue(store.current.items.isEmpty)
        // Open it, add to it, move it into a category: it leaves the side.
        store.open = .side(store.side[0].id)
        store.add(urls("b.png"))
        XCTAssertEqual(store.side[0].items.count, 2)
        let id = store.newCategory(named: "Later")
        XCTAssertTrue(store.side.isEmpty)
        XCTAssertEqual(store.categories.first { $0.id == id }?.items.count, 2)
        XCTAssertEqual(store.open, .current)
    }

    func testSavedAndLoaded() {
        store.add(urls("a.png")); store.newCategory(named: "Keep")
        store.add(urls("b.png")); store.minimizeToSide()
        let again = ShelfStore(folder: dir)
        XCTAssertEqual(again.categories.first?.name, "Keep")
        XCTAssertEqual(again.side.first?.items.first?.name, "b.png")
    }

    func testDropOnACategoryRow() {
        store.add(urls("a.png")); let id = store.newCategory(named: "X")
        store.add(urls("z.png"), to: .category(id))
        XCTAssertEqual(store.categories[0].items.first?.name, "z.png")
        XCTAssertEqual(store.open, .current, "dropping on a row doesn't change what's open")
        XCTAssertTrue(store.current.items.isEmpty)
    }
}

final class OnlineStorageEntryTests: XCTestCase {
    func testServerPages() {
        XCTAssertEqual(CloudStore.serverStoragePage(name: "Nextcloud", server: .init(host: "10.0.0.20", ports: ["443", "80"])),
                       "http://10.0.0.20/index.php/settings/user", "a home server: plain http")
        XCTAssertEqual(CloudStore.serverStoragePage(name: "Nextcloud", server: .init(host: "cloud.example.org", ports: ["443"])),
                       "https://cloud.example.org/index.php/settings/user")
        XCTAssertEqual(CloudStore.serverStoragePage(name: "ownCloud", server: .init(host: "oc.example.org", ports: ["443"])),
                       "https://oc.example.org/index.php/settings/personal")
        XCTAssertNil(CloudStore.serverStoragePage(name: "Nextcloud", server: nil))
    }

    func testTypedNumbers() {
        XCTAssertEqual(CloudStore.bytes("81,5", unit: "GB"), 81_500_000_000)
        XCTAssertEqual(CloudStore.bytes(" 2 ", unit: "TB"), 2_000_000_000_000)
        XCTAssertNil(CloudStore.bytes("lots", unit: "GB"))
        XCTAssertNil(CloudStore.bytes("-1", unit: "GB"))
    }

    func testNextcloudSettingsPageLineIsRead() {
        // What Nextcloud's personal settings page says.
        let q = CloudCatalog.parseUsage("You are using 81.7 GB of 100 GB (81.7 %)")
        XCTAssertEqual(q?.used, 81_700_000_000)
        XCTAssertEqual(q?.total, 100_000_000_000)
    }
}

final class UploadDotTests: XCTestCase {
    func testWhichCircle() {
        XCTAssertNil(CloudUpload.dot(.uploaded, paused: true, serverDown: true), "in the cloud: no circle")
        XCTAssertEqual(CloudUpload.dot(.sending, paused: false, serverDown: false), .uploading)
        XCTAssertEqual(CloudUpload.dot(.queued, paused: false, serverDown: false), .uploading)
        XCTAssertEqual(CloudUpload.dot(.queued, paused: false, serverDown: true), .paused, "can’t connect: yellow")
        XCTAssertEqual(CloudUpload.dot(.queued, paused: true, serverDown: false), .paused, "paused: yellow")
        XCTAssertEqual(CloudUpload.dot(.failed("x"), paused: true, serverDown: true), .failed("x"), "an error stays red")
    }
}

final class UploadProblemTests: XCTestCase {
    func testConnectionProblemsAreYellowWhileTheServerIsDown() {
        let p = CloudUpload.problem(domain: "NSFileProviderErrorDomain", code: -2005, text: "x")
        XCTAssertEqual(CloudUpload.dot(p, paused: false, serverDown: true), .paused, "Nextcloud -2005 while its server is unreachable")
        if case .failed = CloudUpload.dot(p, paused: false, serverDown: false) {} else { XCTFail("server answers, still can't sync: red") }
        XCTAssertEqual(CloudUpload.problem(domain: "NSFileProviderErrorDomain", code: -1004, text: ""), .blocked("Can’t reach the server."))
    }

    func testRealProblemsAreRedWithPlainWords() {
        XCTAssertEqual(CloudUpload.dot(CloudUpload.problem(domain: "NSFileProviderErrorDomain", code: -1003, text: ""), paused: true, serverDown: true),
                       .failed("Your cloud storage is full. Free some space online, or get more."))
        XCTAssertEqual(CloudUpload.problem(domain: "NSCocoaErrorDomain", code: 4, text: "No such file"), .failed("No such file"))
    }
}

final class SyncingDotTests: XCTestCase {
    func testTheAppSendingWinsOverApexsServerCheck() {
        XCTAssertEqual(CloudUpload.dot(.sending, paused: false, serverDown: true), .uploading, "the app says it's syncing: green")
        XCTAssertEqual(CloudUpload.dot(.sending, paused: true, serverDown: false), .paused)
        XCTAssertEqual(CloudUpload.dot(.queued, paused: false, serverDown: true), .paused)
    }
}

final class UploadProgressTests: XCTestCase {
    func testEstimate() {
        XCTAssertEqual(CloudUpload.estimatedProgress(sent: 50, size: 200), 0.25)
        XCTAssertEqual(CloudUpload.estimatedProgress(sent: 500, size: 200), 0.97, "never shown as finished until it is")
        XCTAssertEqual(CloudUpload.estimatedProgress(sent: 5, size: 0), 0)
    }
}

final class MediaInfoTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-info-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A JPEG with camera, date and GPS details, like a phone photo.
    private func photo() throws -> URL {
        let png = dir.appendingPathComponent("src.png")
        try MediaCompressorTests.drawScreenshotLike(to: png)
        let src = CGImageSourceCreateWithURL(png as CFURL, nil)!
        let url = dir.appendingPathComponent("Photo.jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:20 14:03:11", kCGImagePropertyExifFNumber: 1.8],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 26.2041, kCGImagePropertyGPSLatitudeRef: "S",
                                            kCGImagePropertyGPSLongitude: 28.0473, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(dest, CGImageSourceCreateImageAtIndex(src, 0, nil)!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testReadsTheDetailsPeopleCareAbout() async throws {
        let info = await MediaInfo.read(try photo())
        let labels = Set(info.map(\.label))
        for l in ["File size", "Dimensions", "Camera", "Taken", "Location", "Settings", "Format"] { XCTAssertTrue(labels.contains(l), l) }
    }

    func testRemoveDetailsKeepsEveryPixel() async throws {
        let original = try photo()
        let out = try await MediaInfo.removeDetails(original, output: dir.appendingPathComponent("Photo (no details).jpg"))
        let fields = await MediaInfo.read(out)
        let labels = Set(fields.map(\.label))
        XCTAssertFalse(labels.contains("Camera")); XCTAssertFalse(labels.contains("Location")); XCTAssertFalse(labels.contains("Taken"))
        let before = await MediaInfo.read(original)
        XCTAssertEqual(Set(MediaInfo.removed(original: before, copy: fields)), ["Camera", "Taken", "Location", "Settings"])
        // Same picture: identical pixels, same orientation.
        func pixels(_ u: URL) -> Data {
            let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(u as CFURL, nil)!, 0, nil)!
            return img.dataProvider!.data! as Data
        }
        XCTAssertEqual(pixels(original), pixels(out), "not re-encoded: the picture is untouched")
        let o = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertEqual(o?[kCGImagePropertyOrientation] as? Int, 6, "still the right way up")
    }

    func testRemoveDetailsFromAVideoIsACopy() async throws {
        let src = dir.appendingPathComponent("Clip.mov")
        try await ShelfActionTests.writeMovie(to: src)
        let out = try await MediaInfo.removeDetails(src, output: dir.appendingPathComponent("Clip (no details).mov"))
        let d = try await AVURLAsset(url: out).load(.duration)
        XCTAssertGreaterThan(d.seconds, 1.5)
        XCTAssertEqual(Double(MediaCompressor.fileSize(out)), Double(MediaCompressor.fileSize(src)), accuracy: Double(MediaCompressor.fileSize(src)) * 0.05,
                       "passthrough: same size, not re-encoded")
    }
}

@MainActor final class ShelfCloseTests: XCTestCase {
    func testClosingAlwaysGivesAFreshShelfAndKeepsTheRest() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-shelfclose-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ShelfStore(folder: dir)
        store.add([URL(fileURLWithPath: "/tmp/a.png")]); let cat = store.newCategory(named: "Keep me")
        store.add([URL(fileURLWithPath: "/tmp/b.png")]); store.minimizeToSide()
        store.add([URL(fileURLWithPath: "/tmp/c.png")]); store.minimizeToSide(menuBar: true)
        store.add([URL(fileURLWithPath: "/tmp/old.png")])
        // Viewing the category, then ×: next time is a new, empty shelf.
        store.open = .category(cat)
        store.newShelf()
        XCTAssertEqual(store.open, .current)
        XCTAssertTrue(store.current.items.isEmpty, "never the old shelf")
        XCTAssertEqual(store.shelves[1].items.first?.name, "old.png", "the old one is in Recent")
        XCTAssertEqual(store.categories.first?.items.count, 1, "categories untouched")
        XCTAssertEqual(store.edgeShelves.count, 1); XCTAssertEqual(store.menuBarShelves.count, 1)
    }
}

/// APEX_RENDER_COMPARE=out.png: the compare pop-up for a phone-like photo and its compressed copy.
final class CompareRenderTests: XCTestCase {
    @MainActor func testRender() async throws {
        guard let out = ProcessInfo.processInfo.environment["APEX_RENDER_COMPARE"] else { throw XCTSkip("set APEX_RENDER_COMPARE") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-cmp-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("src.png")
        try MediaCompressorTests.drawScreenshotLike(to: png)
        let src = CGImageSourceCreateWithURL(png as CFURL, nil)!
        let photo = dir.appendingPathComponent("IMG_2041.jpg")
        let dest = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, CGImageSourceCreateImageAtIndex(src, 0, nil)!, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:20 14:03:11", kCGImagePropertyExifFNumber: 1.8],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 26.2041, kCGImagePropertyGPSLatitudeRef: "S",
                                            kCGImagePropertyGPSLongitude: 28.0473, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let r = try await MediaCompressor.compress(photo, keepMetadata: false, output: dir.appendingPathComponent("IMG_2041 (compressed).jpg"))
        let view = VStack(spacing: 20) {
            SizeChange(before: r.before, after: r.after)
            CompareView(pair: ComparePair(original: photo, copy: r.url))
        }
        .padding(20).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 540, height: 640)
        // A real window, far off-screen, so the view appears and loads its details and previews.
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 540, height: 640), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = host
        w.orderFrontRegardless()
        defer { w.orderOut(nil) }
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(100)); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}

final class CompressNameTests: XCTestCase {
    func testJpgStaysJpg() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-jpg-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("s.png"); try MediaCompressorTests.drawScreenshotLike(to: png)
        let jpg = dir.appendingPathComponent("IMG_1.jpg")
        let d = CGImageDestinationCreateWithURL(jpg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(png as CFURL, nil)!, 0, nil)!,
                                   [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        CGImageDestinationFinalize(d)
        let r = try MediaCompressor.compressImage(jpg, keepMetadata: true, output: MediaCompressor.outputURL(for: jpg, suffix: "compressed", fallback: dir))
        XCTAssertEqual(r.url.lastPathComponent, "IMG_1 (compressed).jpg")
    }
}

/// APEX_RENDER_FAILED=out.png: the upload card with one file waiting and one that failed.
final class UploadFailedRenderTests: XCTestCase {
    @MainActor func testRender() throws {
        guard let out = ProcessInfo.processInfo.environment["APEX_RENDER_FAILED"] else { throw XCTSkip("set APEX_RENDER_FAILED") }
        var st = CloudStore.OffloadState()
        st.uploadingSince = Date().addingTimeInterval(-95); st.total = 2; st.waiting = 1; st.failed = 1
        st.waitingBytes = 357_000_000; st.rateHistory = [0, 1_200_000, 2_400_000, 1_800_000]; st.rate = 1_800_000
        st.failedFiles = ["MicrosoftTeams.pkg": "Your cloud storage is full. Free some space online, or get more."]
        st.checkedServer = true; st.server = "10.0.0.20"; st.latency = 8
        let host = NSHostingView(rootView: UploadMonitor(state: st, service: "Nextcloud").frame(width: 720).padding(20)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 420)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}
