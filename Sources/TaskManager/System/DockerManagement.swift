import Foundation

/// Docker Management on a server: containers grouped by stack (and the
/// manager that runs each stack: Dockge, Portainer, Compose), images,
/// volumes and networks. The same requests go to Apex Server Edition
/// (`/api/docker`) or, over SSH, to Resources/apex-docker.py; both answer
/// the same way and decide on the server which files and stacks they touch.
struct DockerReport: Decodable, Sendable {
    struct Manager: Decodable, Sendable, Hashable { var name: String; var container: String; var running: Bool; var url: String? }
    struct Container: Decodable, Sendable, Hashable, Identifiable {
        var id: String; var name: String; var image: String; var imageId: String?; var state: String; var status: String
        var created: Double?; var ports: [String]?; var networks: [String]?; var volumes: [String]?
        var project: String?; var service: String?; var cpu: String?; var memory: String?
        var running: Bool { state == "running" }
        var paused: Bool { state == "paused" }
    }
    struct Stack: Decodable, Sendable, Hashable, Identifiable {
        var id: String { name }
        var name: String; var manager: String; var dir: String?; var files: [String]; var editable: Bool; var total: Int; var running: Int
        var managerName: String { ["dockge": "Dockge", "portainer": "Portainer", "compose": "Compose"][manager] ?? manager }
        /// Up, down and update need the compose file on the server (not Portainer's).
        var canDeploy: Bool { manager != "portainer" && !files.isEmpty }
    }
    struct Image: Decodable, Sendable, Hashable, Identifiable {
        var id: String; var tags: [String]; var size: Int64; var created: Double?; var usedBy: [String]
        var name: String { tags.first ?? "<untagged> " + id.replacingOccurrences(of: "sha256:", with: "").prefix(12) }
    }
    struct Volume: Decodable, Sendable, Hashable, Identifiable {
        var id: String { name }
        var name: String; var driver: String; var mountpoint: String; var usedBy: [String]; var anonymous: Bool
    }
    struct Network: Decodable, Sendable, Hashable, Identifiable {
        var id: String; var name: String; var driver: String; var scope: String; var containers: [String]; var builtin: Bool
    }
    var available: Bool
    var problem: String?
    var version: String?
    var compose: Bool
    var managers: [Manager]
    var containers: [Container]
    var stacks: [Stack]
    var images: [Image]
    var volumes: [Volume]
    var networks: [Network]

    /// Containers that belong to no stack.
    var loose: [Container] { containers.filter { ($0.project ?? "").isEmpty } }
    func containers(of s: Stack) -> [Container] { containers.filter { $0.project == s.name } }
    var unusedImageBytes: Int64 { images.filter(\.usedBy.isEmpty).reduce(0) { $0 + $1.size } }
}

/// One request and its answer.
struct DockerAnswer: Sendable {
    var ok: Bool
    var message: String
    var result: Data?

    /// `{"ok":…, "message":…, "result":…}` from either side. Pure: tested.
    static func parse(_ d: Data) -> DockerAnswer {
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return DockerAnswer(ok: false, message: "The server answered something Apex doesn’t understand.")
        }
        var r: Data?
        if let res = j["result"], !(res is NSNull) { r = try? JSONSerialization.data(withJSONObject: res, options: [.fragmentsAllowed]) }
        return DockerAnswer(ok: j["ok"] as? Bool == true, message: j["message"] as? String ?? "", result: r)
    }

    func text(_ key: String = "text") -> String? {
        result.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?[key] as? String
    }
}

enum DockerClient {
    /// Tests set this (no app bundle).
    nonisolated(unsafe) static var scriptOverride: String?

    static var script: String {
        if let scriptOverride { return scriptOverride }
        guard let url = Bundle.main.url(forResource: "apex-docker", withExtension: "py"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }

    /// Docker runs on the server itself, also for a container watched on it.
    static func host(_ s: ServerConfig) -> ServerConfig { var h = s; h.container = ""; return h }

    /// Sends one request (blocking).
    static func send(_ s: ServerConfig, _ req: [String: Any]) -> DockerAnswer {
        let h = host(s)
        let long = (req["op"] as? String).map { ["stack", "save", "prune"].contains($0) } ?? false
        if h.isEdition {
            switch ServerEdition.request(h, "/api/docker", body: req, long: long) {
            case .failure(let e):
                if case .other(let m) = e, m.contains("(404)") {
                    return DockerAnswer(ok: false, message: "Update Apex Server Edition on \(s.name) to 1.1 or later for Docker Management.")
                }
                return DockerAnswer(ok: false, message: e.message)
            case .success(let d): return DockerAnswer.parse(d)
            }
        }
        guard let body = try? JSONSerialization.data(withJSONObject: req) else { return DockerAnswer(ok: false, message: "Bad request.") }
        // The request rides in the script's first line (base64: nothing to escape,
        // and no limit on a command line's length).
        let input = "APEX_REQ = \"\(body.base64EncodedString())\"\n" + script
        var r = ServerClient.runSSH(h, command: "python3 -", input: input)
        var a = DockerAnswer.parse(Data(r.stdout.utf8))
        if !a.ok, r.stdout.contains("\"permission\": true") {
            r = ServerClient.runSSH(h, command: "sudo -n python3 -", input: input)
            let b = DockerAnswer.parse(Data(r.stdout.utf8))
            if b.ok || !r.stdout.isEmpty && !r.stdout.contains("\"permission\": true") { a = b }
        }
        if r.stdout.isEmpty {
            let e = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return DockerAnswer(ok: false, message: e.contains("python3") && e.contains("not found")
                                ? "The server has no Python 3, which Docker Management over SSH needs (or use Apex Server Edition there)."
                                : (e.isEmpty ? "No answer from \(s.name)." : e))
        }
        return a
    }

    static func list(_ s: ServerConfig) -> Result<DockerReport, ServerError> {
        let a = send(s, ["op": "list"])
        guard a.ok, let d = a.result else { return .failure(.other(a.message.isEmpty ? "Couldn’t read Docker on \(s.name)." : a.message)) }
        do { return .success(try JSONDecoder().decode(DockerReport.self, from: d)) }
        catch { return .failure(.other("Docker on \(s.name) answered in a way Apex doesn’t understand. Update Apex Server Edition there.")) }
    }
}

/// Every server's Docker, read every 5 seconds while Docker Management is open.
@MainActor @Observable
final class DockerStore {
    static let shared = DockerStore()
    private(set) var reports: [UUID: DockerReport] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var loading = Set<UUID>()
    /// What's being done now (a container, stack, image… id), for spinners.
    private(set) var busy = Set<String>()

    func refresh(_ s: ServerConfig) async {
        if reports[s.id] == nil { loading.insert(s.id) }
        let r = await Task.detached(priority: .utility) { DockerClient.list(s) }.value
        loading.remove(s.id)
        switch r {
        case .success(let rep): reports[s.id] = rep; errors[s.id] = nil
        case .failure(let e): errors[s.id] = e.message
        }
    }

    /// Does it, reads again, and says what happened.
    func run(_ s: ServerConfig, _ req: [String: Any], busyKey: String) async -> DockerAnswer {
        busy.insert(busyKey)
        let r = await Task.detached(priority: .userInitiated) { DockerClient.send(s, req) }.value
        await refresh(s)
        busy.remove(busyKey)
        return r
    }

    /// Shows a report without reading (tests render the page from a saved one).
    func use(_ r: DockerReport, for id: UUID) { reports[id] = r; errors[id] = nil }

    func ask(_ s: ServerConfig, _ req: [String: Any]) async -> DockerAnswer {
        await Task.detached(priority: .userInitiated) { DockerClient.send(s, req) }.value
    }
}
