import SwiftUI

/// Local AI › Assistant: ask a local model about this Mac. Each question goes
/// with Apex's live readings; answers stream in. Nothing leaves the Mac.
struct AssistantView: View {
    @AppStorage("assistantModel") private var chosen = ""
    @State private var server: Assistant.Server?
    @State private var models: [String] = []
    @State private var looking = true
    @State private var messages: [Assistant.Message] = []
    @State private var input = ""
    @State private var answering: Task<Void, Never>?
    @State private var problem: String?
    @State private var starting = false

    private let suggestions = ["Why is my Mac slow right now?", "What's using the most memory?",
                               "How can I free up disk space?", "Is my battery healthy?"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if server == nil {
                noServer
            } else {
                chat
                Divider()
                composer
            }
        }
        .task { await connect() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text("Assistant").font(.headline)
            if let server { Text("via \(server.name)").foregroundStyle(.secondary) }
            Spacer()
            if !models.isEmpty {
                Picker("Model", selection: $chosen) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 280)
                .help("The model Apex asks. Bigger models answer better; smaller ones answer faster.")
            }
            Button { Task { await connect() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Look for the model server again")
            if !messages.isEmpty {
                Button("New Chat") { answering?.cancel(); messages = []; problem = nil }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var noServer: some View {
        VStack(spacing: 12) {
            if looking {
                ProgressView("Looking for LM Studio or Ollama on this Mac…").controlSize(.small)
            } else {
                Image(systemName: "sparkles.rectangle.stack").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("No local model server is running").font(.title3.weight(.semibold))
                Text("The assistant uses a model on this Mac, through LM Studio or Ollama. Nothing you ask leaves the Mac.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
                HStack {
                    Button(starting ? "Starting…" : "Start LM Studio’s Server") { startLMStudio() }
                        .buttonStyle(.borderedProminent).disabled(starting)
                    Button("Look Again") { Task { await connect() } }
                }
                Text("Ollama: open the Ollama app; it starts its server by itself.").font(.caption).foregroundStyle(.tertiary)
                if let problem { Text(problem).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 420) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Ask about your Mac").font(.title3.weight(.semibold))
                            Text("The assistant sees Apex’s live readings: CPU, memory, disk, network, battery, the busiest apps and recent alerts. It only helps with your Mac and its system utilities.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            ForEach(suggestions, id: \.self) { q in
                                Button { send(q) } label: { Label(q, systemImage: "text.bubble") }.buttonStyle(.link)
                            }
                        }
                        .padding(.vertical, 20)
                    }
                    ForEach(messages) { m in bubble(m).id(m.id) }
                    if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                .padding(16)
            }
            .onChange(of: messages.last?.text) { if let id = messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
    }

    private func bubble(_ m: Assistant.Message) -> some View {
        HStack {
            if m.role == .user { Spacer(minLength: 60) }
            Text(m.text.isEmpty ? "…" : (try? AttributedString(markdown: m.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(m.text))
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(m.role == .user ? Color.accentColor : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(m.role == .user ? Color.white : .primary)
            if m.role == .assistant { Spacer(minLength: 60) }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask about your Mac…", text: $input, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4)
                .onSubmit { send(input) }
            if answering != nil {
                Button { answering?.cancel(); answering = nil } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).help("Stop")
            } else {
                Button { send(input) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || chosen.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }

    private func connect() async {
        looking = true; problem = nil
        if let (s, list) = await Assistant.find() {
            server = s; models = list
            if !list.contains(chosen) { chosen = list.first ?? "" }
            if list.isEmpty { problem = "\(s.name) is running but has no models. Download one in \(s.name) first." }
        } else {
            server = nil; models = []
        }
        looking = false
    }

    private func startLMStudio() {
        starting = true; problem = nil
        Task {
            problem = await Task.detached { Assistant.startLMStudio() }.value
            try? await Task.sleep(for: .seconds(2))
            await connect()
            starting = false
        }
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let server, !chosen.isEmpty, answering == nil else { return }
        input = ""; problem = nil
        messages.append(.init(role: .user, text: q))
        let history = messages
        messages.append(.init(role: .assistant, text: ""))
        let context = AssistantContext.current(), model = chosen
        answering = Task {
            do {
                try await Assistant.ask(server, model: model, history: history, context: context) { piece in
                    Task { @MainActor in
                        if let i = messages.indices.last { messages[i].text += piece }
                    }
                }
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
            if messages.last?.role == .assistant, messages.last?.text.isEmpty == true { messages.removeLast() }
            answering = nil
        }
    }
}
