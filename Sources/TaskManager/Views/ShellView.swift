import AppKit
import SwiftUI

/// Shell: categories of ready-made commands (fill in the blanks, run, see the
/// output live), or your own command. Custom holds the person's own saved
/// commands. Opens over the Network page; Pop Out gives it its own window.
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
    @State private var customCommands = ShellCustom.load()
    /// The command being added or edited in the editor sheet.
    @State private var editing: CustomEdit?
    @State private var confirmDelete: ShellCommand?

    struct CustomEdit: Identifiable {
        let id = UUID()
        var original: ShellCommand?     // nil = a new one
        var template = ""
    }

    private var allCommands: [ShellCommand] { ShellCatalog.commands + customCommands }

    var body: some View {
        HStack(spacing: 0) {
            // Categories, like a sidebar.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ShellCatalog.categories + [ShellCustom.category], id: \.self) { c in
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
        .sheet(item: $editing) { e in
            CustomCommandEditor(edit: e, existing: customCommands) { saved in
                customCommands = ShellCustom.upsert(saved, into: customCommands, replacing: e.original?.title)
                ShellCustom.save(customCommands)
                category = ShellCustom.category
                chosen = saved; values = [:]; edited = nil
            }
        }
        .confirmationDialog("Delete “\(confirmDelete?.title ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { c in
            Button("Delete", role: .destructive) {
                customCommands.removeAll { $0.title == c.title }
                ShellCustom.save(customCommands)
                if chosen?.id == c.id { chosen = nil }
            }
        } message: { _ in Text("Only the saved command is removed.") }
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
            VStack(alignment: .leading, spacing: 6) {
                if category == ShellCustom.category {
                    HStack {
                        Text("Your own commands").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { editing = CustomEdit() } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless).help("Add a command of your own")
                    }
                }
                if category == ShellCustom.category && customCommands.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No commands of your own yet.").font(.callout)
                        Text("Add one with +, or type one in the command line below and click Save.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Add a Command…") { editing = CustomEdit() }.controlSize(.small)
                    }
                    .padding(10).frame(width: 280, alignment: .leading)
                    Spacer(minLength: 0)
                } else {
                    commandRows
                }
            }
            .frame(width: 280)
            commandDetail
        }
        .frame(height: 230)
    }

    private var commandRows: some View {
        List(allCommands.filter { $0.category == category }, selection: Binding(get: { chosen?.id }, set: { id in
            chosen = allCommands.first { $0.id == id }; values = [:]; edited = nil
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var commandDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let c = chosen {
                HStack {
                    Text(c.title).font(.headline)
                    Spacer()
                    if c.category == ShellCustom.category {
                        Button { editing = CustomEdit(original: c, template: c.template) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("Edit this command")
                        Button { confirmDelete = c } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete this command")
                    }
                }
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
            Button("Save") { editing = CustomEdit(template: custom) }
                .controlSize(.small)
                .disabled(custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Save this command in Custom, to run it again later")
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
        case ShellCustom.category: return "star"
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

/// Add or edit a command of your own for Shell › Custom.
private struct CustomCommandEditor: View {
    let edit: ShellView.CustomEdit
    let existing: [ShellCommand]
    var onSave: (ShellCommand) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var detail = ""
    @State private var template = ""
    @State private var admin = false
    @State private var changes = false

    var body: some View {
        let draft = ShellCustom.make(title: title, detail: detail, template: template, admin: admin, changes: changes)
        let problem = ShellCustom.problem(draft, existing: existing, replacing: edit.original?.title)
        VStack(alignment: .leading, spacing: 12) {
            Text(edit.original == nil ? "New Command" : "Edit Command").font(.title2.bold())
            Form {
                TextField("Name", text: $title, prompt: Text("e.g. Ping my router"))
                TextField("What it does", text: $detail, prompt: Text("Optional"))
                TextField("Command", text: $template, prompt: Text("e.g. ping -c 3 {Host}"), axis: .vertical)
                    .font(.system(.body, design: .monospaced)).lineLimit(1...4)
                Toggle("Needs my administrator password", isOn: $admin)
                Toggle("Changes my Mac (ask before running)", isOn: Binding(get: { changes || draft.needsAdmin }, set: { changes = $0 }))
                    .disabled(draft.needsAdmin)
            }
            .formStyle(.grouped)
            Text("Put a word in braces, like {Host} or {Folder}, for a blank you fill in each time; what you type there is used only as that value.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !draft.fields.isEmpty {
                Text("Blanks: " + draft.fields.joined(separator: ", ")).font(.caption)
            }
            HStack {
                if let problem, !title.isEmpty || !template.isEmpty { Text(problem).font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft); dismiss() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let c = edit.original {
                title = c.title; detail = c.detail; template = c.template; admin = c.needsAdmin; changes = c.changes
            } else {
                template = edit.template
            }
        }
    }
}
