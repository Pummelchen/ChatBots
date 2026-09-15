// ChatBotsCoreTests — A75: the HTTP surface grants no cross-origin access
//
// `HTTPResponse.serialised` put `Access-Control-Allow-Origin: *` on every response, the SSE head
// did the same, and `APIServer.handle` answered every `OPTIONS` preflight with `204`. A page from
// any origin could therefore read `GET /api/conversations` and POST to `/api/roster`,
// `/api/moderator`, `/api/seat` and `/api/conversations/new`, because the preflight that would
// otherwise block a JSON write succeeded.
//
// There is no cross-origin case in any supported configuration: `web/app.js` fetches relative
// paths only, so it is always same-origin; the macOS app uses WebTransport rather than the HTTP
// API; and the page and `/api` are on one origin both when Caddy serves the page and proxies the
// API, and when the engine serves the page itself. The grant is removed rather than narrowed.

import ChatBotsCore
import Foundation
import Testing

private actor CorsStub: LLMEngine {
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
        "a reply"
    }
}

/// A server on a port of its own, with its own store, so tests cannot see each other.
@MainActor
private func corsServer() async throws -> (APIServer, URLSession, String) {
    let specs = AgentSpec.makeSeats(count: 2)
    let stubs = specs.map { CorsStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    engine.setTopic("A question")
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "audit-s1-cors-\(UUID().uuidString)"))
    let session = URLSession(configuration: .ephemeral)
    for _ in 0..<8 {
        let port = allocateTestPort()
        let server = APIServer(engine: engine, store: store, port: port)
        try server.start()
        if await server.waitUntilReady() {
            return (server, session, "http://127.0.0.1:\(port)")
        }
        server.stop()
    }
    throw CorsTestError.noPort
}

private enum CorsTestError: Error {
    case noPort
}

private let crossOriginHeaders = [
    "Access-Control-Allow-Origin",
    "Access-Control-Allow-Methods",
    "Access-Control-Allow-Headers",
]

@MainActor
@Suite("The HTTP surface grants no cross-origin access")
struct AuditS1CORSTests {

    @Test("A read the audit names carries no cross-origin grant")
    func readIsNotSharedCrossOrigin() async throws {
        let (server, session, base) = try await corsServer()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "\(base)/api/conversations")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        for header in crossOriginHeaders {
            #expect(
                http.value(forHTTPHeaderField: header) == nil,
                "\(header) is still granted to every origin")
        }
    }

    @Test("A cross-origin write is not preflighted into succeeding")
    func preflightIsNotAnswered() async throws {
        let (server, session, base) = try await corsServer()
        defer { server.stop() }

        // The preflight a browser sends before a JSON POST. It must not be answered with a
        // grant: `204` plus the CORS headers is what let the write through.
        var request = URLRequest(url: URL(string: "\(base)/api/conversations/new")!)
        request.httpMethod = "OPTIONS"
        request.setValue("http://evil.example", forHTTPHeaderField: "Origin")
        request.setValue("POST", forHTTPHeaderField: "Access-Control-Request-Method")
        let (_, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode != 204, "a preflight was answered as though it were allowed")
        // This asserted 404 — "there is no OPTIONS route" — which was the pre-A136 mechanism's
        // byproduct: the request fell through to the default. A136 refuses a cross-origin request
        // explicitly instead, so the honest answer is now 403 and it names the reason. The property
        // under test is unchanged: a cross-origin write gains nothing (A209).
        #expect(http.statusCode == 403, "a cross-origin preflight must be refused as cross-origin")
        for header in crossOriginHeaders {
            #expect(http.value(forHTTPHeaderField: header) == nil)
        }
    }

    @Test("The event stream's own head grants nothing either")
    func eventStreamGrantsNothing() async throws {
        let (server, session, base) = try await corsServer()
        defer { server.stop() }

        // The SSE head is written by hand rather than through `serialised`, so it has to be
        // checked on its own — it carried `Access-Control-Allow-Origin: *` too.
        let (bytes, response) = try await session.bytes(
            for: URLRequest(url: URL(string: "\(base)/api/events")!))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        for header in crossOriginHeaders {
            #expect(http.value(forHTTPHeaderField: header) == nil)
        }
        // The stream never ends; one line is enough to know the head is real, then drop it.
        var iterator = bytes.makeAsyncIterator()
        _ = try? await iterator.next()
    }
}
