import Foundation

/// Local LLM runtimes (Ollama, LM Studio, llama.cpp, MLX, …).
///
/// Detection is done on the process list we already sample, so nothing is
/// queried unless a runtime is actually running. Each runtime's local HTTP API
/// (127.0.0.1 only) is polled only while the Local AI view is on screen.
struct AIRuntime: Identifiable, Sendable {
    enum Kind: String, Sendable { case ollama, lmStudio, llamaCpp, mlx, kobold, other }

    var id: String { name }
    let kind: Kind
    let name: String
    let iconPath: String
    let pids: [pid_t]
    let mainPID: pid_t
    let cpu: Double
    let memory: UInt64
    let gpu: Double
    var port: Int?
    var api: APIState = .unknown
    var models: [AIModel] = []
    /// Generation speed (tokens/s) and totals, where the runtime reports them.
    var tokensPerSecond: Double?
    var tokensGenerated: UInt64?
    var promptTokens: UInt64?
    var activeRequests: Int?
    var tokenNote: String?

    enum APIState: Sendable, Equatable { case unknown, online, offline }
}

struct AIModel: Identifiable, Sendable, Hashable {
    var id: String { name }
    let name: String
    var sizeBytes: UInt64?
    var gpuBytes: UInt64?
    var parameters: String?
    var quantization: String?
    var contextLength: Int?
    var unloadsAt: Date?
}

enum LocalAI {
    struct Signature { let kind: AIRuntime.Kind; let name: String; let port: Int?; let match: (ProcessInfoSample) -> Bool }

    static let signatures: [Signature] = [
        .init(kind: .ollama, name: "Ollama", port: 11434) { p in
            let n = p.name.lowercased()
            return n == "ollama" || n.hasPrefix("ollama_llama_server") || n == "ollama app"
                || p.bundlePath.hasSuffix("/Ollama.app")
        },
        .init(kind: .lmStudio, name: "LM Studio", port: 1234) { p in
            p.bundlePath.hasSuffix("/LM Studio.app") || p.path.contains("/.lmstudio/") || p.name.hasPrefix("LM Studio")
        },
        .init(kind: .llamaCpp, name: "llama.cpp", port: 8080) { p in
            ["llama-server", "llama-cli", "llama-run", "llamafile"].contains(p.name) || p.name.hasSuffix(".llamafile")
        },
        .init(kind: .kobold, name: "KoboldCpp", port: 5001) { p in p.name.lowercased().hasPrefix("koboldcpp") },
        .init(kind: .other, name: "Jan", port: 1337) { p in p.bundlePath.hasSuffix("/Jan.app") },
        .init(kind: .other, name: "GPT4All", port: 4891) { p in p.bundlePath.lowercased().hasSuffix("/gpt4all.app") || p.name == "chat" && p.path.lowercased().contains("gpt4all") },
        .init(kind: .other, name: "Msty", port: nil) { p in p.bundlePath.hasSuffix("/Msty.app") },
        .init(kind: .other, name: "LocalAI", port: 8080) { p in p.name == "local-ai" },
        .init(kind: .other, name: "vLLM", port: 8000) { p in p.name == "vllm" },
    ]

    /// Groups matching processes into runtimes. Python-based runtimes (MLX,
    /// vLLM) are recognised from their command line, read only for python
    /// processes.
    static func detect(_ procs: [ProcessInfoSample], commandLine: (pid_t) -> String?) -> [AIRuntime] {
        var found: [String: (Signature, [ProcessInfoSample])] = [:]
        for p in procs {
            if let sig = signatures.first(where: { $0.match(p) }) {
                found[sig.name, default: (sig, [])].1.append(p)
            } else if p.name.lowercased().hasPrefix("python"), let cmd = commandLine(p.pid) {
                if cmd.contains("mlx_lm") || cmd.contains("mlx-lm") || cmd.contains("mlx_vlm") {
                    let sig = Signature(kind: .mlx, name: "MLX", port: portArg(cmd) ?? 8080) { _ in false }
                    found["MLX", default: (sig, [])].1.append(p)
                } else if cmd.contains("vllm") {
                    let sig = Signature(kind: .other, name: "vLLM", port: portArg(cmd) ?? 8000) { _ in false }
                    found["vLLM", default: (sig, [])].1.append(p)
                } else if cmd.contains("llama_cpp.server") {
                    let sig = Signature(kind: .llamaCpp, name: "llama-cpp-python", port: portArg(cmd) ?? 8000) { _ in false }
                    found["llama-cpp-python", default: (sig, [])].1.append(p)
                }
            }
        }
        return found.values.map { sig, members in
            let main = members.first(where: \.isRegularApp) ?? members.min { $0.pid < $1.pid }!
            var port = sig.port
            if sig.kind == .llamaCpp || sig.kind == .kobold, let cmd = commandLine(main.pid), let p = portArg(cmd) { port = p }
            return AIRuntime(kind: sig.kind, name: sig.name,
                             iconPath: members.first { !$0.bundlePath.isEmpty }?.bundlePath ?? "",
                             pids: members.map(\.pid), mainPID: main.pid,
                             cpu: members.reduce(0) { $0 + $1.cpu }, memory: members.reduce(0) { $0 + $1.memory },
                             gpu: min(100, members.reduce(0) { $0 + $1.gpu }), port: port)
        }
        .sorted { $0.memory > $1.memory }
    }

    static func portArg(_ cmd: String) -> Int? {
        let parts = cmd.split(separator: " ")
        for (i, a) in parts.enumerated() {
            if (a == "--port" || a == "-p"), i + 1 < parts.count, let v = Int(parts[i + 1]) { return v }
            if a.hasPrefix("--port="), let v = Int(a.dropFirst(7)) { return v }
        }
        return nil
    }

    // MARK: - APIs (localhost only, short timeouts)

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.5
        c.timeoutIntervalForResource = 2
        c.waitsForConnectivity = false
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    private static func get(_ port: Int, _ path: String) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Fills `api`, `models` and token figures. `previous` provides the last
    /// token counter so a tokens/second rate can be derived.
    static func enrich(_ rt: AIRuntime, previous: (tokens: UInt64, at: Date)?) async -> AIRuntime {
        var r = rt
        guard let port = rt.port else { r.tokenNote = "This app doesn’t expose a local API."; return r }
        switch rt.kind {
        case .ollama:
            guard let d = await get(port, "/api/ps"),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { r.api = .offline; return r }
            r.api = .online
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            r.models = (j["models"] as? [[String: Any]] ?? []).map { m in
                let details = m["details"] as? [String: Any]
                let exp = (m["expires_at"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                return AIModel(name: m["name"] as? String ?? "model",
                               sizeBytes: (m["size"] as? NSNumber)?.uint64Value,
                               gpuBytes: (m["size_vram"] as? NSNumber)?.uint64Value,
                               parameters: details?["parameter_size"] as? String,
                               quantization: details?["quantization_level"] as? String,
                               contextLength: (m["context_length"] as? NSNumber)?.intValue,
                               unloadsAt: exp)
            }
            r.tokenNote = "Ollama doesn’t report live token counts; speed is shown per reply in the client."
        case .lmStudio:
            guard let d = await get(port, "/api/v0/models"),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                r.api = .offline
                r.tokenNote = "Turn on LM Studio’s local server (Developer tab) to see loaded models."
                return r
            }
            r.api = .online
            r.models = (j["data"] as? [[String: Any]] ?? [])
                .filter { ($0["state"] as? String) == "loaded" }
                .map { m in
                    AIModel(name: m["id"] as? String ?? "model", sizeBytes: nil, gpuBytes: nil,
                            parameters: m["arch"] as? String, quantization: m["quantization"] as? String,
                            contextLength: ((m["loaded_context_length"] ?? m["max_context_length"]) as? NSNumber)?.intValue,
                            unloadsAt: nil)
                }
            r.tokenNote = "LM Studio reports speed per reply only; memory below is what its processes use."
        case .llamaCpp, .mlx, .other, .kobold:
            if rt.kind == .kobold, let d = await get(port, "/api/extra/perf"),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                r.api = .online
                if let t = (j["last_token_count"] as? NSNumber)?.doubleValue,
                   let s = (j["last_eval_time"] as? NSNumber)?.doubleValue ?? (j["last_eval"] as? NSNumber)?.doubleValue, s > 0 {
                    r.tokensPerSecond = t / s
                }
                r.tokenNote = "Speed of the last reply."
            }
            // llama.cpp server (started with --metrics) exposes Prometheus counters.
            if let d = await get(port, "/metrics"), let text = String(data: d, encoding: .utf8), text.contains("llamacpp:") {
                r.api = .online
                func metric(_ name: String) -> Double? {
                    for line in text.split(separator: "\n") where line.hasPrefix(name + " ") {
                        return Double(line.split(separator: " ").last ?? "")
                    }
                    return nil
                }
                if let total = metric("llamacpp:tokens_predicted_total") {
                    r.tokensGenerated = UInt64(total)
                    if let prev = previous, UInt64(total) >= prev.tokens {
                        let dt = Date().timeIntervalSince(prev.at)
                        if dt > 0 { r.tokensPerSecond = Double(UInt64(total) - prev.tokens) / dt }
                    }
                }
                r.promptTokens = metric("llamacpp:prompt_tokens_total").map { UInt64($0) }
                r.activeRequests = metric("llamacpp:requests_processing").map { Int($0) }
                r.tokenNote = nil
            } else if r.tokensPerSecond == nil && r.kind == .llamaCpp {
                r.tokenNote = "Start llama-server with --metrics to see live tokens per second."
            }
            // OpenAI-compatible model list (llama.cpp, MLX, vLLM, Jan, LocalAI, GPT4All).
            if let d = await get(port, "/v1/models"),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                r.api = .online
                r.models = (j["data"] as? [[String: Any]] ?? []).compactMap { m in
                    (m["id"] as? String).map { AIModel(name: ($0 as NSString).lastPathComponent) }
                }
            } else if r.api != .online {
                r.api = .offline
            }
        }
        return r
    }

    /// Frees a model's memory without quitting the runtime.
    static func unload(_ model: AIModel, from rt: AIRuntime) async -> String? {
        switch rt.kind {
        case .ollama:
            guard let port = rt.port, let url = URL(string: "http://127.0.0.1:\(port)/api/generate") else { return "No API" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model.name, "keep_alive": 0])
            guard let (_, resp) = try? await session.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return "Ollama didn’t accept the request." }
            return nil
        case .lmStudio:
            let lms = NSHomeDirectory() + "/.lmstudio/bin/lms"
            guard FileManager.default.isExecutableFile(atPath: lms) else {
                return "LM Studio’s command-line tool (lms) isn’t installed. Eject the model in LM Studio, or quit it."
            }
            let r = await Task.detached { Shell.run(lms, ["unload", model.name]) }.value
            return r.status == 0 ? nil : (r.stderr.isEmpty ? "lms unload failed" : r.stderr)
        default:
            return "This runtime can’t unload a single model. Quit it to free its memory."
        }
    }

    static func canUnload(_ rt: AIRuntime) -> Bool { rt.kind == .ollama || rt.kind == .lmStudio }
}
