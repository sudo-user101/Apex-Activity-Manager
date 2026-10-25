import AppKit
import SwiftUI

/// One finding from a doctor (Drive Doctor, Network Doctor): what was found,
/// why it matters, the evidence and where it came from, causes, steps in
/// order, how to tell it's fixed, and safe one-click actions.
struct FindingCard: View {
    let finding: Finding
    @Binding var open: Set<String>
    var sourceName: (EvidenceSource) -> String = FindingCard.defaultSource
    var run: (SafeAction) -> Void

    static func defaultSource(_ s: EvidenceSource) -> String {
        switch s { case .device: return "Device"; case .measured: return "Measured"; case .macOS: return "macOS"; case .inferred: return "Rule" }
    }

    var body: some View {
        let f = finding
        let expanded = Binding(get: { open.contains(f.id) || f.severity >= .warning },
                               set: { if $0 { open.insert(f.id) } else { open.remove(f.id) } })
        DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(f.why).fixedSize(horizontal: false, vertical: true)
                if !f.evidence.isEmpty {
                    section("Evidence") {
                        ForEach(f.evidence, id: \.self) { e in
                            HStack(alignment: .firstTextBaseline) {
                                Text(e.label).foregroundStyle(.secondary)
                                Spacer()
                                Text(e.value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
                                Text(sourceName(e.source)).font(.caption2).foregroundStyle(.tertiary).frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                }
                if !f.causes.isEmpty {
                    section("Possible causes") {
                        ForEach(f.causes, id: \.self) { Text("• " + $0).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                if !f.steps.isEmpty {
                    section("What to do, in order") {
                        ForEach(Array(f.steps.enumerated()), id: \.offset) { n, s in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(n + 1). \(s.title)")
                                if !s.expected.isEmpty { Text("If it works: " + s.expected).font(.caption).foregroundStyle(.secondary) }
                                if !s.risk.isEmpty { Text(s.risk).font(.caption).foregroundStyle(.orange) }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !f.followUp.isEmpty { section("Is it fixed?") { Text(f.followUp).fixedSize(horizontal: false, vertical: true) } }
                if !f.escalate.isEmpty {
                    Label(f.escalate, systemImage: "wrench.and.screwdriver").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !f.actions.isEmpty {
                    HStack { ForEach(f.actions, id: \.self) { a in Button(a.title) { run(a) }.controlSize(.small) } }
                }
            }
            .font(.callout)
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Self.icon(f.severity)).foregroundStyle(Self.color(f.severity))
                Text(f.title).font(.body.weight(.medium))
                Spacer()
                if f.severity != .ok {
                    Text(f.confidence.title + " · " + f.severity.title).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    static func icon(_ s: FindingSeverity) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .notice: return "eye.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    static func color(_ s: FindingSeverity) -> Color {
        switch s { case .ok: return .green; case .info: return .blue; case .notice: return .yellow; case .warning: return .orange; case .critical: return .red }
    }
}
