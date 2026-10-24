import SwiftUI

/// "Local AI": what local model runtimes are loaded, how much memory / GPU
/// they hold, token throughput where available, and one-click relief
/// (unload a model, optimize, or quit) before the Mac runs out of memory.
struct LocalAIView: View {
    @Environment(AppModel.self) private var model
    @State private var api: [String: AIRuntime] = [:]          // last API results by runtime name
    @State private var tokenHistory: [String: (tokens: UInt64, at: Date)] = [:]
    @State private var commandLines: [pid_t: String] = [:]
    @State private var busy = Set<String>()
    @State private var message: String?
    @State private var installed: [InstalledModel] = InstalledModelsCache.items ?? []

    var body: some View {
        let runtimes = currentRuntimes()
        let mem = model.snapshot.system.memory
        let aiMemory = runtimes.reduce(0) { $0 + $1.memory }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MemoryHeadroom(aiMemory: aiMemory, memory: mem)
                if runtimes.isEmpty {
                    ContentUnavailableView {
                        Label("No Local AI Running", systemImage: "cpu")
                    } description: {
                        Text("Start Ollama, LM Studio, llama.cpp, MLX, Jan, GPT4All, KoboldCpp, LocalAI or vLLM and it will appear here with its loaded models, memory and token speed.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
                ForEach(runtimes) { rt in
                    RuntimeCard(runtime: rt, totalMemory: mem.total, busy: busy, unload: { m in unload(m, rt) })
                }
                InstalledModelsList(models: installed,
                                    loaded: Set(runtimes.flatMap { $0.models.map { $0.name.lowercased() } }))
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationSubtitle(runtimes.isEmpty ? "Nothing running" : "\(runtimes.count) running · \(Fmt.bytes(aiMemory))")
        .alert("Local AI", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
        .task {
            installed = await Task.detached(priority: .utility) { InstalledModels.scan() }.value
            InstalledModelsCache.items = installed
        }
        .task(id: model.interval) {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(max(2, model.interval)))
            }
        }
    }

    /// Live process figures from the latest sample, merged with API details.
    private func currentRuntimes() -> [AIRuntime] {
        LocalAI.detect(model.snapshot.processes) { commandLines[$0] }.map { rt in
            guard let a = api[rt.name] else { return rt }
            var r = rt
            r.api = a.api; r.models = a.models; r.tokensPerSecond = a.tokensPerSecond
            r.tokensGenerated = a.tokensGenerated; r.promptTokens = a.promptTokens
            r.activeRequests = a.activeRequests; r.tokenNote = a.tokenNote
            if a.port != nil { r.port = a.port }
            return r
        }
    }

    private func poll() async {
        // Read command lines only for python / llama processes (needed to spot MLX, vLLM, ports).
        let candidates = model.snapshot.processes.filter {
            let n = $0.name.lowercased()
            return (n.hasPrefix("python") || n.hasPrefix("llama") || n.hasPrefix("koboldcpp")) && commandLines[$0.pid] == nil
        }.map(\.pid)
        if !candidates.isEmpty {
            let found = await Task.detached { candidates.reduce(into: [pid_t: String]()) { $0[$1] = ProcessActions.commandLine(pid: $1) ?? "" } }.value
            commandLines.merge(found) { $1 }
        }
        let runtimes = LocalAI.detect(model.snapshot.processes) { commandLines[$0] }
        var next: [String: AIRuntime] = [:]
        for rt in runtimes {
            let r = await LocalAI.enrich(rt, previous: tokenHistory[rt.name])
            if let t = r.tokensGenerated { tokenHistory[rt.name] = (t, Date()) }
            next[rt.name] = r
        }
        api = next
    }

    private func unload(_ m: AIModel, _ rt: AIRuntime) {
        busy.insert(m.id)
        Task {
            if let err = await LocalAI.unload(m, from: rt) { message = err }
            busy.remove(m.id)
            await poll()
            model.refreshNow()
        }
    }
}

private struct MemoryHeadroom: View {
    let aiMemory: UInt64
    let memory: MemoryStats

    var body: some View {
        let total = Double(max(1, memory.total))
        let other = memory.used > aiMemory ? memory.used - aiMemory : 0
        let tight = memory.pressureLevel != .normal
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory").font(.headline)
                Spacer()
                Text("\(Fmt.bytes(memory.used)) of \(Fmt.bytes(memory.total)) in use")
                    .monospacedDigit().foregroundStyle(.secondary)
                Button { AppModel.shared.showFreeMemory = true } label: {
                    Label("Free Up Memory…", systemImage: "memorychip")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
            StackedBar(parts: [.init(value: Double(aiMemory), color: .pink),
                               .init(value: Double(other), color: .windowsBlue.opacity(0.7))], total: total)
            HStack(spacing: 16) {
                key(.pink, "Local AI", aiMemory, total)
                key(.windowsBlue.opacity(0.7), "Everything else", other, total)
                key(.primary.opacity(0.15), "Free", memory.total > memory.used ? memory.total - memory.used : 0, total)
            }
            if tight {
                Label(aiMemory > 0
                      ? "Your Mac is short on memory. Unloading a model or quitting a runtime below frees it straight away."
                      : "Your Mac is short on memory.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func key(_ c: Color, _ label: String, _ bytes: UInt64, _ total: Double) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(label).foregroundStyle(.secondary)
            Text("\(Fmt.bytes(bytes)) (\(Int((Double(bytes) / total * 100).rounded()))%)").monospacedDigit()
        }
        .font(.caption)
    }
}

private struct RuntimeCard: View {
    @Environment(AppModel.self) private var model
    let runtime: AIRuntime
    let totalMemory: UInt64
    let busy: Set<String>
    let unload: (AIModel) -> Void

    var body: some View {
        let rt = runtime
        let optimized = !rt.pids.isEmpty && rt.pids.allSatisfy(model.optimized.contains)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: rt.iconPath.isEmpty ? IconCache.shared.executable : IconCache.shared.icon(forBundle: rt.iconPath))
                    .resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(rt.name).font(.title3).bold()
                        if optimized { Image(systemName: "leaf.fill").foregroundStyle(.green) }
                    }
                    Text(statusLine(rt)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.setOptimized(pids: rt.pids, !optimized) } label: {
                    Label(optimized ? "Stop Optimizing" : "Optimize", systemImage: optimized ? "leaf.fill" : "leaf")
                }
                .help("Keep it running at the lowest priority on efficiency cores.")
                Menu {
                    Button("Quit") { model.end(pids: rt.pids, force: false) }
                    Button("Force Quit") { model.end(pids: rt.pids, force: true) }
                } label: {
                    Label("Quit", systemImage: "xmark.octagon")
                } primaryAction: {
                    model.end(pids: rt.pids, force: false)
                }
                .fixedSize()
                .help("Quit \(rt.name) and free all of its memory")
            }

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
                GridRow {
                    stat("Memory", "\(Fmt.bytes(rt.memory)) (\(totalMemory > 0 ? Int(Double(rt.memory) / Double(totalMemory) * 100) : 0)% of RAM)")
                    stat("CPU", Fmt.percent(rt.cpu * model.cpuScale) + "%")
                    stat("GPU", Fmt.percent(rt.gpu) + "%")
                    stat("Tokens / sec", rt.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—")
                }
                if rt.tokensGenerated != nil || rt.promptTokens != nil || rt.activeRequests != nil {
                    GridRow {
                        stat("Tokens generated", rt.tokensGenerated.map(Fmt.integer) ?? "—")
                        stat("Prompt tokens read", rt.promptTokens.map(Fmt.integer) ?? "—")
                        stat("Requests running", rt.activeRequests.map(String.init) ?? "—")
                        Color.clear.frame(width: 1, height: 1)
                    }
                }
            }
            if let note = rt.tokenNote {
                Text(note).font(.caption).foregroundStyle(.tertiary)
            }

            if !rt.models.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rt.models.enumerated()), id: \.element.id) { i, m in
                        HStack(spacing: 10) {
                            Image(systemName: "shippingbox").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.name).lineLimit(1).truncationMode(.middle)
                                Text(details(m)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let s = m.sizeBytes { Text(Fmt.bytes(s)).monospacedDigit() }
                            if LocalAI.canUnload(rt) {
                                Button("Unload") { unload(m) }
                                    .disabled(busy.contains(m.id))
                                    .help("Free this model’s memory but keep \(rt.name) running")
                            }
                        }
                        .padding(.horizontal, 10).frame(minHeight: 40)
                        .background(i % 2 == 1 ? Color.primary.opacity(0.035) : .clear)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            } else if rt.api == .online {
                Text("No model loaded.").foregroundStyle(.secondary).font(.callout)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func statusLine(_ rt: AIRuntime) -> String {
        var parts = ["\(rt.pids.count) process\(rt.pids.count == 1 ? "" : "es")"]
        switch rt.api {
        case .online: parts.append("API on port \(rt.port ?? 0)")
        case .offline: parts.append("API not reachable")
        case .unknown: break
        }
        parts.append("\(rt.models.count) model\(rt.models.count == 1 ? "" : "s") loaded")
        return parts.joined(separator: " · ")
    }

    private func details(_ m: AIModel) -> String {
        var parts: [String] = []
        if let p = m.parameters { parts.append(p) }
        if let q = m.quantization { parts.append(q) }
        if let c = m.contextLength { parts.append("\(Fmt.integer(UInt64(c))) token context") }
        if let g = m.gpuBytes, let s = m.sizeBytes, s > 0 { parts.append("\(Int(Double(g) / Double(s) * 100))% on GPU") }
        if let u = m.unloadsAt, u > Date() {
            parts.append("unloads " + u.formatted(.relative(presentation: .named)))
        }
        return parts.isEmpty ? "Loaded" : parts.joined(separator: " · ")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium)).monospacedDigit()
        }
    }
}

@MainActor enum InstalledModelsCache { static var items: [InstalledModel]? }

/// Models downloaded on this Mac (whether or not anything is running).
private struct InstalledModelsList: View {
    let models: [InstalledModel]
    let loaded: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Installed models").font(.headline)
                Text("on this Mac").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !models.isEmpty {
                    Text("\(models.count) · \(Fmt.diskBytes(models.reduce(0) { $0 + $1.sizeBytes })) on disk")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if models.isEmpty {
                Text("No downloaded models found in LM Studio, Ollama or Hugging Face folders.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { i, m in
                        let isLoaded = loaded.contains { $0.contains(m.name.lowercased()) || m.name.lowercased().contains($0) }
                        HStack(spacing: 10) {
                            Image(systemName: "shippingbox").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.name).lineLimit(1).truncationMode(.middle)
                                Text("\(m.source) · \(m.format)").font(.caption).foregroundStyle(.secondary)
                            }
                            if isLoaded {
                                Text("Loaded").font(.caption.weight(.semibold)).foregroundStyle(.green)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.green.opacity(0.15), in: Capsule())
                            }
                            Spacer()
                            Text(Fmt.diskBytes(m.sizeBytes)).monospacedDigit().foregroundStyle(.secondary)
                            Button { ProcessActions.reveal(path: m.path) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless).help("Show in Finder")
                        }
                        .padding(.horizontal, 10).frame(minHeight: 40)
                        .background(i % 2 == 1 ? Color.primary.opacity(0.035) : .clear)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            }
        }
    }
}
