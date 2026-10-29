import AppKit
import SwiftUI
import XCTest
@testable import TaskManager

final class AddCloudSheetTests: XCTestCase {
    func testAddressChecks() {
        XCTAssertNil(AddCloudSheet.addressProblem("https://cloud.example.com/remote.php/dav"))
        XCTAssertNil(AddCloudSheet.addressProblem("https://localhost:8443"))
        XCTAssertNotNil(AddCloudSheet.addressProblem("https://"))
        XCTAssertNotNil(AddCloudSheet.addressProblem("cloud.example.com"))
        XCTAssertNotNil(AddCloudSheet.addressProblem("ftp://cloud.example.com"))
        XCTAssertEqual(AddCloudSheet.addressProblem("http://10.0.0.5/dav")?.contains("isn’t encrypted"), true)
    }

    /// APEX_RENDER_ADDCLOUD=dir: each step, light and dark, as PNGs.
    @MainActor func testRender() async throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_RENDER_ADDCLOUD"] else { throw XCTSkip("set APEX_RENDER_ADDCLOUD") }
        let p = CloudCatalog.providers.first { $0.webdav != nil && $0.storagePage != nil } ?? CloudCatalog.providers[0]
        let views: [(String, AddCloudSheet)] = [
            ("choose", AddCloudSheet()),
            ("connect-web", AddCloudSheet(step: .connect, provider: p, method: .web)),
            ("connect-webdav", AddCloudSheet(step: .connect, provider: p, method: .webdav)),
            ("summary", AddCloudSheet(step: .summary, provider: p, method: .webdav)),
        ]
        for (name, v) in views {
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: v.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
                let size = host.fittingSize
                let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
                w.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                w.contentView = host
                w.orderFrontRegardless()
                for _ in 0..<10 { try await Task.sleep(for: .milliseconds(50)) }
                host.layoutSubtreeIfNeeded()
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/addcloud-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                w.orderOut(nil)
            }
        }
    }
}
