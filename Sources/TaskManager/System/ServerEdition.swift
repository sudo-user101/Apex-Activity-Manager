import CryptoKit
import Foundation
import Security

/// Talks to Apex Activity Manager Server Edition on a Linux server: HTTPS on
/// its own port (7443 by default), with the server's own certificate pinned
/// (its SHA-256 fingerprint is saved when pairing; a different certificate
/// later is refused), and this Mac's token, kept in the login keychain.
enum ServerEdition {
    static let defaultPort = 7443

    /// What pairing gives back.
    struct Paired: Equatable, Sendable { let token: String; let fingerprint: String; let host: String }

    /// Pairs with a server using the code its install printed.
    static func pair(host: String, port: Int, code: String, device: String) async -> Result<Paired, ServerError> {
        let pin = PinDelegate(expected: nil)
        let session = URLSession(configuration: config(), delegate: pin, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let hello = url(host, port, "/api/hello"), let pairURL = url(host, port, "/api/pair") else {
            return .failure(.other("That address doesn’t look right."))
        }
        do {
            let (hd, hr) = try await session.data(from: hello)
            guard (hr as? HTTPURLResponse)?.statusCode == 200,
                  let o = try? JSONSerialization.jsonObject(with: hd) as? [String: Any], (o["product"] as? String)?.contains("Apex") == true else {
                return .failure(.other("Something answered on port \(port), but it isn’t Apex Server Edition."))
            }
            var req = URLRequest(url: pairURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "device": device])
            let (d, r) = try await session.data(for: req)
            let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            guard (r as? HTTPURLResponse)?.statusCode == 200, let token = j["token"] as? String, let fp = pin.seen else {
                return .failure(.other((j["error"] as? String) ?? "The server didn’t accept the code."))
            }
            return .success(Paired(token: token, fingerprint: fp, host: j["host"] as? String ?? host))
        } catch {
            return .failure(problem(error, pinned: nil))
        }
    }

    /// One reading. Blocking (it's called off the main thread, like the SSH reading).
    static func snapshot(_ s: ServerConfig) -> Result<ServerSnapshot, ServerError> {
        switch request(s, "/api/snapshot", body: nil) {
        case .failure(let e): return .failure(e)
        case .success(let d):
            guard let snap = try? JSONDecoder().decode(ServerSnapshot.self, from: d) else {
                return .failure(.other("The server answered, but not with readings Apex understands. Update Apex Server Edition on it."))
            }
            return .success(snap)
        }
    }

    /// An action, from the same command text the SSH connection runs
    /// (`kill -9 12 34`, `sudo systemctl restart 'nginx'`, `docker stop 'web'`).
    static func action(_ s: ServerConfig, _ command: String) -> Shell.Result {
        guard let a = Action.parse(command) else {
            return Shell.Result(launched: false, status: 1, stdout: "", stderr: "Apex Server Edition can’t do that.")
        }
        switch request(s, "/api/action", body: a.json) {
        case .failure(let e): return Shell.Result(launched: false, status: 1, stdout: "", stderr: e.message)
        case .success(let d):
            let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            let ok = j["ok"] as? Bool == true
            return Shell.Result(launched: true, status: ok ? 0 : 1, stdout: "", stderr: ok ? "" : (j["message"] as? String ?? "It didn’t work."))
        }
    }

    /// The action an SSH command stands for. Pure: tested.
    struct Action: Equatable {
        let kind: String, verb: String, target: String, force: Bool
        var json: [String: Any] { ["kind": kind, "verb": verb, "target": target, "force": force] }

        static func parse(_ command: String) -> Action? {
            var c = command.trimmingCharacters(in: .whitespaces)
            if c.hasPrefix("sudo ") { c.removeFirst(5) }
            let words = c.split(separator: " ").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            guard let first = words.first else { return nil }
            switch first {
            case "kill":
                let force = words.dropFirst().first == "-9"
                let pids = words.dropFirst(force ? 2 : 1).filter { Int($0) != nil }
                return pids.isEmpty ? nil : Action(kind: "process", verb: "end", target: pids.joined(separator: " "), force: force)
            case "systemctl" where words.count >= 3 && ["start", "stop", "restart"].contains(words[1]):
                return Action(kind: "service", verb: words[1], target: words[2...].joined(separator: " "), force: false)
            case "docker" where words.count == 3 && ["start", "stop", "restart"].contains(words[1]):
                return Action(kind: "container", verb: words[1], target: words[2], force: false)
            default:
                return nil
            }
        }
    }

    // MARK: Connection

    static func tokenAccount(_ s: ServerConfig) -> String { "server-edition:" + s.id.uuidString }
    static func saveToken(_ token: String, for s: ServerConfig) { Keychain.set(token, account: tokenAccount(s)) }
    static func forget(_ s: ServerConfig) { Keychain.remove(account: tokenAccount(s)) }

    private static func config() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 30
        c.urlCache = nil
        c.httpCookieStorage = nil
        return c
    }

    /// One session per server, pinned to the certificate it was paired with.
    private static let sessions = SessionCache()

    private final class SessionCache: @unchecked Sendable {
        private var map: [String: URLSession] = [:]
        private let lock = NSLock()
        func session(for fingerprint: String) -> URLSession {
            lock.lock(); defer { lock.unlock() }
            if let s = map[fingerprint] { return s }
            let s = URLSession(configuration: ServerEdition.config(), delegate: PinDelegate(expected: fingerprint), delegateQueue: nil)
            map[fingerprint] = s
            return s
        }
    }

    static func url(_ host: String, _ port: Int, _ path: String) -> URL? {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = h.contains(":") && !h.hasPrefix("[") ? "[\(h)]" : h      // IPv6 needs brackets
        c.port = port
        c.path = path
        return c.url
    }

    private static func request(_ s: ServerConfig, _ path: String, body: [String: Any]?) -> Result<Data, ServerError> {
        guard let fp = s.fingerprint, let token = Keychain.get(account: tokenAccount(s)) else {
            return .failure(.other("Apex isn’t paired with \(s.name). Edit it and pair it again with the code from `sudo apex-server pair`."))
        }
        guard let u = url(s.host, s.port, path) else { return .failure(.other("That address doesn’t look right.")) }
        var req = URLRequest(url: u)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        sessions.session(for: fp).dataTask(with: req) { d, r, e in
            if let e { box.value = .failure(problem(e, pinned: fp)) }
            else if let code = (r as? HTTPURLResponse)?.statusCode, code == 401 {
                box.value = .failure(.other("\(s.name) doesn’t know this Mac any more (it was unpaired). Edit it and pair it again."))
            } else if let d, (r as? HTTPURLResponse)?.statusCode == 200 { box.value = .success(d) }
            else { box.value = .failure(.other("The server answered with an error (\((r as? HTTPURLResponse)?.statusCode ?? 0)).")) }
            sem.signal()
        }.resume()
        if sem.wait(timeout: .now() + 35) == .timedOut { return .failure(.unreachable) }
        return box.value ?? .failure(.unreachable)
    }

    private final class ResultBox: @unchecked Sendable { var value: Result<Data, ServerError>? }

    /// URL errors in plain words. Pure: tested.
    static func problem(_ error: Error, pinned: String?) -> ServerError {
        let e = error as NSError
        switch e.code {
        case NSURLErrorCancelled where pinned != nil, NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed:
            return .other("This server’s certificate isn’t the one Apex paired with. If Apex Server Edition was reinstalled there, pair again; otherwise something may be standing in for the server.")
        case NSURLErrorCannotConnectToHost:
            return .other("Nothing is answering on that port. Is Apex Server Edition running there (sudo apex-server status), and is the port open in its firewall?")
        case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
            return .unreachable
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .hostUnknown
        default:
            return .other(e.localizedDescription)
        }
    }

    /// SHA-256 of a certificate, as the server prints it ("AB:CD:…"). Pure: tested.
    static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Accepts the server's certificate only if it's the paired one (or, when
    /// pairing, notes which one it is).
    final class PinDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        let expected: String?
        var seen: String?
        init(expected: String?) { self.expected = expected }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            let fp = ServerEdition.fingerprint(SecCertificateCopyData(leaf) as Data)
            seen = fp
            if expected == nil || expected == fp { completionHandler(.useCredential, URLCredential(trust: trust)) }
            else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }
}
