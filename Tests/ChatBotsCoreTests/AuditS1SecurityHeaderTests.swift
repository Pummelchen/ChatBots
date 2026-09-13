// ChatBotsCoreTests — A76: the response boundary carries a policy that holds
//
// The server wrote only Content-Type, Content-Length, Cache-Control and Connection, so the
// interface could be framed by any page the user visited and A20's stored XSS had no CSP behind
// it. There was no `nosniff` and no referrer policy either.
//
// The policy is chosen from the content type because the two HTML documents need different
// things: `/app.js` and `/style.css` are separate same-origin files and the interface has no
// inline script or style, so it keeps `script-src 'self'` with no `'unsafe-inline'`; the
// kept-conversation page carries its own inline stylesheet and replay script, so it replaces the
// policy in its own response. These tests hold that line in both directions — the interface is
// not given an inline grant, and the share page is not broken by the interface's policy.

import ChatBotsCore
import Foundation
import Testing

private actor HeaderStub: LLMEngine {
    nonisolated let spec: AgentSpec
    init(spec: AgentSpec) { self.spec = spec }

    var isLoaded: Bool { true }
    var contextWindow: Int { spec.contextWindow }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        let text = "According to the filings, the first contribution."
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 10, stopReason: "stop")))
        return text
    }
}

@MainActor
private func headerServer() async throws -> (APIServer, ConversationEngine, URLSession, String) {
    let specs = AgentSpec.makeSeats(count: 2)
    let stubs = specs.map { HeaderStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 2
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    engine.setTopic("A question worth keeping")
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "audit-s1-headers-\(UUID().uuidString)"))
    let session = URLSession(configuration: .ephemeral)
    for _ in 0..<8 {
        let port = allocateTestPort()
        let server = APIServer(engine: engine, store: store, port: port)
        try server.start()
        if await server.waitUntilReady() {
            return (server, engine, session, "http://127.0.0.1:\(port)")
        }
        server.stop()
    }
    throw HeaderTestError.noPort
}

private enum HeaderTestError: Error {
    case noPort
}

private func responseHead(_ response: HTTPResponse) -> String {
    guard let text = String(data: response.serialised(keepAlive: true), encoding: .utf8),
        let end = text.range(of: "\r\n\r\n")
    else { return "" }
    return String(text[..<end.lowerBound])
}

private func get(_ session: URLSession, _ url: String) async throws -> (Int, HTTPURLResponse, Data) {
    let (data, response) = try await session.data(for: URLRequest(url: URL(string: url)!))
    let http = try #require(response as? HTTPURLResponse)
    return (http.statusCode, http, data)
}

@Suite("The response boundary carries a policy")
@MainActor
struct AuditS1SecurityHeaderTests {

    // MARK: The headers themselves

    @Test("Every serialised response carries nosniff, a referrer policy and frame denial")
    func baselineHeadersAreOnEveryResponse() {
        for response in [HTTPResponse.json(["status": "ok"]), HTTPResponse.html("<p>hi</p>")] {
            let written = responseHead(response)
            #expect(written.contains("X-Content-Type-Options: nosniff"))
            #expect(written.contains("Referrer-Policy: no-referrer"))
            #expect(written.contains("X-Frame-Options: DENY"))
            #expect(written.contains("Content-Security-Policy:"))
            #expect(written.contains("frame-ancestors 'none'"))
        }
    }

    @Test("The interface policy has no inline grant")
    func interfacePolicyIsStrict() {
        // The value the interface is served with: `/app.js` and `/style.css` from this origin,
        // same-origin `/api` for `fetch` and `EventSource`, and no inline grant at all.
        let text = String(decoding: HTTPResponse.html("<p>hi</p>").serialised(keepAlive: true), as: UTF8.self)
        #expect(text.contains("script-src 'self'"))
        #expect(text.contains("style-src 'self'"))
        #expect(text.contains("connect-src 'self'"))
        #expect(!text.contains("'unsafe-inline'"), "the interface must not be given an inline grant")
    }

    @Test("A response that renders nothing gets a policy that loads nothing")
    func jsonPolicyIsEmpty() {
        let text = String(
            decoding: HTTPResponse.json(["status": "ok"]).serialised(keepAlive: false), as: UTF8.self)
        #expect(text.contains("default-src 'none'"))
        #expect(!text.contains("script-src"))
    }

    @Test("A response can replace the policy for a page that needs inline markup")
    func responsePolicyWins() {
        // The share page and the missing-link page override the default, which is what keeps
        // this change from breaking them.
        let replacement =
            "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
        let response = HTTPResponse(
            contentType: "text/html; charset=utf-8", body: Data(),
            headers: ["Content-Security-Policy": replacement])
        let written = responseHead(response)
        #expect(written.contains(replacement))
        #expect(!written.contains("script-src 'self';"))
    }

    // MARK: Over a real server

    @Test("The interface is served with the strict policy")
    func interfacePageIsStrictOverHTTP() async throws {
        let (server, _, session, base) = try await headerServer()
        defer { server.stop() }

        let (status, response, _) = try await get(session, "\(base)/")
        #expect(status == 200)
        #expect(response.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
        #expect(response.value(forHTTPHeaderField: "X-Frame-Options") == "DENY")
        #expect(response.value(forHTTPHeaderField: "Referrer-Policy") == "no-referrer")
        let policy = response.value(forHTTPHeaderField: "Content-Security-Policy") ?? ""
        #expect(policy.contains("script-src 'self'"))
        #expect(policy.contains("connect-src 'self'"))
        #expect(
            !policy.contains("'unsafe-inline'"),
            "the interface must not be given an inline grant")
    }

    @Test("The API carries the policy too, with nothing to load")
    func apiCarriesTheDocumentPolicy() async throws {
        let (server, _, session, base) = try await headerServer()
        defer { server.stop() }

        let (status, response, _) = try await get(session, "\(base)/api/conversations")
        #expect(status == 200)
        #expect(response.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
        let policy = response.value(forHTTPHeaderField: "Content-Security-Policy") ?? ""
        #expect(policy.hasPrefix("default-src 'none'"))
        #expect(!policy.contains("script-src"))
    }

    @Test("The share page keeps its inline stylesheet and script")
    func sharePageKeepsItsInlineMarkup() async throws {
        let (server, engine, session, base) = try await headerServer()
        defer { server.stop() }

        engine.start()
        await engine.waitUntilFinished()

        let (listStatus, _, listBody) = try await get(session, "\(base)/api/conversations")
        #expect(listStatus == 200)
        let list = try JSONSerialization.jsonObject(with: listBody) as? [[String: Any]]
        let id = try #require(list?.first?["id"] as? String, "the run should have been kept")

        let (status, response, body) = try await get(session, "\(base)/s/\(id)")
        #expect(status == 200)
        // The page really does carry the inline script, so the policy has to permit it or the
        // replay controls would be dead.
        #expect(String(decoding: body, as: UTF8.self).contains("<script>"))
        let policy = response.value(forHTTPHeaderField: "Content-Security-Policy") ?? ""
        #expect(policy.contains("script-src 'self' 'unsafe-inline'"))
        #expect(policy.contains("style-src 'self' 'unsafe-inline'"))
        #expect(policy.contains("connect-src 'none'"))
    }

    @Test("The missing-link page keeps its inline style and no script grant")
    func missingLinkPageKeepsItsInlineStyle() async throws {
        let (server, _, session, base) = try await headerServer()
        defer { server.stop() }

        let (status, response, _) = try await get(session, "\(base)/s/\(UUID().uuidString)")
        #expect(status == 404)
        let policy = response.value(forHTTPHeaderField: "Content-Security-Policy") ?? ""
        #expect(policy.contains("style-src 'unsafe-inline'"))
        #expect(!policy.contains("script-src 'unsafe-inline'"), "the page has no script")
    }
}
