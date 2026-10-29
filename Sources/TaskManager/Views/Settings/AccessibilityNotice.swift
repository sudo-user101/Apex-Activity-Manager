import SwiftUI

/// Shown under a feature that needs Accessibility while it doesn't work for
/// this copy of Apex: Allow, and Fix for a switch that's on in System Settings
/// but belongs to another copy (macOS keeps one switch per app ID).
struct AccessibilityNotice: View {
    @State private var trusted = AccessibilityAccess.trusted
    @State private var others: [URL] = []
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        if !trusted {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "hand.raised").foregroundStyle(.orange)
                    Text("Accessibility isn’t on for this copy of Apex. Once it is, this starts by itself.")
                        .settingsCaption().fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Allow…") { AccessibilityAccess.ask() }.controlSize(.small)
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(others.isEmpty
                         ? "Already on in System Settings? That switch is for an earlier build of Apex. Fix clears it and asks again; switch it on once more."
                         : "Another copy of Apex is at \(others.map { $0.deletingLastPathComponent().path }.joined(separator: ", ")). macOS keeps one switch for every copy, so the one you see on may be that copy’s. Keep one copy, or press Fix to give the switch to this one.")
                        .settingsCaption().fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Fix") { PermissionCenter.shared.resetAndAsk(.accessibility) }.controlSize(.small)
                }
            }
            .onAppear { others = AccessibilityAccess.otherCopies() }
            .onReceive(tick) { _ in trusted = AccessibilityAccess.trusted }
        }
    }
}
