import SwiftUI

/// Network Doctor sheet: runs the checks for one connection and shows the
/// findings with the same cards as Drive Doctor.
struct NetworkDoctorView: View {
    @Environment(\.dismiss) private var dismiss
    let device: NetworkDevice
    let primary: String
    @State private var input: NetworkDoctor.Input?
    @State private var running = false
    @State private var open = Set<String>()

    private let stages = ["Connection", "Address", "Router", "Internet", "Website names", "Sign-in page"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Network Doctor").font(.title2).bold()
                    Text(device.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Checks each step from this Mac to the internet (connection, address, router, internet, website names, sign-in pages) and tells you where it breaks and what to do.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            // The path, step by step.
            HStack(spacing: 6) {
                ForEach(Array(stages.enumerated()), id: \.offset) { n, s in
                    let state = stageState(n)
                    HStack(spacing: 4) {
                        if running && state == nil { ProgressView().controlSize(.mini) }
                        else { Image(systemName: state == true ? "checkmark.circle.fill" : state == false ? "xmark.circle.fill" : "circle")
                                .foregroundStyle(state == true ? Color.green : state == false ? .red : .secondary) }
                        Text(s).font(.caption)
                    }
                    if n < stages.count - 1 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let input {
                        let report = NetworkDoctor.diagnose(input)
                        ForEach(report.findings) { FindingCard(finding: $0, open: $open, run: run) }
                        ForEach(report.missing, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("Running checks… about 10 seconds.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
            }
            .frame(minHeight: 340, maxHeight: 500)

            HStack {
                Text("Nothing is changed by the checks. Measured: by Apex just now.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(running ? "Checking…" : "Check Again") { check() }.disabled(running)
            }
        }
        .padding(22)
        .frame(width: 680)
        .task { check() }
    }

    /// true = passed, false = failed, nil = not checked (yet).
    private func stageState(_ n: Int) -> Bool? {
        guard let i = input else { return nil }
        switch n {
        case 0: return i.isUp
        case 1: return i.isUp ? !(i.address.isEmpty || i.address.hasPrefix("169.254.")) : nil
        case 2: return i.router?.reachable
        case 3: return (i.internet == nil && i.httpsOK == nil) ? nil : ((i.internet?.reachable ?? false) || (i.httpsOK ?? false))
        case 4: return i.dnsOK
        default: return i.signInPage.map { !$0 }
        }
    }

    private func check() {
        running = true; input = nil
        let d = device, p = primary
        Task {
            input = await Task.detached(priority: .userInitiated) { NetworkProbe.run(device: d, primary: p) }.value
            running = false
        }
    }

    private func run(_ a: SafeAction) {
        if a == .testSpeed { check() } else { SafeAction.runCommon(a) }
        if a == .restartWiFi {
            Task { try? await Task.sleep(for: .seconds(10)); check() }
        }
    }
}
