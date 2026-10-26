import XCTest
@testable import TaskManager

/// Cloud API with any provider and named, grouped keys; Lumen AI. The network
/// is a stand-in (`StubService`), so the real request code runs end to end
/// without the internet; secrets live in memory, never in the Keychain.
@MainActor final class AIProviderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var secrets: MemorySecrets!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "apex-ai-\(UUID())")
        secrets = MemorySecrets()
        URLProtocol.registerClass(StubService.self)
    }
    override func tearDown() async throws {
        URLProtocol.unregisterClass(StubService.self)
        StubService.reset()
    }

    // MARK: Keys: named, grouped, any provider

    func testKeysAreNamedGroupedAndKeptApart() {
        let store = CloudKeyStore(defaults: defaults, secrets: secrets)
        store.save(CloudKey(name: "Client X project", group: "Work", provider: .openai, model: "gpt-x"), secret: "sk-1")
        store.save(CloudKey(name: "  Home  ", group: " ", provider: .anthropic), secret: "sk-2")
        store.save(CloudKey(name: "Research", group: "Work", provider: .gemini), secret: "g-3")
        XCTAssertEqual(store.groups, ["Work"])
        XCTAssertEqual(store.grouped.map(\.group), ["", "Work"], "keys with no group first")
        XCTAssertEqual(store.grouped[1].keys.map(\.title), ["Client X project", "Research"])
        XCTAssertEqual(store.grouped[0].keys.first?.title, "Home", "names trimmed; an empty group is no group")
        XCTAssertEqual(store.active?.name, "Client X project", "the first key is in use")
        let home = store.keys.first { $0.name == "Home" }!
        XCTAssertEqual(store.secret(for: home), "sk-2")
        XCTAssertNil(defaults.data(forKey: "cloudKeys").flatMap { String(data: $0, encoding: .utf8) }?.range(of: "sk-"),
                     "secrets never in the saved list")
        // Kept across launches.
        let again = CloudKeyStore(defaults: defaults, secrets: secrets)
        XCTAssertEqual(again.keys.count, 3)
        // Removed: from the list and from the secret store.
        again.remove(home.id)
        XCTAssertNil(secrets.get(home.secretAccount))
        XCTAssertEqual(again.keys.count, 2)
    }

    func testTheOldSingleAnthropicKeyIsKept() {
        secrets.set("sk-old", "anthropic-api-key")
        defaults.set("claude-sonnet-5-5", forKey: "assistantCloudModel")
        let store = CloudKeyStore(defaults: defaults, secrets: secrets)
        let k = try! XCTUnwrap(store.active)
        XCTAssertEqual(k.provider, .anthropic)
        XCTAssertEqual(k.name, "Anthropic")
        XCTAssertEqual(k.model, "claude-sonnet-5-5")
        XCTAssertEqual(store.secret(for: k), "sk-old")
        XCTAssertNil(secrets.get("anthropic-api-key"), "moved, not copied")
        XCTAssertEqual(CloudKeyStore(defaults: defaults, secrets: secrets).keys.count, 1, "migrated once")
    }

    func testEveryProviderHasAnAddressAndPages() {
        for p in AIProvider.allCases where p != .custom {
            XCTAssertNotNil(p.base.flatMap(URL.init(string:)), p.name)
            XCTAssertNotNil(p.keysPage, p.name)
        }
        XCTAssertEqual(AIProvider.anthropic.api, .anthropic)
        XCTAssertTrue(AIProvider.allCases.filter { $0 != .anthropic }.allSatisfy { $0.api == .openAI })
        var custom = CloudKey(name: "Gateway", provider: .custom)
        custom.customBase = " https://ai.example.com/v1/ "
        XCTAssertEqual(custom.base, "https://ai.example.com/v1")
    }

    // MARK: Requests, end to end against a stand-in service

    func testOpenAIStyleKeyCheckListsChatModelsOnly() async throws {
        StubService.reply = (200, #"{"data":[{"id":"gpt-b"},{"id":"text-embedding-3"},{"id":"gpt-a"},{"id":"whisper-1"},{"id":"tts-1"}]}"#)
        let k = CloudKey(name: "x", provider: .openai)
        let models = try await Assistant.models(for: k, secret: "sk-test")
        XCTAssertEqual(models, ["gpt-a", "gpt-b"])
        XCTAssertEqual(StubService.last?.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(StubService.last?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testAnthropicKeyCheckUsesItsOwnHeaders() async throws {
        StubService.reply = (200, #"{"data":[{"id":"claude-new"},{"id":"claude-old"}]}"#)
        let models = try await Assistant.models(for: CloudKey(name: "x", provider: .anthropic), secret: "sk-ant")
        XCTAssertEqual(models, ["claude-new", "claude-old"], "newest first, as listed")
        XCTAssertEqual(StubService.last?.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertNil(StubService.last?.value(forHTTPHeaderField: "Authorization"))
    }

    func testAWrongKeyIsSaidInPlainWordsNamingTheService() async {
        StubService.reply = (401, #"{"error":{"message":"Incorrect API key"}}"#)
        do {
            _ = try await Assistant.models(for: CloudKey(name: "x", provider: .mistral), secret: "bad")
            XCTFail("should throw")
        } catch let e as CloudError {
            XCTAssertEqual(e.text("Mistral"), "Mistral didn’t accept this API key. Check it under Manage Keys.")
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(CloudError.status(402, Data()).text("OpenAI"), "The OpenAI account needs credit. Add some on its billing page.")
        XCTAssertEqual(CloudError.status(429, Data()).text("OpenAI"), "Too many questions at once for this account. Wait a moment and ask again.")
        XCTAssertEqual(CloudError.status(503, Data()).text("Google"), "Google is busy right now. Ask again in a moment.")
        XCTAssertEqual(CloudError.status(418, Data(#"{"error":"teapot"}"#.utf8)).text("X"), "X: teapot")
    }

    func testAnOpenAIStyleAnswerStreamsIn() async throws {
        StubService.reply = (200, """
        data: {"choices":[{"delta":{"content":"Safari is "}}]}

        data: {"choices":[{"delta":{"content":"using 4 GB."}}]}

        data: [DONE]

        """)
        let q = Assistant.Message(role: .user, text: "What's using memory?")
        let got = Collected()
        try await OpenAIChat.ask(base: "https://openrouter.ai/api/v1", key: "or-key", model: "some/model", history: [q],
                                 readings: "Memory: 7 GB used") { got.add($0) }
        XCTAssertEqual(got.text, "Safari is using 4 GB.")
        let body = try XCTUnwrap(StubService.lastBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["model"] as? String, "some/model")
        let msgs = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(msgs.first?["role"], "system")
        XCTAssertTrue(msgs.first?["content"]?.contains("Memory: 7 GB used") == true, "readings in the system message")
        XCTAssertEqual(msgs.last?["content"], "What's using memory?")
    }

    func testChatModelFilter() {
        XCTAssertEqual(OpenAIChat.chatModels(["a", "dall-e-3", "omni-moderation", "b-realtime", "c"]), ["a", "c"])
    }

    // MARK: Lumen AI (CyberNet Labs)

    func testLumenIsComingSoonUntilCyberNetLabsOpensIt() async {
        XCTAssertNil(Lumen.liveBase, "no CyberNet Labs endpoint exists yet")
        XCTAssertFalse(Lumen.isLive)
        XCTAssertEqual(Lumen.Access.allCases.map(\.title), ["Monthly Plan", "API Access"])
        let account = LumenAccount(defaults: defaults, secrets: secrets)
        let p = await account.connect(key: "lumen-123", access: .plan)
        XCTAssertEqual(p, "Lumen AI isn’t open yet. CyberNet Labs will open it soon.")
        XCTAssertFalse(account.hasKey)
        XCTAssertTrue(Assistant.Mode.lumen.detail.contains("CyberNet Labs"))
    }
}

final class MemorySecrets: SecretStore {
    private var d: [String: String] = [:]
    func get(_ account: String) -> String? { d[account] }
    func set(_ value: String, _ account: String) { d[account] = value }
    func remove(_ account: String) { d[account] = nil }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []
    func add(_ s: String) { lock.lock(); parts.append(s); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return parts.joined() }
}

/// Answers every request with `reply`, and remembers the last one.
final class StubService: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (Int, String) = (200, "{}")
    nonisolated(unsafe) static var last: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    static func reset() { reply = (200, "{}"); last = nil; lastBody = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.last = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { s in
            s.open(); defer { s.close() }
            var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            return d
        }
        let r = HTTPURLResponse(url: request.url!, statusCode: Self.reply.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
