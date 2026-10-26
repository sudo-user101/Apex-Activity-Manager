import Foundation

/// Assistant › Local AI: a model running on this Mac (LM Studio, Ollama, or
/// any server with the same OpenAI-style API) answering questions about this
/// Mac, with Apex's live readings attached. Nothing leaves the Mac.
enum LocalChat {
    struct Server: Equatable, Sendable {
        let name: String         // "LM Studio", "Ollama"
        let base: String         // e.g. http://127.0.0.1:1234/v1
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

    /// Streams the reply, calling `onText` with each piece. Local models get
    /// the same instructions as the cloud services, with the readings in the system message.
    static func ask(_ server: Server, model: String, history: [Assistant.Message], readings: String,
                    onText: @escaping @Sendable (String) -> Void) async throws {
        do {
            try await OpenAIChat.ask(base: server.base, key: nil, model: model, history: Array(history.suffix(12)),
                                     readings: readings, extra: ["temperature": 0.3], onText: onText)
        } catch CloudError.status(let code, _) {
            throw NSError(domain: "Apex", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(server.name) answered \(code). Is the model loaded?"])
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
