import AppKit
import ProcessIdentityCore
import SwiftUI

/// Assistant: ask about this Mac (Apex Agent, a local model, Lumen AI, or any
/// cloud AI with the user's own keys). The same conversation shows on the
/// Assistant page and in its own window (`inWindow`), which has a glass
/// background and no title bar.
struct AssistantView: View {
    var inWindow = false
    @Environment(\.openWindow) private var openWindow
    @AppStorage("assistantReadings") private var readings = true
    @State private var chat = AssistantChat.shared
    @State private var input = ""
    @State private var changingKey = false
    @State private var showingModels = false
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            if inWindow {
                GlassBackground().ignoresSafeArea()
                AuroraGlow(active: chat.answering != nil).ignoresSafeArea().allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                topBar
                if chat.mode == .lumen && !(Lumen.isLive && chat.lumen.hasKey) {
                    ScrollView { LumenConnect(account: chat.lumen) { chat.mode = $0 }.padding(.vertical, 40) }.scrollIndicators(.never)
                } else if chat.mode == .local && chat.localServer == nil {
                    ScrollView { LocalConnect(chat: chat, showModels: { showingModels = true }).padding(.vertical, 40) }.scrollIndicators(.never)
                } else if chat.mode == .cloud && !chat.hasKey {
                    ScrollView { CloudConnect { changingKey = true }.padding(.vertical, 40) }.scrollIndicators(.never)
                } else {
                    conversation
                    composer
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .sheet(isPresented: $changingKey) {
            CloudKeysSheet(chat: chat, done: { changingKey = false })
        }
        .animation(.easeInOut(duration: 0.25), value: chat.mode)
        // Local AI: look for a model server when the mode opens.
        .task(id: chat.mode) { if chat.mode == .local { await chat.findLocal() } }
        // The models on this Mac (runtimes, loaded and installed models), in one place with Local AI.
        .sheet(isPresented: $showingModels) {
            VStack(spacing: 0) {
                HStack {
                    Label("Models on this Mac", systemImage: "square.stack.3d.up").font(.headline)
                    Spacer()
                    Button("Done") { showingModels = false; Task { await chat.findLocal() } }.keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                Divider()
                LocalAIRuntimesView()
            }
            .frame(width: 820, height: 620)
        }
        .task {
            // Test switch: APEX_ASSISTANT_ASK asks a question when the window opens (no typing needed).
            // APEX_OPEN=assistantkeys opens Manage Keys.
            if inWindow, ProcessInfo.processInfo.environment["APEX_OPEN"] == "assistantkeys" { changingKey = true }
            if inWindow, let q = ProcessInfo.processInfo.environment["APEX_ASSISTANT_ASK"], chat.messages.isEmpty, chat.mode != .cloud || chat.hasKey {
                try? await Task.sleep(for: .seconds(1)); send(q)
            }
        }
        .onChange(of: chat.lastUnanswered) { if let q = chat.lastUnanswered, input.isEmpty { input = q } }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 6) {
            if inWindow { Color.clear.frame(width: 64, height: 1) }   // the window buttons
            Spacer(minLength: 0)
            ModePicker(mode: Binding(get: { chat.mode }, set: { chat.mode = $0 }))
                .disabled(chat.answering != nil)
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                if chat.mode == .cloud, let active = chat.keys.active {
                    CloudKeyMenu(store: chat.keys, active: active, manage: { changingKey = true })
                }
                if chat.mode == .local, chat.localServer != nil {
                    Menu {
                        ForEach(chat.localModels, id: \.self) { m in
                            Button(m + (m == chat.localModel ? "  ✓" : "")) { chat.localModel = m }
                        }
                    } label: {
                        Text(chat.localModel.isEmpty ? "No model" : chat.localModel)
                            .font(.system(.caption, design: .rounded).weight(.semibold)).lineLimit(1)
                            .frame(maxWidth: 160)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    .help("The model that answers, via \(chat.localServer?.name ?? "the local server"). Bigger models answer better; smaller ones answer faster.")
                }
                if chat.mode == .local {
                    barButton("square.stack.3d.up", "Models on this Mac: which are loaded, how much memory they use, and every model installed") { showingModels = true }
                }
                if chat.mode != .agent {
                    barButton(readings ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent",
                              readings ? "Your Mac’s readings go with each question. Click to stop sending them."
                                       : "Readings are off: only your question is sent. Click to send this Mac’s readings too.",
                              tint: readings ? .accentColor : .secondary) { readings.toggle() }
                }
                if chat.mode != .lumen {
                    barButton("square.and.pencil", "New chat") { chat.newChat(); input = ""; focused = true }
                        .disabled(chat.messages.isEmpty && chat.answering == nil)
                }
                Menu {
                    Button(chat.hasKey ? "Manage Keys…" : "Add API Key…") { changingKey = true }
                    if let p = chat.keys.active?.provider, p.billingPage != nil || p.privacyPage != nil {
                        Divider()
                        if let u = p.billingPage { Link("\(p.shortName) Usage and Billing", destination: u) }
                        if let u = p.privacyPage { Link("\(p.shortName) Privacy Policy", destination: u) }
                    }
                    if chat.lumen.hasKey {
                        Divider()
                        if let u = Lumen.accountPage { Link("Lumen Account (CyberNet Labs)", destination: u) }
                        Button("Sign Out of Lumen AI", role: .destructive) { chat.lumen.signOut() }
                    }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(.secondary).padding(.horizontal, 4)
                    .help("API keys and accounts")
                if !inWindow {
                    barButton("macwindow.on.rectangle", "Open the assistant in its own window") { openWindow(id: "assistant") }
                }
            }
            .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.top, inWindow ? 10 : 8).padding(.bottom, 6)
    }

    private func barButton(_ symbol: String, _ help: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 22) {
                    if chat.messages.isEmpty {
                        AssistantWelcome(mode: chat.mode) { send($0) }.padding(.top, 24)
                    }
                    ForEach(chat.messages) { m in
                        MessageRow(message: m, working: chat.answering != nil && m.id == chat.messages.last?.id,
                                   perform: perform, tryLumen: { tryLumen(after: m) })
                            .id(m.id)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    if let p = chat.problem {
                        Label(p, systemImage: "exclamationmark.circle.fill")
                            .font(.callout).foregroundStyle(.orange)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: 700)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: chat.messages.count)
            }
            .scrollIndicators(.automatic)
            .onChange(of: chat.messages.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat.messages.count) { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    // MARK: Composer

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.answering == nil }

    private var composer: some View {
        VStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(chat.mode == .agent ? "Ask a question about your Mac" : "Ask anything about your Mac", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { send(input) }
                    .padding(.vertical, 6)
                if chat.answering != nil {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(Circle().fill(.primary.opacity(0.75)))
                    }
                    .buttonStyle(.plain).help("Stop")
                } else {
                    Button { send(input) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(canSend ? AnyShapeStyle(AssistantStyle.gradient) : AnyShapeStyle(Color.secondary.opacity(0.35))))
                    }
                    .buttonStyle(.plain).disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (Return)")
                }
            }
            .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(GlowBorder(active: chat.answering != nil, focused: focused))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            Text(footnote)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 700)
        .padding(.horizontal, 24).padding(.bottom, 14).padding(.top, 4)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
    }

    private var footnote: String {
        switch chat.mode {
        case .agent: return "Apex Agent answers on this Mac. Nothing you ask is sent anywhere."
        case .local: return "\(chat.localModel.isEmpty ? "A local model" : chat.localModel) answers on this Mac, through \(chat.localServer?.name ?? "a local server"). Nothing leaves the Mac."
        case .lumen: return readings ? "Your question and this Mac’s readings go to Lumen AI (CyberNet Labs)." : "Your question goes to Lumen AI (CyberNet Labs)."
        case .cloud:
            let to = chat.keys.active.map { $0.provider == .custom ? $0.title : $0.provider.shortName } ?? "the service"
            return readings ? "Your question and this Mac’s readings go to \(to). AI can make mistakes."
                            : "Your question goes to \(to). AI can make mistakes."
        }
    }

    /// An Apex Agent button: open the page or sheet it names.
    private func perform(_ a: ApexAgent.Action) {
        switch a {
        case .freeMemory: app.showFreeMemory = true
        case .clean: app.openStorage(volume: nil)
        case .page(let p):
            UserDefaults.standard.set(p, forKey: "perfItem")
            app.section = .performance
        case .section(let s): if let sec = AppSection(rawValue: s) { app.section = sec }
        case .quitApps(let targets, let names, let force):
            // Only the apps the answer was about: each is checked against its
            // identity first, so one that quit (and whose PID was reused) is left alone.
            let named = Dictionary(zip(targets, names), uniquingKeysWith: { a, _ in a })
            let report = ProcessActions.end(targets, force: force)
            let skipped = AppModel.message(for: report, names: named, verb: "quit")
            Task {
                try? await Task.sleep(for: .seconds(force ? 1 : 3))
                let still = targets.filter { $0.check() == .same }.compactMap { named[$0] }
                let quit = report.done.count - still.count
                var text = still.isEmpty && report.refused.isEmpty
                    ? "Done: quit \(names.count == 1 ? names[0] : "\(names.count) apps")."
                    : "Quit \(max(0, quit)) of \(names.count)."
                if !still.isEmpty {
                    text += " Still open: " + still.joined(separator: ", ")
                        + (force ? "." : ". They may be asking you to save; or say “force quit” to close them anyway.")
                }
                if let skipped { text += " " + skipped }
                chat.agentSays(text)
            }
            return
        case .stopProcesses(let targets, let names):
            // Your own processes only, each still the one the answer named.
            let uid = getuid()
            let named = Dictionary(zip(targets, names), uniquingKeysWith: { a, _ in a })
            var report = ProcessActions.Report()
            for t in targets {
                guard let p = AppModel.shared.process(t.pid), p.identity == t, p.uid == uid else {
                    report.add(t, t.check() == .exited ? .exited : .unverifiable); continue
                }
                report.add(t, ProcessSignal.send(SIGTERM, to: t))
            }
            let stopped = report.done.count
            var text = stopped == targets.count ? "Stopped \(names.count == 1 ? names[0] : "\(names.count) processes")."
                                                : "Stopped \(stopped) of \(targets.count). I can only stop your own processes."
            if let skipped = AppModel.message(for: report, names: named, verb: "stop") { text += " " + skipped }
            chat.agentSays(text)
            return
        }
        app.openMainWindow?()
    }

    /// "Try Lumen AI" under an answer the agent couldn't give: ask it there.
    private func tryLumen(after m: Assistant.Message) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { chat.mode = .lumen }
    }

    private func send(_ text: String) {
        guard chat.answering == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input = ""
        chat.lastUnanswered = nil
        chat.send(text, readings: readings)
    }
}

// MARK: - Pieces

enum AssistantStyle {
    static let colors: [Color] = [Color(red: 0.36, green: 0.42, blue: 1.0), Color(red: 0.66, green: 0.36, blue: 0.98),
                                  Color(red: 0.98, green: 0.38, blue: 0.62), Color(red: 1.0, green: 0.62, blue: 0.3),
                                  Color(red: 0.3, green: 0.78, blue: 1.0)]
    static let gradient = LinearGradient(colors: [colors[0], colors[1], colors[2]], startPoint: .topLeading, endPoint: .bottomTrailing)
    static var angular: AngularGradient { AngularGradient(colors: colors + [colors[0]], center: .center) }
}

/// The assistant's mark: a soft glowing orb that turns while it works.
struct AssistantOrb: View {
    var size: CGFloat = 64
    var active = false
    @State private var turn = false

    var body: some View {
        ZStack {
            Circle().fill(AssistantStyle.angular).blur(radius: size * 0.28).opacity(0.75)
            Circle().fill(AssistantStyle.angular)
                .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .init(x: 0.35, y: 0.3),
                                                      startRadius: 0, endRadius: size * 0.6)))
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: max(0.5, size / 80)))
            Image(systemName: "sparkle").font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 2)
                .rotationEffect(.degrees(turn ? -360 : 0))
        }
        .rotationEffect(.degrees(turn ? 360 : 0))
        .frame(width: size, height: size)
        .onChange(of: active, initial: true) {
            if active {
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { turn = true }
            } else {
                withAnimation(.easeOut(duration: 0.6)) { turn = false }
            }
        }
    }
}

/// The empty chat: a greeting and a few good first questions.
private struct AssistantWelcome: View {
    let mode: Assistant.Mode
    let ask: (String) -> Void
    private var ideas: [(String, String, String)] {
        switch mode {
        case .agent: [("tortoise", "Why is my Mac slow?", "Checks what’s busy right now"),
                      ("internaldrive", "My disk is full", "What’s safe to clear"),
                      ("battery.75percent", "Is my battery healthy?", "Health and cycles"),
                      ("thermometer.medium", "Why is my Mac hot?", "Heat and fans"),
                      ("wifi", "My Wi-Fi keeps disconnecting", "Step-by-step fixes"),
                      ("questionmark.app", "What is kernel_task?", "Common processes explained")]
        default: [("tortoise", "Why is my Mac slow?", "Looks at what’s busy right now"),
                  ("memorychip", "What’s using my memory?", "Finds the biggest apps"),
                  ("internaldrive", "Free up disk space", "What’s safe to clear"),
                  ("battery.75percent", "Is my battery healthy?", "Health, cycles and charging")]
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            AssistantOrb(size: 72)
            VStack(spacing: 6) {
                Text(mode == .agent ? "Apex Agent" : mode == .lumen ? "Lumen AI" : greeting)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(mode == .cloud ? "Ask me anything about your Mac. I can see what Apex sees." : mode.detail)
                    .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(ideas, id: \.1) { idea in IdeaCard(symbol: idea.0, title: idea.1, detail: idea.2) { ask(idea.1) } }
            }
            .frame(maxWidth: 560)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}

private struct IdeaCard: View {
    let symbol: String, title: String, detail: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AssistantStyle.gradient).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(hover ? 0.25 : 0.1)))
            .scaleEffect(hover ? 1.015 : 1)
            .shadow(color: .black.opacity(hover ? 0.12 : 0.04), radius: hover ? 10 : 4, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

private struct MessageRow: View {
    let message: Assistant.Message
    let working: Bool
    var perform: (ApexAgent.Action) -> Void = { _ in }
    var tryLumen: () -> Void = {}

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .font(.system(size: 14)).foregroundStyle(.white).textSelection(.enabled)
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .background(AssistantStyle.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: AssistantStyle.colors[1].opacity(0.25), radius: 8, y: 3)
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                AssistantOrb(size: 24, active: working)
                VStack(alignment: .leading, spacing: 8) {
                    if message.text.isEmpty {
                        ThinkingLine(summary: message.thinking)
                    } else {
                        RichText(text: message.text)
                    }
                    if !message.actions.isEmpty || message.suggestLumen {
                        HStack(spacing: 8) {
                            ForEach(message.actions, id: \.self) { a in
                                Button { perform(a) } label: { Label(a.title, systemImage: a.symbol) }
                                    .buttonStyle(ChipStyle(prominent: a.acts))
                            }
                            if message.suggestLumen {
                                Button(action: tryLumen) { Label("Try Lumen AI", systemImage: "sparkles") }
                                    .buttonStyle(ChipStyle(prominent: true))
                            }
                        }
                        .padding(.top, 2)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
        }
    }
}

/// "Thinking" with a light sweeping across it, and the latest line of the
/// model's thinking summary underneath.
private struct ThinkingLine: View {
    let summary: String
    @State private var sweep = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Thinking")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                .overlay(
                    LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 50).offset(x: sweep ? 70 : -70)
                        .mask(Text("Thinking").font(.system(size: 14, weight: .medium)))
                )
                .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { sweep = true } }
            if let last = summary.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                Text(String(last).replacingOccurrences(of: "**", with: ""))
                    .font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(2)
                    .transition(.opacity).id(last)
            }
        }
        .animation(.easeOut(duration: 0.3), value: summary)
    }
}

/// Markdown answers: paragraphs, headings, bullet and numbered lists, code
/// blocks, and inline bold/italic/code/links.
struct RichText: View {
    let text: String

    enum Block: Equatable {
        case paragraph(String), heading(String), bullet(String), numbered(String, String), code(String)
    }

    /// Pure: tested.
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = [], code: [String]? = nil
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush(); out.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush(); out.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), dot > line.startIndex,
                      line[..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].hasPrefix(" ") {
                flush(); out.append(.numbered(String(line[..<dot]), line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
            } else {
                para.append(line)
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }   // still streaming
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, b in
                switch b {
                case .paragraph(let s): inline(s)
                case .heading(let s): inline(s, weight: .semibold, size: 15).padding(.top, 4)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(AssistantStyle.gradient).frame(width: 5, height: 5).offset(y: -2)
                        inline(s)
                    }
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(n).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(AssistantStyle.colors[1])
                            .frame(minWidth: 14, alignment: .trailing)
                        inline(s)
                    }
                case .code(let s):
                    Text(s).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func inline(_ s: String, weight: Font.Weight = .regular, size: CGFloat = 14) -> some View {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
            .font(.system(size: size, weight: weight)).lineSpacing(3).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The composer's edge: a quiet hairline, a soft colour when focused, and a
/// turning rainbow while an answer comes in.
private struct GlowBorder: View {
    let active: Bool, focused: Bool
    @State private var angle = 0.0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        ZStack {
            shape.strokeBorder(.white.opacity(0.14), lineWidth: 1)
            shape.strokeBorder(AngularGradient(colors: AssistantStyle.colors + [AssistantStyle.colors[0]], center: .center, angle: .degrees(angle)),
                               lineWidth: active ? 1.6 : 1.2)
                .opacity(active ? 1 : focused ? 0.55 : 0)
            if active {
                shape.strokeBorder(AngularGradient(colors: AssistantStyle.colors + [AssistantStyle.colors[0]], center: .center, angle: .degrees(angle)), lineWidth: 5)
                    .blur(radius: 8).opacity(0.6)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.3), value: focused)
        .onChange(of: active, initial: true) {
            if active {
                withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { angle = 360 }
            } else {
                withAnimation(.easeOut(duration: 0.4)) { angle = 0 }
            }
        }
    }
}

/// Soft colour behind the glass, brighter while an answer comes in.
private struct AuroraGlow: View {
    let active: Bool

    var body: some View {
        GeometryReader { g in
            ZStack {
                Circle().fill(AssistantStyle.colors[0]).frame(width: g.size.width * 0.7).offset(x: -g.size.width * 0.32, y: -g.size.height * 0.42)
                Circle().fill(AssistantStyle.colors[2]).frame(width: g.size.width * 0.6).offset(x: g.size.width * 0.38, y: -g.size.height * 0.3)
                Circle().fill(AssistantStyle.colors[1]).frame(width: g.size.width * 0.8).offset(x: 0, y: g.size.height * 0.58)
            }
            .frame(width: g.size.width, height: g.size.height)
            .blur(radius: 120)
            .opacity(active ? 0.32 : 0.18)
            .animation(.easeInOut(duration: 1.2), value: active)
            .drawingGroup()
        }
    }
}

/// The window's frosted background (shows the desktop softly through it).
private struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// A rounded chip button under an answer.
private struct ChipStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background {
                if prominent { Capsule().fill(AssistantStyle.gradient) }
                else { Capsule().fill(.thinMaterial).overlay(Capsule().strokeBorder(.white.opacity(0.14))) }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// The three-way switch in the middle: Apex Agent, Lumen AI, Cloud API.
private struct ModePicker: View {
    @Binding var mode: Assistant.Mode
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Assistant.Mode.allCases) { m in
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { mode = m } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.symbol).font(.system(size: 11, weight: .semibold))
                        Text(m.title).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        if m == .lumen && !Lumen.isLive {
                            Text("SOON").font(.system(size: 8.5, weight: .heavy, design: .rounded))
                                .padding(.horizontal, 4).padding(.vertical, 1.5)
                                .background(Capsule().fill(mode == m ? Color.white.opacity(0.25) : Color.secondary.opacity(0.2)))
                        }
                    }
                    .foregroundStyle(mode == m ? Color.white : Color.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background {
                        if mode == m {
                            Capsule().fill(AssistantStyle.gradient)
                                .shadow(color: AssistantStyle.colors[1].opacity(0.35), radius: 6, y: 2)
                                .matchedGeometryEffect(id: "mode", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(m.detail)
            }
        }
        .padding(3)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .fixedSize()
    }
}

/// Cloud API without a key: one button to connect it.
private struct CloudConnect: View {
    let connect: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            AssistantOrb(size: 72)
            Text("Use your own AI service").font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("Add an API key from OpenAI, Anthropic, Google, Mistral, OpenRouter or any OpenAI-compatible service. Name each key (for example after a project) and group them. Answers are billed to that account. Apex Agent works without a key.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            Button(action: connect) {
                Label("Add API Key…", systemImage: "key.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(AssistantStyle.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Lumen AI (CyberNet Labs): choose a monthly plan or API access, then paste
/// the Lumen key from the account. Until the service is live, it says so and
/// points to what works today.
private struct LumenConnect: View {
    let account: LumenAccount
    let switchTo: (Assistant.Mode) -> Void
    @State private var access: Lumen.Access = .plan
    @State private var key = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 16) {
            AssistantOrb(size: 84, active: checking || !Lumen.isLive)
            Text(Lumen.isLive ? "Lumen AI" : "Lumen AI is coming soon").font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("Apex’s own cloud AI, by CyberNet Labs. It sees what’s going on across your Mac, remembers what’s been tried, and works through problems that keep coming back.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                ForEach(Lumen.Access.allCases) { a in option(a) }
            }
            .fixedSize(horizontal: false, vertical: true)     // both cards as tall as the taller one
            .frame(maxWidth: 480)
            if Lumen.isLive {
                VStack(spacing: 10) {
                    if let page = access.page {
                        Link(access == .plan ? "Choose a plan at CyberNet Labs" : "Buy API access at CyberNet Labs", destination: page).font(.callout)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill").foregroundStyle(.secondary)
                        SecureField("Paste the Lumen key from your CyberNet Labs account", text: $key)
                            .textFieldStyle(.plain).font(.system(size: 14)).onSubmit(connect)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button(action: connect) {
                        HStack(spacing: 8) {
                            if checking { ProgressView().controlSize(.small).tint(.white) }
                            Text(checking ? "Checking…" : "Connect").font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(AssistantStyle.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .opacity(key.isEmpty ? 0.5 : 1)
                    }
                    .buttonStyle(.plain).disabled(key.isEmpty || checking)
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.circle.fill").font(.callout).foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 400)
            } else {
                Text("Plans and API access open when CyberNet Labs launches Lumen AI. Until then, Apex Agent answers common questions on this Mac, and Cloud API uses your own keys.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack(spacing: 10) {
                    Button { switchTo(.agent) } label: {
                        Label("Ask Apex Agent", systemImage: "cpu")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(AssistantStyle.gradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { switchTo(.cloud) } label: {
                        Label("Use Cloud API", systemImage: "key.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(.thinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity)
    }

    /// One way to pay: a card, selectable once the service is live.
    private func option(_ a: Lumen.Access) -> some View {
        let on = access == a && Lumen.isLive
        return Button { access = a } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(a.title, systemImage: a.symbol).font(.system(size: 14, weight: .semibold))
                Text(a.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(on ? AnyShapeStyle(AssistantStyle.gradient) : AnyShapeStyle(Color.white.opacity(0.12)), lineWidth: on ? 2 : 1))
        }
        .buttonStyle(.plain)
        .disabled(!Lumen.isLive)
        .help(Lumen.isLive ? a.detail : "Opens when CyberNet Labs launches Lumen AI")
    }

    private func connect() {
        guard !key.isEmpty, !checking else { return }
        checking = true; problem = nil
        Task {
            problem = await account.connect(key: key, access: access)
            checking = false
            if problem == nil { key = "" }
        }
    }
}

/// Local AI without a model server running: start one, or look again.
private struct LocalConnect: View {
    let chat: AssistantChat
    let showModels: () -> Void
    @State private var starting = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 16) {
            AssistantOrb(size: 72, active: chat.lookingForLocal || starting)
            if chat.lookingForLocal {
                Text("Looking for a model on this Mac…").font(.system(size: 20, weight: .semibold, design: .rounded))
            } else {
                Text("No local model is running").font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Local AI uses a model on this Mac, through LM Studio or Ollama. Nothing you ask leaves the Mac. Start one, then look again.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(action: start) {
                        Label(starting ? "Starting…" : "Start LM Studio’s Server", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(AssistantStyle.gradient, in: Capsule())
                    }
                    .buttonStyle(.plain).disabled(starting)
                    Button { Task { await chat.findLocal() } } label: {
                        Label("Look Again", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(.thinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
                Text("Ollama: open the Ollama app; it starts its server by itself.").font(.caption).foregroundStyle(.tertiary)
                Button("See the models on this Mac", action: showModels).buttonStyle(.link).font(.callout)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle.fill").font(.callout).foregroundStyle(.orange)
                        .multilineTextAlignment(.center).frame(maxWidth: 440)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func start() {
        starting = true; problem = nil
        Task {
            problem = await Task.detached { LocalChat.startLMStudio() }.value
            try? await Task.sleep(for: .seconds(2))
            await chat.findLocal()
            starting = false
        }
    }
}
