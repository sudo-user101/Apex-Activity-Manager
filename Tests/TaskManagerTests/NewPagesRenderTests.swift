import AppKit
import SwiftUI
import XCTest
@testable import TaskManager

/// APEX_RENDER_NEW=dir: Menu bar › Sound and Cloud Disks › Overview, from
/// this Mac's live state (read-only), light and dark.
final class NewPagesRenderTests: XCTestCase {
    @MainActor func testRender() async throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_RENDER_NEW"] else { throw XCTSkip("set APEX_RENDER_NEW") }
        let store = CloudStore.shared
        store.refreshList()
        for s in store.services { store.refresh(s) }
        for _ in 0..<120 where !store.scanning.isEmpty { try await Task.sleep(for: .seconds(1)) }
        func shot(_ name: String, _ width: CGFloat, _ view: some View) throws {
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: view.frame(width: width).padding(16)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
                let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width + 32, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
                w.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                w.contentView = host
                w.setContentSize(host.fittingSize)
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(1.0))
                host.layoutSubtreeIfNeeded()
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(scheme == .dark ? "dark" : "light").png"))
                w.orderOut(nil)
            }
        }
        try shot("sound", 320, SoundTab())
        try shot("cloud-overview", 760, CloudOverviewView(onOpen: { _ in }))
    }
}
