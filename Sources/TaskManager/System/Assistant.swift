import DetectionCore
import Foundation

/// The Apex assistant: a local model (LM Studio, Ollama, or any server with
/// the same OpenAI-style API on this Mac) answering questions about this Mac,
/// with Apex's live readings attached to each question. Nothing leaves the Mac.
enum Assistant {
    struct Server: Equatable, Sendable {
        let name: String         // "LM Studio", "Ollama"
        let base: String         // e.g. http://127.0.0.1:1234/v1
    }

    struct Message: Identifiable, Equatable, Sendable {
        enum Role: String, Sendable { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    static let knownServers: [Server] = [
        .init(name: "LM Studio", base: "http://127.0.0.1:1234/v1"),
        .init(name: "Ollama", base: "http://127.0.0.1:11434/v1"),
    ]

    /// The first local server that answers, with its models.
    static func find() async -> (Server, [String])? {
        for s in knownServers {
            if let models = await models(s) { return (s, models) }
        }
        return nil
    }

    static func models(_ s: Server) async -> [String]? {
        guard let url = URL(string: s.base + "/models") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 1.5)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseModels(data)
    }

    /// `/v1/models` → ids, chat models only (no embedding models). Pure: tested.
    static func parseModels(_ data: Data) -> [String] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = o["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }.filter { !$0.lowercased().contains("embed") }.sorted()
    }

    /// What the assistant is for, and how it should answer.
    static let instructions = """
    You are the assistant inside Apex Activity Manager, a Mac system utility. Help with this Mac only: \
    performance, memory, storage, battery and energy, network and Wi-Fi, displays, apps and processes, \
    startup items, and fixing problems with them. Use the live readings you are given; say which reading \
    you're basing an answer on. Explain in plain words for someone who isn't technical, give steps in order, \
    and suggest the Apex page or button that helps (for example Free Up Memory, Disk › Analyze, Drive Doctor, \
    Network Doctor). Never suggest deleting system files or running commands that could lose data without a \
    clear warning. If a question isn't about this Mac or its software, say briefly that you only help with \
    the Mac and its system utilities.
    """

    /// Streams the reply, calling `onText` with each piece.
    static func ask(_ server: Server, model: String, history: [Message], context: String,
                    onText: @escaping @Sendable (String) -> Void) async throws {
        guard let url = URL(string: server.base + "/chat/completions") else { return }
        var msgs: [[String: String]] = [["role": "system", "content": instructions + "\n\nLive readings from this Mac right now:\n" + context]]
        msgs += history.suffix(12).map { ["role": $0.role.rawValue, "content": $0.text] }
        let body: [String: Any] = ["model": model, "messages": msgs, "stream": true, "temperature": 0.3]
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Apex", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The model server answered \((resp as? HTTPURLResponse)?.statusCode ?? 0). Is the model loaded?"])
        }
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            if let piece = parseStreamLine(line) { onText(piece) }
        }
    }

    /// One server-sent-events line → the text it adds, if any. Pure: tested.
    static func parseStreamLine(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let d = payload.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let choice = (o["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any],
              let text = delta["content"] as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Starts LM Studio's local server with its own command-line tool (the user
    /// asks for it). Returns an error message, or nil.
    static func startLMStudio() -> String? {
        let lms = NSHomeDirectory() + "/.lmstudio/bin/lms"
        guard FileManager.default.isExecutableFile(atPath: lms) else {
            return "LM Studio’s command-line tool isn’t installed. Open LM Studio and turn on its local server (Developer › Start Server)."
        }
        let r = Shell.run(lms, ["server", "start"])
        return r.status == 0 ? nil : "LM Studio didn’t start its server. Open LM Studio once, then try again."
    }
}

/// Apex's live readings as short plain text for the assistant.
enum AssistantContext {
    @MainActor static func current() -> String {
        let m = AppModel.shared
        return build(m.snapshot, events: Array(EventLog.shared.events.prefix(5)),
                     battery: HardwareStore.shared.hasBattery ? HardwareStore.shared.battery : nil)
    }

    /// Pure: tested.
    static func build(_ s: Snapshot, events: [DetectionEvent], battery: BatteryInfo?) -> String {
        let sys = s.system
        var lines: [String] = []
        lines.append("Mac: \(sys.cpu.brand), \(Fmt.bytes(sys.memory.total)) memory")
        lines.append(String(format: "CPU: %.0f%% busy", sys.cpu.total))
        lines.append("Memory: \(Fmt.bytes(sys.memory.used)) used of \(Fmt.bytes(sys.memory.total)), pressure \(sys.memory.pressureLevel.title), swap \(Fmt.bytes(sys.memory.swapUsed))")
        lines.append("Startup disk: \(Fmt.diskBytes(sys.disk.available)) free of \(Fmt.diskBytes(sys.disk.capacity))")
        lines.append("Network: \(sys.network.interface.isEmpty ? "not connected" : sys.network.interface), ↓ \(Fmt.rate(sys.network.inPerSec)) ↑ \(Fmt.rate(sys.network.outPerSec))")
        if let g = sys.gpu.utilization { lines.append(String(format: "GPU: %.0f%%", g)) }
        if let b = battery {
            lines.append("Battery: \(b.percent)%, \(b.onAC ? "on power" : "on battery"), health \(Int(b.health.rounded()))%, \(b.cycleCount) cycles")
        }
        let apps = s.processes.filter(\.isRegularApp)
        let byCPU = apps.sorted { $0.cpu > $1.cpu }.prefix(5).map { String(format: "%@ %.0f%%", $0.name, $0.cpu) }
        let byMem = apps.sorted { $0.memory > $1.memory }.prefix(5).map { "\($0.name) \(Fmt.bytes($0.memory))" }
        if !byCPU.isEmpty { lines.append("Busiest apps (CPU): " + byCPU.joined(separator: ", ")) }
        if !byMem.isEmpty { lines.append("Largest apps (memory): " + byMem.joined(separator: ", ")) }
        if !events.isEmpty {
            lines.append("Recent alerts: " + events.map { "\($0.title) (\($0.date.formatted(date: .omitted, time: .shortened)))" }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}
