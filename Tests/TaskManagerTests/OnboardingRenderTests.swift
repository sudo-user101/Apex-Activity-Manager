import AppKit
import SwiftUI
import XCTest
@testable import TaskManager

/// APEX_RENDER_UTILITIES=dir also renders the welcome and permissions screens.
final class OnboardingRenderTests: XCTestCase {
    @MainActor func testRender() async throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_RENDER_UTILITIES"] else { throw XCTSkip("set APEX_RENDER_UTILITIES") }
        for (step, name) in [(0, "welcome"), (2, "permissions")] {
            let host = NSHostingView(rootView: OnboardingView(step: step).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
            let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 640, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .aqua)
            w.contentView = host
            w.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(800))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/onboarding-\(name).png"))
            w.orderOut(nil)
        }
    }
}
