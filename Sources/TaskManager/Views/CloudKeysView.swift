import SwiftUI

/// Assistant › Cloud API, top bar: which key answers (by group) and its model.
struct CloudKeyMenu: View {
    let store: CloudKeyStore
    let active: CloudKey
    let manage: () -> Void

    var body: some View {
        Menu {
            ForEach(store.grouped, id: \.group) { g in
                Section(g.group.isEmpty ? "Keys" : g.group) {
                    ForEach(g.keys) { k in
                        keyButton(k)
                    }
                }
            }
            if !active.models.isEmpty {
                Divider()
                Menu("Model for “\(active.title)”") {
                    ForEach(active.models, id: \.self) { m in
                        Button(m + (m == active.model ? "  ✓" : "")) { store.setModel(m, for: active.id) }
                    }
                }
            }
            Divider()
            Button("Manage Keys…", action: manage)
        } label: {
            HStack(spacing: 4) {
                Text(active.title).lineLimit(1)
                if !active.model.isEmpty { Text("· " + active.model).foregroundStyle(.secondary).lineLimit(1) }
            }
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .frame(maxWidth: 220)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help("Which key answers, and its model. Keys are grouped the way you named them.")
    }

    private func keyButton(_ k: CloudKey) -> some View {
        let mark = k.id == active.id ? "  ✓" : ""
        let detail = k.model.isEmpty ? k.provider.name : "\(k.provider.name) · \(k.model)"
        return Button { store.activeID = k.id } label: {
            Text(k.title + mark)
            Text(detail)
        }
    }
}

/// Manage Keys: every saved key under its group; add, edit (name, group,
/// provider, key, model) or remove one.
struct CloudKeysSheet: View {
    let chat: AssistantChat
    let done: () -> Void
    @State private var editing: CloudKey?
    @State private var isNew = false

    private var store: CloudKeyStore { chat.keys }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("API Keys", systemImage: "key.fill").font(.headline)
                Spacer()
                if editing == nil {
                    Button { startNew() } label: { Label("Add Key", systemImage: "plus") }
                    Button("Done", action: done).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            if let k = editing {
                CloudKeyEditor(chat: chat, key: k, isNew: isNew, close: { withAnimation(.easeInOut(duration: 0.2)) { editing = nil } })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if store.keys.isEmpty {
                VStack(spacing: 12) {
                    AssistantOrb(size: 56)
                    Text("No keys yet").font(.title3.weight(.semibold))
                    Text("Add a key from any AI service. Give it a name, like the project it’s for, and a group to keep keys together.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    Button { startNew() } label: { Label("Add Key", systemImage: "plus") }.controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.grouped, id: \.group) { g in
                        Section(g.group.isEmpty ? "No group" : g.group) {
                            ForEach(g.keys) { k in row(k) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 560, height: 560)
        .animation(.easeInOut(duration: 0.2), value: editing?.id)
        .onAppear { if store.keys.isEmpty { startNew() } }
    }

    private func row(_ k: CloudKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: k.id == store.active?.id ? "checkmark.circle.fill" : "key")
                .foregroundStyle(k.id == store.active?.id ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(k.title).font(.body.weight(.medium))
                Text(k.provider.name + (k.model.isEmpty ? "" : " · \(k.model)")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if k.id != store.active?.id {
                Button("Use") { store.activeID = k.id }.buttonStyle(.borderless)
            }
            Button("Edit") { isNew = false; editing = k }.buttonStyle(.borderless)
            Button(role: .destructive) { store.remove(k.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Remove this key from Apex (and from the Keychain)")
        }
        .padding(.vertical, 3)
    }

    private func startNew() {
        isNew = true
        editing = CloudKey(name: "", provider: .openai)
    }
}

/// One key: service, name, group, the key itself, and the model.
private struct CloudKeyEditor: View {
    let chat: AssistantChat
    @State var key: CloudKey
    let isNew: Bool
    let close: () -> Void
    @State private var secret = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Service", selection: $key.provider) {
                        ForEach(AIProvider.allCases) { p in Text(p.name).tag(p) }
                    }
                    if key.provider == .custom {
                        TextField("API address", text: Binding(get: { key.customBase ?? "" }, set: { key.customBase = $0 }),
                                  prompt: Text("https://example.com/v1"))
                    }
                    SecureField("API key", text: $secret, prompt: Text(isNew ? "Paste the key" : "Saved — paste a new one to replace it"))
                    if let page = key.provider.keysPage {
                        Link("Get a key from \(key.provider.shortName)", destination: page).font(.callout)
                    }
                } header: {
                    Text("Key")
                }
                Section {
                    TextField("Name", text: $key.name, prompt: Text("e.g. Client X project"))
                    HStack {
                        TextField("Group", text: Binding(get: { key.group ?? "" }, set: { key.group = $0 }), prompt: Text("e.g. Work (optional)"))
                        if !chat.keys.groups.isEmpty {
                            Menu {
                                ForEach(chat.keys.groups, id: \.self) { g in Button(g) { key.group = g } }
                            } label: { Image(systemName: "folder") }
                                .menuStyle(.borderlessButton).fixedSize().help("Use a group you already have")
                        }
                    }
                } header: {
                    Text("Name and Group")
                } footer: {
                    Text("Names and groups are only for you, to tell keys apart.").font(.caption).foregroundStyle(.secondary)
                }
                if !key.models.isEmpty {
                    Section("Model") {
                        Picker("Answers with", selection: $key.model) {
                            ForEach(key.models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                Section {
                    Label("The key is kept in this Mac’s Keychain and only ever sent to \(key.provider.shortName).", systemImage: "lock.fill")
                    Label("Answers are billed to that account.", systemImage: "creditcard")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle.fill").font(.callout).foregroundStyle(.orange).lineLimit(3)
                }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(action: save) {
                    HStack(spacing: 6) {
                        if checking { ProgressView().controlSize(.small) }
                        Text(checking ? "Checking…" : isNew ? "Add Key" : "Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checking || (isNew && secret.isEmpty))
            }
            .padding(14)
        }
        .onChange(of: key.provider) { _, _ in key.models = []; key.model = "" }
    }

    private func save() {
        checking = true; problem = nil
        Task {
            problem = await chat.save(key, secret: secret.isEmpty ? nil : secret)
            checking = false
            if problem == nil { close() }
        }
    }
}
