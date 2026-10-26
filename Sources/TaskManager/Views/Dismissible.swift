import AppKit
import SwiftUI

/// A message that can be put away: a small × when the pointer is over it,
/// or swipe it left or right (two fingers on the trackpad, or drag it) and it
/// slides out.
struct Dismissible<Content: View>: View {
    var onDismiss: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false
    @State private var offset: CGFloat = 0
    @State private var monitor: Any?
    @State private var scrolled: CGFloat = 0

    /// How far a swipe has to go before it counts.
    static var threshold: CGFloat { 50 }

    var body: some View {
        HStack(spacing: 6) {
            content
            if hover {
                Button { slideOut(direction: 1) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss (or swipe it away)")
                .transition(.opacity)
            }
        }
        .offset(x: offset)
        .opacity(1 - min(0.9, Double(abs(offset)) / 160))
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hover = inside }
            if inside { startWatchingSwipes() } else { stopWatchingSwipes() }
        }
        .gesture(DragGesture(minimumDistance: 6)
            .onChanged { offset = $0.translation.width }
            .onEnded { v in
                if abs(v.translation.width) > Self.threshold { slideOut(direction: v.translation.width > 0 ? 1 : -1) }
                else { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 } }
            })
        .onDisappear { stopWatchingSwipes() }
    }

    private func slideOut(direction: CGFloat) {
        stopWatchingSwipes()
        withAnimation(.easeIn(duration: 0.18)) { offset = 220 * direction }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onDismiss(); offset = 0; scrolled = 0 }
    }

    /// Two-finger horizontal swipes while the pointer is over it.
    private func startWatchingSwipes() {
        guard monitor == nil else { return }
        scrolled = 0
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return e }
            scrolled += e.scrollingDeltaX
            offset = scrolled
            if e.phase == .ended || e.momentumPhase == .began {
                if abs(scrolled) > Self.threshold { slideOut(direction: scrolled > 0 ? 1 : -1) }
                else { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }; scrolled = 0 }
            }
            return nil
        }
    }

    private func stopWatchingSwipes() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}
