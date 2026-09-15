// ChatBotsCoreTests — a running engine can say what is going wrong (A151)
//
// Nothing recorded anything. `_ = error` threw a dropped connection away, a malformed request was
// answered and forgotten, and the counters the listener already kept — refused connections, held
// connections, open streams, the listener's own failure — were reachable from no endpoint. Diagnosing a
// live engine meant reading source.
//
// Now every refusal is recorded once, in a bounded ring, and `/api/health` reports the counters and the
// ring. The bound is at the source rather than at the endpoint because `/api` is unauthenticated and
// reachable from the LAN: a server anyone can poke must not keep an unbounded log of pokes.

import Foundation
import Testing

@testable import ChatBotsCore

private actor DiagnosticsStub: LLMEngine {
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
    ) async throws -> String { "" }
}

/// A running API server with the listener it owns, so a test can ask both what the socket recorded and
/// what the endpoint answers. The port travels with it rather than being parsed back out of the base URL.
private struct DiagnosticsFixture {
    let server: APIServer
    let http: HTTPServer
    let session: URLSession
    let base: String
    let port: UInt16
}

@MainActor
private func diagnosticsServer() async throws -> DiagnosticsFixture {
    let specs = AgentSpec.makeSeats(count: 2)
    let seats = specs.map { ConversationEngine.Seat(spec: $0, engine: DiagnosticsStub(spec: $0)) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    engine.setTopic("A diagnostic test")
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "diagnostics-\(UUID().uuidString)"))
    let session = URLSession(configuration: .ephemeral)
    for _ in 0..<8 {
        let port = allocateTestPort()
        let server = APIServer(engine: engine, store: store, port: port)
        try server.start()
        if await server.waitUntilReady(), let http = server.httpServer {
            return DiagnosticsFixture(
                server: server, http: http, session: session,
                base: "http://127.0.0.1:\(port)", port: port)
        }
        server.stop()
    }
    throw DiagnosticsTestError.noPort
}

private enum DiagnosticsTestError: Error {
    case noPort
}

@MainActor
@Suite("A running engine can say what is going wrong (A151)")
struct ServerDiagnosticsTests {

    @Test("The failure ring keeps the newest entries and no more than its limit")
    func theRingIsBoundedAndNewestFirst() {
        let server = HTTPServer(port: allocateTestPort(), handler: { _ in .json(["ok": "yes"]) })
        defer { server.stop() }

        #expect(server.recentFailures.isEmpty)
        for index in 1...HTTPServer.failureHistoryLimit * 2 {
            server.note("failure \(index)")
        }

        let failures = server.recentFailures
        #expect(failures.count == HTTPServer.failureHistoryLimit, "the ring grew past its bound")
        #expect(failures.first?.reason == "failure \(HTTPServer.failureHistoryLimit * 2)")
        #expect(failures.last?.reason == "failure \(HTTPServer.failureHistoryLimit + 1)")
        // Newest first, and time moves forward: what a reader wants at the top is what just happened.
        #expect(failures[0].at >= failures[1].at)
    }

    @Test("A malformed request is answered and recorded")
    func aMalformedRequestIsRecorded() async throws {
        let fixture = try await diagnosticsServer()
        defer { fixture.server.stop() }
        let http = fixture.http

        #expect(http.recentFailures.isEmpty, "nothing has gone wrong yet")
        let client = try RawConnection(port: fixture.port)
        defer { client.cancel() }
        #expect(await client.connect())
        // Not a request: one token where a request line of three parts belongs. The parser refuses it and
        // the server answers 400 — and, before this, forgot it.
        client.send("nonsense\r\n\r\n")
        let reply = try #require(await client.receiveOnce(timeout: .seconds(5)))
        #expect((String(bytes: reply, encoding: .utf8) ?? "").hasPrefix("HTTP/1.1 400"))

        let failures = http.recentFailures
        #expect(!failures.isEmpty, "the refused request left no trace")
        #expect(failures.first?.reason.hasPrefix("request:") == true, "got \(failures.first?.reason ?? "nothing")")
    }

    @Test("The health endpoint reports the counters and the recent failures")
    func theHealthEndpointReports() async throws {
        let fixture = try await diagnosticsServer()
        defer { fixture.server.stop() }

        // One real failure first, so the endpoint has something to report besides zeroes.
        fixture.http.note("connection: a client went away")

        let url = try #require(URL(string: "\(fixture.base)/api/health"))
        let (data, response) = try await fixture.session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let decoder = JSONDecoder()
        // The same wire shape the interface reads: timestamps travel as ISO 8601 text.
        decoder.dateDecodingStrategy = .iso8601
        let health = try decoder.decode(APIHealth.self, from: data)

        #expect(health.status == "ok")
        #expect(health.port == Int(fixture.port))
        #expect(health.openStreams == 0)
        #expect(health.refusedConnections == 0)
        #expect(health.listenerError == nil)
        #expect(health.connections >= 0)
        #expect(health.recentFailures.first?.reason == "connection: a client went away")
    }
}
