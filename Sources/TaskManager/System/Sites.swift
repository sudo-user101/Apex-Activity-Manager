import Foundation

/// The reverse proxies on a server and every site they serve, from Apex
/// Server Edition 1.1 (`/api/proxies`): where each site forwards, its HTTPS
/// certificate, and the last 10 minutes of its traffic. Decoded leniently.
struct ProxyReport: Decodable, Sendable {
    struct Proxy: Decodable, Sendable, Hashable, Identifiable {
        var id: String { kind }
        var kind: String; var name: String; var running: Bool; var editable: Bool
        var note: String?; var admin: String?
    }
    struct Spec: Codable, Sendable, Hashable {
        var domains: [String]; var upstream: String; var https: Bool; var websockets: Bool
    }
    struct Cert: Decodable, Sendable, Hashable { var expires: Double?; var issuer: String?; var problem: String? }
    struct Count: Decodable, Sendable, Hashable { var value: String; var count: Int }
    struct Traffic: Decodable, Sendable, Hashable {
        var requests: Int; var window: Double; var perMinute: Double; var bytes: Int64
        var statuses: [String: Int]?; var topPaths: [Count]?; var topClients: [Count]?
        var serverErrors: Int { statuses?["5xx"] ?? 0 }
        var notFound: Int { statuses?["4xx"] ?? 0 }
        /// Share of requests that failed on the server (5xx), 0–1.
        var errorShare: Double { requests > 0 ? Double(serverErrors) / Double(requests) : 0 }
    }
    struct Site: Decodable, Sendable, Hashable, Identifiable {
        var id: String; var proxy: String; var domains: [String]; var targets: [String]
        var https: Bool; var enabled: Bool; var managed: Bool; var canToggle: Bool
        var file: String?; var spec: Spec?; var cert: Cert?; var traffic: Traffic?; var trafficNote: String?
        var name: String { domains.first ?? "(any name)" }
    }
    var proxies: [Proxy]
    var sites: [Site]
    var taken: Double?
}

/// What a site needs looking at. Pure: tested.
enum SiteHealth: Equatable {
    case ok, off, certSoon(days: Int), certExpired, certProblem(String), errors(share: Double)

    static func of(_ s: ProxyReport.Site, now: Date = Date()) -> SiteHealth {
        guard s.enabled else { return .off }
        if let c = s.cert {
            if let p = c.problem { return .certProblem(p) }
            if let e = c.expires {
                let days = Int(floor((e - now.timeIntervalSince1970) / 86_400))
                if days < 0 { return .certExpired }
                if days < 14 { return .certSoon(days: days) }
            }
        }
        if let t = s.traffic, t.requests >= 20, t.errorShare >= 0.05 { return .errors(share: t.errorShare) }
        return .ok
    }

    var needsLook: Bool { self != .ok && self != .off }

    var text: String {
        switch self {
        case .ok: "Working"
        case .off: "Switched off"
        case .certSoon(let d): d == 0 ? "Certificate ends today" : "Certificate ends in \(d) day\(d == 1 ? "" : "s")"
        case .certExpired: "Certificate has expired"
        case .certProblem(let p): p
        case .errors(let share): "\(Int((share * 100).rounded()))% of requests fail on the server"
        }
    }
}

/// Splits what was typed into domains ("a.com, www.a.com b.com"). Pure: tested.
func siteDomains(_ text: String) -> [String] {
    var out: [String] = []
    for d in text.lowercased().split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }) {
        var s = String(d)
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        s = String(s.split(separator: "/").first ?? "")
        if !s.isEmpty, !out.contains(s) { out.append(s) }
    }
    return out
}

extension ServerEdition {
    /// The server's proxies and sites. Blocking.
    static func proxies(_ s: ServerConfig, fresh: Bool = false) -> Result<ProxyReport, ServerError> {
        switch request(s, "/api/proxies" + (fresh ? "?fresh=1" : ""), body: nil) {
        case .failure(let e):
            if case .other(let m) = e, m.contains("(404)") {
                return .failure(.other("Update Apex Server Edition on \(s.name) to 1.1 or later to see and change its sites."))
            }
            return .failure(e)
        case .success(let d):
            guard let r = try? JSONDecoder().decode(ProxyReport.self, from: d) else {
                return .failure(.other("The server answered, but not with sites Apex understands. Update Apex Server Edition on it."))
            }
            return .success(r)
        }
    }

    /// Adds, edits, switches off / on or removes a site. Blocking; the
    /// server checks the change with the proxy itself and undoes it if refused.
    static func changeSite(_ s: ServerConfig, proxy: String, verb: String, site: String?, spec: ProxyReport.Spec?) -> (ok: Bool, message: String) {
        var body: [String: Any] = ["proxy": proxy, "verb": verb, "site": site ?? ""]
        if let spec {
            body["spec"] = ["domains": spec.domains, "upstream": spec.upstream, "https": spec.https, "websockets": spec.websockets]
        }
        switch request(s, "/api/proxy", body: body) {
        case .failure(let e): return (false, e.message)
        case .success(let d):
            let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            return (j["ok"] as? Bool == true, j["message"] as? String ?? "It didn’t work.")
        }
    }
}

/// Every paired server's sites, read every 10 seconds while Sites is open.
@MainActor @Observable
final class SitesStore {
    static let shared = SitesStore()
    private(set) var reports: [UUID: ProxyReport] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var loading = Set<UUID>()

    func refresh(_ s: ServerConfig, fresh: Bool = false) async {
        guard s.isEdition else { return }
        if reports[s.id] == nil { loading.insert(s.id) }
        let r = await Task.detached(priority: .utility) { ServerEdition.proxies(s, fresh: fresh) }.value
        loading.remove(s.id)
        switch r {
        case .success(let rep): reports[s.id] = rep; errors[s.id] = nil
        case .failure(let e): errors[s.id] = e.message
        }
    }

    func refresh(_ servers: [ServerConfig]) async {
        await withTaskGroup(of: Void.self) { g in
            for s in servers where s.isEdition { g.addTask { await self.refresh(s) } }
        }
    }

    /// Shows a report without reading (tests and screenshots).
    func use(_ r: ProxyReport, for id: UUID) { reports[id] = r; errors[id] = nil }

    func change(_ s: ServerConfig, proxy: String, verb: String, site: String?, spec: ProxyReport.Spec?) async -> (ok: Bool, message: String) {
        let r = await Task.detached(priority: .userInitiated) { ServerEdition.changeSite(s, proxy: proxy, verb: verb, site: site, spec: spec) }.value
        await refresh(s, fresh: true)
        return r
    }
}
