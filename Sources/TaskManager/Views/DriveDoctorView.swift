import AppKit
import SwiftUI

/// Drive Doctor (the stethoscope in drive page headers): findings, evidence and
/// what to do, built from the same record as the Drive health item. The numbers
/// themselves stay in the Drive health popover; this explains them.
struct DriveDoctorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: String
    let record: DriveRecord?
    let usb: USBLink?
    let capacity: UInt64
    let available: UInt64
    let volumes: [(name: String, path: String)]
    @State private var checking = false
    @State private var firstAid: [DriveCheck.Result] = []
    @State private var open = Set<String>()

    var body: some View {
        let report = DriveDoctor.diagnose(.init(record: record, usb: usb, capacity: capacity,
                                                available: available, firstAid: firstAid))
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Drive Doctor").font(.title2).bold()
                    Text(title).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Drive Doctor analyses your drive’s health, identifies potential problems, estimates remaining lifespan when there’s enough data, and recommends steps to diagnose and fix issues.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    summary(report)
                    ForEach(report.findings) { findingCard($0) }
                    if !report.missing.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What Apex can’t see").font(.subheadline.weight(.semibold))
                            ForEach(report.missing, id: \.self) {
                                Text($0).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(minHeight: 380, maxHeight: 520)

            HStack {
                Text("Measured: by Apex · Drive: from the drive’s own health log · macOS: reported by macOS")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(checking ? "Checking…" : (firstAid.isEmpty ? "Check for Errors" : "Check Again")) { check() }
                    .disabled(checking || volumes.isEmpty)
                    .help("Runs macOS First Aid in read-only mode; nothing is changed. About 10 seconds per volume.")
            }
            if checking { ProgressView().progressViewStyle(.linear) }
        }
        .padding(22)
        .frame(width: 680)
    }

    private func summary(_ report: DiagnosisReport) -> some View {
        let status = record.map { DriveHealthRules.assess($0).status } ?? .learning
        let problems = report.problems.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: status.symbol).foregroundStyle(status.color).font(.title3)
                Text(status.title).font(.headline)
                Spacer()
                Text(problems == 0 ? "No issues to act on" : "\(problems) finding\(problems == 1 ? "" : "s") to look at")
                    .foregroundStyle(.secondary)
            }
            Label(DriveDoctor.describe(DriveDoctor.lifespan(record)), systemImage: "hourglass")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if report.worst >= .warning {
                Label("Back up anything important on this drive soon.", systemImage: "externaldrive.badge.timemachine")
                    .font(.callout.weight(.medium)).foregroundStyle(.orange)
            }
            if !firstAid.isEmpty, firstAid.allSatisfy(\.ok) {
                Label("First Aid (read-only): no file-system problems found.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func findingCard(_ f: Finding) -> some View {
        let expanded = Binding(get: { open.contains(f.id) || f.severity >= .warning },
                               set: { if $0 { open.insert(f.id) } else { open.remove(f.id) } })
        return DisclosureGroup(isExpanded: expanded) {
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
                Image(systemName: icon(f.severity)).foregroundStyle(color(f.severity))
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

    private func sourceName(_ s: EvidenceSource) -> String {
        switch s { case .device: return "Drive"; case .measured: return "Measured"; case .macOS: return "macOS"; case .inferred: return "Rule" }
    }

    private func icon(_ s: FindingSeverity) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .notice: return "eye.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private func color(_ s: FindingSeverity) -> Color {
        switch s { case .ok: return .green; case .info: return .blue; case .notice: return .yellow; case .warning: return .orange; case .critical: return .red }
    }

    private func run(_ a: SafeAction) {
        switch a {
        case .checkForErrors: check()
        case .openDiskUtility: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
        case .openTimeMachine: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!)
        case .openStorageSettings: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
        case .freeUpSpace:
            let root = record?.isStartup == true ? nil : volumes.first?.path
            dismiss()
            DispatchQueue.main.async { model.openStorage(volume: root) }
        }
    }

    private func check() {
        checking = true; firstAid = []
        let v = volumes
        Task {
            firstAid = await Task.detached(priority: .userInitiated) { DriveCheck.verify(v) }.value
            checking = false
        }
    }
}
