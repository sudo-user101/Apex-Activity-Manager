import Foundation

/// Full root work on a server through Apex Server Edition 1.2 (`/api/panel`):
/// files, the terminal, updates and packages, the firewall, SSH and keys.
/// The server only allows it after `sudo apex-server allow panel` there.
enum ServerPanel {
    struct Answer: Sendable {
        var ok: Bool
        var message: String
        var result: Data?
        /// Panel mode is off on the server (switched on only at the server).
        var panelOff: Bool { !ok && message.contains("allow panel") }
        func object() -> [String: Any] { result.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
        func decode<T: Decodable>(_ t: T.Type) -> T? { result.flatMap { try? JSONDecoder().decode(t, from: $0) } }
    }

    /// One request (blocking). `long` for big file parts.
    static func send(_ s: ServerConfig, _ req: [String: Any], long: Bool = false) -> Answer {
        var h = s; h.container = ""
        guard h.isEdition else {
            return Answer(ok: false, message: "Managing a server needs Apex Server Edition on it (it runs as root and keeps the connection encrypted). \(s.name) is read over SSH.")
        }
        switch ServerEdition.request(h, "/api/panel", body: req, long: long) {
        case .failure(let e):
            if case .other(let m) = e, m.contains("(404)") {
                return Answer(ok: false, message: "Update Apex Server Edition on \(s.name) to 1.2 or later to manage it from here.")
            }
            return Answer(ok: false, message: e.message)
        case .success(let d):
            let a = DockerAnswer.parse(d)
            return Answer(ok: a.ok, message: a.message, result: a.result)
        }
    }

    static func sendAsync(_ s: ServerConfig, _ req: [String: Any], long: Bool = false) async -> Answer {
        await Task.detached(priority: .userInitiated) { send(s, req, long: long) }.value
    }

    /// Follows a background job (updates, installs) until it ends; `progress` gets the output so far.
    static func follow(_ s: ServerConfig, job id: String, progress: @MainActor @escaping (String) -> Void) async -> (ok: Bool, text: String) {
        var text = "", next = 0
        while !Task.isCancelled {
            let a = await sendAsync(s, ["op": "job", "id": id, "since": next])
            guard a.ok else { return (false, text + "\n" + a.message) }
            let o = a.object()
            text += o["text"] as? String ?? ""
            next = o["next"] as? Int ?? next
            await progress(text)
            if o["done"] as? Bool == true { return (o["failed"] as? Bool != true, text) }
            try? await Task.sleep(for: .milliseconds(800))
        }
        return (false, text)
    }

    struct Status: Decodable, Sendable { var panel: Bool; var packages: String?; var firewall: String?; var fail2ban: Bool?; var terminal: Bool?; var shell: String? }
}

/// A root terminal on a server: output read in a loop (each read waits up
/// to a second on the server for something new), keys sent as typed.
@MainActor @Observable
final class ServerTerminal {
    let server: ServerConfig
    let screen: TerminalEmulator
    private(set) var problem: String?
    private(set) var connected = false
    private(set) var closed = false
    /// Bumped on every change, so the view redraws.
    private(set) var generation = 0
    @ObservationIgnored private var id: String?
    @ObservationIgnored private var next = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pending = Data()
    @ObservationIgnored private var sending = false
    /// Everything the server sent, for tests that look at the raw bytes.
    @ObservationIgnored var record: ((Data) -> Void)?

    init(server: ServerConfig, cols: Int, rows: Int) {
        self.server = server
        screen = TerminalEmulator(cols: cols, rows: rows)
        screen.respond = { [weak self] d in Task { @MainActor in self?.send(d) } }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            let a = await ServerPanel.sendAsync(server, ["op": "term.open", "cols": screen.cols, "rows": screen.rows])
            guard a.ok, let id = a.object()["id"] as? String else { problem = a.message; return }
            self.id = id; connected = true
            while !Task.isCancelled {
                let r = await ServerPanel.sendAsync(server, ["op": "term.read", "id": id, "since": next])
                if !r.ok { problem = r.message; connected = false; break }
                let o = r.object()
                if let b64 = o["data"] as? String, let d = Data(base64Encoded: b64), !d.isEmpty {
                    record?(d)
                    screen.feed(d); generation &+= 1
                }
                next = o["next"] as? Int ?? next
                if o["closed"] as? Bool == true { closed = true; connected = false; generation &+= 1; break }
            }
        }
    }

    /// Keys go out in order; ones typed while a send is on the way go together next.
    func send(_ d: Data) {
        guard id != nil, !closed else { return }
        pending.append(d)
        guard !sending else { return }
        sending = true
        Task {
            while !pending.isEmpty, let id {
                let chunk = pending; pending.removeAll()
                let a = await ServerPanel.sendAsync(server, ["op": "term.write", "id": id, "data": chunk.base64EncodedString()])
                if !a.ok { problem = a.message }
            }
            sending = false
        }
    }

    func resize(cols: Int, rows: Int) {
        guard cols != screen.cols || rows != screen.rows else { return }
        screen.resize(cols: cols, rows: rows); generation &+= 1
        guard let id else { return }
        let s = server
        Task.detached { _ = ServerPanel.send(s, ["op": "term.resize", "id": id, "cols": cols, "rows": rows]) }
    }

    func stop() {
        loop?.cancel(); loop = nil
        if let id { let s = server; Task.detached { _ = ServerPanel.send(s, ["op": "term.close", "id": id]) } }
        id = nil; connected = false
    }
}
