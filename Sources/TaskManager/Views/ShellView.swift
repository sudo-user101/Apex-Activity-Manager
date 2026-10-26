import AppKit
import SwiftUI

/// Shell: categories of ready-made commands (fill in the blanks, run, see the
/// output live), or your own command. Opens over the Network page; Pop Out
/// gives it its own window.
struct ShellView: View {
    var inWindow = false
    var onPopOut: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("shellCategory") private var category = "Network"
    @State private var chosen: ShellCommand?
    @State private var values: [String: String] = [:]
    /// The ready-made command as the person edited it (e.g. with sudo added); nil = as filled in.
    @State private var edited: String?
    @State private var custom = ""
    @State private var runner = ShellRunner()
    @State private var services: [String] = []
    @State private var confirm: (command: String, admin: Bool)?
    /// Commands run from the command line, newest last (↑ / ↓ go through them).
    @AppStorage("shellHistory") private var historyText = ""
    @State private var historyIndex: Int?
    @FocusState private var promptFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Categories, like a sidebar.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ShellCatalog.categories, id: \.self) { c in
                    Button { withAnimation(.easeInOut(duration: 0.15)) { category = c; chosen = nil } } label: {
                        Label(c, systemImage: icon(c)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(category == c ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 190)
            .background(.quaternary.opacity(0.4))
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                header
                commandList
                console
            }
            .padding(14)
        }
        .frame(minWidth: 820, minHeight: 560)
        .task { services = await Task.detached { ShellView.networkServices() }.value }
        .confirmationDialog("Run this?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { c in
            Button(c.admin ? "Run as Administrator" : "Run") { runner.run(c.command, admin: c.admin) }
        } message: { c in
            Text("This changes your Mac:\n\n\(c.command)")
        }
    }

    private var header: some View {
        HStack {
            Text("Shell").font(.title2.bold())
            Text(category).foregroundStyle(.secondary)
            Spacer()
            if !inWindow, let onPopOut {
                Button { onPopOut() } label: { Label("Pop Out", systemImage: "macwindow.on.rectangle") }
                    .help("Open the Shell in its own window")
            }
            if !inWindow { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
    }

    private var commandList: some View {
        HStack(alignment: .top, spacing: 12) {
            List(ShellCatalog.commands.filter { $0.category == category }, selection: Binding(get: { chosen?.id }, set: { id in
                chosen = ShellCatalog.commands.first { $0.id == id }; values = [:]; edited = nil
            })) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(c.title).font(.callout.weight(.medium))
                        if c.needsAdmin { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("Asks for your password") }
                    }
                    if !c.detail.isEmpty { Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                .padding(.vertical, 2)
                .tag(c.id)
            }
            .frame(width: 280)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                if let c = chosen {
                    Text(c.title).font(.headline)
                    if !c.detail.isEmpty { Text(c.detail).font(.callout).foregroundStyle(.secondary) }
                    ForEach(c.fields, id: \.self) { f in
                        HStack {
                            Text(f).frame(width: 110, alignment: .trailing).foregroundStyle(.secondary)
                            TextField(placeholder(f), text: Binding(get: { values[f] ?? "" }, set: { values[f] = $0; edited = nil }))
                                .textFieldStyle(.roundedBorder)
                            if f == "Service", !services.isEmpty {
                                Menu("Choose") { ForEach(services, id: \.self) { s in Button(s) { values[f] = s; edited = nil } } }.fixedSize()
                            }
                        }
                    }
                    let cmd = edited ?? c.command(values)
                    // Editable: e.g. put sudo in front for root access, or add options.
                    TextField("", text: Binding(get: { cmd }, set: { edited = $0 }), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1...3)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        .help("You can change the command here, e.g. put sudo in front to run it as administrator")
                    if edited != nil {
                        Button("Back to the original") { edited = nil }.buttonStyle(.link).font(.caption)
                    }
                    HStack {
                        let missing = c.fields.contains { (values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
                        let typed = ShellCatalog.adminForm(cmd)
                        let admin = c.needsAdmin || typed.admin
                        Button(runner.running ? "Running…" : (admin ? "Run as Administrator" : "Run")) {
                            start(typed.command, admin: admin, changes: c.changes || edited != nil)
                        }
                            .keyboardShortcut(.defaultAction)
                            .disabled((missing && edited == nil) || runner.running)
                        Button("Copy to Command Line") { toPrompt(cmd) }
                            .help("Puts it in the command line below (and on the clipboard) so you can change it or add to it, then press Return")
                        if missing && edited == nil { Text("Fill in the blanks first.").font(.caption).foregroundStyle(.secondary) }
                    }
                } else {
                    Text("Choose a command on the left.").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 230)
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("OUTPUT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if runner.running { ProgressView().controlSize(.mini) }
                if let code = runner.exitCode {
                    Text(code == 0 ? "Finished" : code == -128 ? "Cancelled" : "Ended with code \(code)")
                        .font(.caption).foregroundStyle(code == 0 ? .green : .orange)
                }
                Spacer()
                if runner.running { Button("Stop") { runner.stop() }.controlSize(.small) }
                Button("Copy Output") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(runner.output, forType: .string) }
                    .controlSize(.small).disabled(runner.output.isEmpty)
                Button("Clear") { runner.clear() }.controlSize(.small).disabled(runner.running || runner.output.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.output.isEmpty ? "Output appears here." : runner.output)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(runner.output.isEmpty ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: runner.output) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            prompt
        }
    }

    /// The command line: type (or copy a command in and carry on typing),
    /// Return runs it, ↑ / ↓ go through what was run before.
    private var prompt: some View {
        HStack(spacing: 8) {
            Text("$").font(.system(.body, design: .monospaced).weight(.bold)).foregroundStyle(.green)
            TextField("Type a command, or copy one in from the list above", text: $custom, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...4)
                .focused($promptFocused)
                .onSubmit { runPrompt() }
                .onKeyPress(.upArrow) { stepHistory(-1) }
                .onKeyPress(.downArrow) { stepHistory(1) }
            if ShellCatalog.isInteractive(custom) {
                Button("Open in Terminal") { ShellRunner.openInTerminal(custom) }
                    .controlSize(.small).help("This program waits for typing or redraws the screen, so it runs in Terminal")
            } else {
                Button(runner.running ? "Running…" : "Run") { runPrompt() }
                    .controlSize(.small)
                    .disabled(custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || runner.running)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(promptFocused ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
    }

    private var history: [String] { historyText.split(separator: "\n").map(String.init) }

    private func toPrompt(_ command: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        custom = command
        historyIndex = nil
        promptFocused = true
    }

    private func runPrompt() {
        let line = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !runner.running else { return }
        if ShellCatalog.isInteractive(line) && !line.hasPrefix("sudo ") { ShellRunner.openInTerminal(line); return }
        var h = history.filter { $0 != line }; h.append(line)
        historyText = h.suffix(100).joined(separator: "\n")
        historyIndex = nil
        let (command, admin) = ShellCatalog.adminForm(line)
        if admin { confirm = (command, true) } else { runner.run(command, admin: false) }
        custom = ""
    }

    private func stepHistory(_ step: Int) -> KeyPress.Result {
        let h = history
        guard !h.isEmpty else { return .ignored }
        var i = (historyIndex ?? h.count) + step
        i = max(0, min(h.count, i))
        historyIndex = i == h.count ? nil : i
        custom = i == h.count ? "" : h[i]
        return .handled
    }

    private func start(_ command: String, admin: Bool, changes: Bool) {
        let c = command.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        if changes || admin { confirm = (c, admin) } else { runner.run(c, admin: false) }
    }

    private func icon(_ c: String) -> String {
        switch c {
        case "Network": return "network"
        case "System": return "desktopcomputer"
        case "Updates": return "arrow.down.circle"
        case "Disk": return "internaldrive"
        default: return "lock.shield"
        }
    }

    private func placeholder(_ f: String) -> String {
        switch f {
        case "Host": return "e.g. apple.com or 1.1.1.1"
        case "Interface": return "e.g. en0"
        case "IP address": return "e.g. 192.168.1.50"
        case "Subnet mask": return "e.g. 255.255.255.0"
        case "Router": return "e.g. 192.168.1.1"
        case "DNS server": return "e.g. 1.1.1.1"
        case "Service": return "e.g. Wi-Fi"
        default: return ""
        }
    }

    /// "Wi-Fi", "Ethernet"… (networksetup's names), for the Service blank.
    nonisolated static func networkServices() -> [String] {
        (Shell.capture("/usr/sbin/networksetup", ["-listallnetworkservices"]) ?? "")
            .split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("An asterisk") }.map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }
    }
}
