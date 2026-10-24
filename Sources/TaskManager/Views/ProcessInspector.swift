import AppKit
import SwiftUI

/// Right-hand panel in Processes: everything about the selected process.
struct ProcessInspector: View {
    @Environment(AppModel.self) private var model
    let pid: pid_t?
    @State private var command: String?
    @State private var signature: SignatureInfo?
    @State private var bundle: BundleFacts?

    struct BundleFacts: Sendable { var version: String?; var identifier: String?; var developer: String? }

    var body: some View {
        ScrollView {
            if let pid, let p = model.process(pid) {
                content(p).padding(16)
            } else {
                ContentUnavailableView("No Process Selected", systemImage: "info.circle",
                                       description: Text("Click a process to see its details."))
                    .padding(.top, 60)
            }
        }
        .task(id: pid) { await load() }
    }

    @ViewBuilder
    private func content(_ p: ProcessInfoSample) -> some View {
        let app = NSRunningApplication(processIdentifier: p.pid)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: IconCache.shared.icon(forBundle: p.bundlePath)).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.title3).bold().lineLimit(2)
                    HStack(spacing: 6) {
                        Text("PID \(p.pid)")
                        if p.background { Label("Optimized", systemImage: "leaf.fill").foregroundStyle(.green) }
                        if p.state == .stopped { Label("Paused", systemImage: "pause.circle.fill").foregroundStyle(.orange) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Actions
            VStack(alignment: .leading, spacing: 6) {
                if let app, app.activationPolicy == .regular {
                    Button { app.unhide(); app.activate() } label: { Label("Bring to Front", systemImage: "macwindow") }
                }
                if !p.path.isEmpty {
                    Button { ProcessActions.reveal(path: p.bundlePath.isEmpty ? p.path : p.bundlePath) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
                HStack {
                    Button { model.setOptimized(pids: model.withHelpers([p.pid]), !p.background) } label: {
                        Label(p.background ? "Stop Optimizing" : "Optimize", systemImage: p.background ? "leaf.fill" : "leaf")
                    }
                    Button(role: .destructive) { model.end(pids: [p.pid], force: false) } label: {
                        Label("Quit", systemImage: "xmark.octagon")
                    }
                }
            }
            .buttonStyle(.bordered).controlSize(.small)

            if p.restricted {
                Label("macOS limits what other apps can read about processes owned by root or other users. CPU and memory come from the system’s ps tool; disk, threads, power and the command line aren’t available without administrator rights.",
                      systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            section("Running") {
                fact("Running for", p.started.map { Fmt.duration(Date().timeIntervalSince($0)) } ?? "—")
                fact("Started", p.started.map { Fmt.dateTime.string(from: $0) } ?? "—")
                fact("Status", p.state.rawValue)
                fact("User", p.user)
                fact("Parent", model.process(p.ppid).map { "\($0.name) (\(p.ppid))" } ?? "\(p.ppid)")
                fact("Kind", p.kind.title)
            }

            section("Usage") {
                fact("CPU", Fmt.percent(p.cpu * model.cpuScale) + "%")
                fact("Memory", Fmt.bytes(p.memory))
                fact("Disk", p.restricted ? "—" : "↓ \(Fmt.rate(p.diskReadPerSec))  ↑ \(Fmt.rate(p.diskWritePerSec))")
                fact("Network", Fmt.rate(p.netPerSec))
                fact("GPU", Fmt.percent(p.gpu) + "%")
                fact("Power", p.restricted ? "—" : EnergyRow.watts(p.power))
                fact("Threads", p.restricted ? "—" : "\(p.threads)")
                fact("Priority (nice)", "\(p.nice)")
            }

            section("Location") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.bundlePath.isEmpty ? (p.path.isEmpty ? "—" : p.path) : p.bundlePath)
                        .font(.caption).textSelection(.enabled).lineLimit(4)
                    if !p.bundlePath.isEmpty && p.path != p.bundlePath {
                        Text(p.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                    }
                }
                if let v = bundle?.version { fact("Version", v) }
                if let id = bundle?.identifier { fact("Bundle ID", id) }
            }

            section("Security") {
                if let sig = signature {
                    HStack(spacing: 6) {
                        Image(systemName: sig.isTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(sig.isTrusted ? .green : .orange)
                        Text(sig.status.rawValue)
                    }
                    if let dev = sig.developer { fact("Developer", dev) }
                } else {
                    Text(p.path.isEmpty ? "Not available" : "Checking…").foregroundStyle(.secondary)
                }
                if !p.path.isEmpty {
                    Button("Check on VirusTotal") {
                        let path = p.path
                        Task {
                            if let hash = await Task.detached(operation: { CodeSignature.sha256(path) }).value,
                               let url = URL(string: "https://www.virustotal.com/gui/file/\(hash)") { NSWorkspace.shared.open(url) }
                        }
                    }
                    .buttonStyle(.link).font(.caption)
                    .help("Only the file’s fingerprint (SHA-256) is sent.")
                }
            }

            section("Command") {
                Text(command ?? (p.restricted ? "Not available for this process" : "—"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(8)
            }
        }
    }

    private func load() async {
        command = nil; signature = nil; bundle = nil
        guard let pid, let p = model.process(pid) else { return }
        let path = p.path, bundlePath = p.bundlePath
        async let cmd = Task.detached { ProcessActions.commandLine(pid: pid) }.value
        async let sig = Task.detached { CodeSignature.check(bundlePath.isEmpty ? path : bundlePath) }.value
        async let facts = Task.detached { () -> BundleFacts? in
            guard !bundlePath.isEmpty, let b = Bundle(path: bundlePath) else { return nil }
            return BundleFacts(version: b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                               identifier: b.bundleIdentifier, developer: nil)
        }.value
        command = await cmd
        signature = await sig
        bundle = await facts
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            c()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).lineLimit(2).textSelection(.enabled)
        }
        .font(.callout)
    }
}
