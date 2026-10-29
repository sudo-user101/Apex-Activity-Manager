import AppKit
import SwiftUI

/// Drive Doctor (the stethoscope in drive page headers): findings, evidence and
/// what to do, built from the same record as the Drive health item. The numbers
/// themselves stay in the Drive health popover; this explains them.
/// `embedded` drops the header and fixed size for Storage › Diagnose.
struct DriveDoctorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: String
    let record: DriveRecord?
    let usb: USBLink?
    let capacity: UInt64
    let available: UInt64
    let volumes: [(name: String, path: String)]
    var embedded = false
    @State private var checking = false
    @State private var firstAid: [DriveCheck.Result] = []
    @State private var open = Set<String>()
    @State private var manual = false

    var body: some View {
        let report = DriveDoctor.diagnose(.init(record: record, usb: usb, capacity: capacity,
                                                available: available, firstAid: firstAid))
        VStack(alignment: .leading, spacing: 14) {
            if !embedded {
                HStack(spacing: 10) {
                    Image(systemName: "stethoscope").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Drive Doctor").font(.title2).bold()
                        Text(title).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            Picker("", selection: $manual) {
                Text("Automatic").tag(false)
                Text("Manual").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            .help("Automatic: Drive Doctor checks everything and explains. Manual: run individual checks yourself.")

            if manual {
                DriveManualView(record: record, volumes: volumes).frame(minHeight: 380, maxHeight: 520)
            } else {
            Text("Drive Doctor analyses your drive’s health, identifies potential problems, estimates remaining lifespan when there’s enough data, and recommends steps to diagnose and fix issues.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    summary(report)
                    ForEach(report.findings) { FindingCard(finding: $0, open: $open, sourceName: { $0 == .device ? "Drive" : FindingCard.defaultSource($0) }, run: run) }
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
        }
        .padding(embedded ? 0 : 22)
        .frame(width: embedded ? nil : 680)
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
        default: SafeAction.runCommon(a)
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
