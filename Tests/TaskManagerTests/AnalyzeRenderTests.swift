import AppKit
import SwiftUI
import XCTest
@testable import TaskManager

/// APEX_RENDER_ANALYZE=folder:file.png — Analyze opened on a folder (read-only), after it has measured.
final class AnalyzeRenderTests: XCTestCase {
    @MainActor func testRender() async throws {
        guard let arg = ProcessInfo.processInfo.environment["APEX_RENDER_ANALYZE"], let i = arg.lastIndex(of: ":") else { throw XCTSkip("set APEX_RENDER_ANALYZE") }
        let folder = String(arg[..<i]), out = String(arg[arg.index(after: i)...])
        let start = Date()
        let view = AnalyzeView(onBack: {}, onDone: {}, startAt: DiskEntry(name: (folder as NSString).lastPathComponent, path: folder, isDirectory: true))
            .environment(AppModel.shared).padding(20).frame(width: 760, height: 640)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 760, height: 640), styleMask: .borderless, backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        w.orderFrontRegardless()
        for _ in 0..<60 { try await Task.sleep(for: .milliseconds(500)) }
        print("ANALYZE rendered after \(String(format: "%.0f", Date().timeIntervalSince(start))) s")
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        w.orderOut(nil)
    }
}
