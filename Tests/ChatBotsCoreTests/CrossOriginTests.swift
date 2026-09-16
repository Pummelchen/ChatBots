// ChatBotsCoreTests — a state-changing request must be same-origin JSON
//
// Before the fix, `HTTPRequest.json()` decoded the body whatever its `Content-Type` and no route
// looked at `Origin`, so any page the user visited could POST `text/plain` JSON to the engine — a
// CORS *simple request*, which skips the preflight — and have it act. `/api/seat` accepts a baseURL
// from that body, so the page could repoint a cloud seat at a host it controlled and start a run.
//
// These tests name the refusals, and the two cases that must keep working: a same-origin JSON POST
// (what the web interface sends) and a plain GET.

import Foundation
import Testing

@testable import ChatBotsCore

private actor SilentStub: LLMEngine {
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

private enum XOriginTestError: Error { case noPort }

private struct XOriginTestServer {
    let server: APIServer
    let engine: ConversationEngine
    let session: URLSession
    let base: String
}

@MainActor
private func crossOriginServer() async throws -> XOriginTestServer {
    let specs = AgentSpec.makeSeats(count: 1)
    let seats = specs.map { ConversationEngine.Seat(spec: $0, engine: SilentStub(spec: $0)) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "xorigin-\(UUID().uuidString)"))
    let session = URLSession(configuration: .ephemeral)
    for _ in 0..<8 {
        let port = allocateTestPort()
        let server = APIServer(engine: engine, store: store, port: port)
        try server.start()
        if await server.waitUntilReady() {
            return XOriginTestServer(
                server: server, engine: engine, session: session,
                base: "http://127.0.0.1:\(port)")
        }
        server.stop()
    }
    throw XOriginTestError.noPort
}

private func post(
    _ session: URLSession, _ url: String, body: String, headers: [String: String]
) async throws -> Int {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = Data(body.utf8)
    let (_, response) = try await session.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode ?? -1
}

@Suite("A state-changing request must be same-origin JSON")
@MainActor
struct CrossOriginTests {

    @Test("A cross-origin simple request cannot change state")
    func textPlainIsRefused() async throws {
        let fixture = try await crossOriginServer()
        let server = fixture.server
        let engine = fixture.engine
        let session = fixture.session
        let base = fixture.base
        defer { server.stop() }

        let status = try await post(
            session, "\(base)/api/topic", body: #"{"value":"pwned"}"#,
            headers: ["Content-Type": "text/plain"])

        #expect(status == 415, "a non-JSON content type must be refused")
        #expect(engine.topic != "pwned", "the refused request must not have changed the topic")
    }

    @Test("An Origin that is not the addressed host is refused")
    func foreignOriginIsRefused() async throws {
        let fixture = try await crossOriginServer()
        let server = fixture.server
        let engine = fixture.engine
        let session = fixture.session
        let base = fixture.base
        defer { server.stop() }

        let status = try await post(
            session, "\(base)/api/topic", body: #"{"value":"pwned"}"#,
            headers: ["Content-Type": "application/json", "Origin": "http://evil.example"])

        #expect(status == 403, "a foreign origin must be refused")
        #expect(engine.topic != "pwned")
    }

    @Test("A request the browser marks cross-site is refused")
    func crossSiteFetchIsRefused() async throws {
        let fixture = try await crossOriginServer()
        let server = fixture.server
        let engine = fixture.engine
        let session = fixture.session
        let base = fixture.base
        defer { server.stop() }

        let status = try await post(
            session, "\(base)/api/topic", body: #"{"value":"pwned"}"#,
            headers: ["Content-Type": "application/json", "Sec-Fetch-Site": "cross-site"])

        #expect(status == 403)
        #expect(engine.topic != "pwned")
    }

    // `/api/votes/clear` is used for the positive cases rather than `/api/topic`: a topic change
    // can be refused for reasons that have nothing to do with this guard (a running conversation
    // answers 409), which would make the test about the engine rather than about the boundary.
    @Test("A same-origin JSON request still reaches the engine")
    func sameOriginJSONIsAccepted() async throws {
        let fixture = try await crossOriginServer()
        let server = fixture.server
        let session = fixture.session
        let base = fixture.base
        defer { server.stop() }

        // The shape the web interface sends: JSON, and an Origin matching the host it addressed.
        let status = try await post(
            session, "\(base)/api/votes/clear", body: "{}",
            headers: ["Content-Type": "application/json", "Origin": base])

        #expect(status != 415, "a same-origin JSON POST must not be refused on content type")
        #expect(status != 403, "a same-origin POST must not be refused on origin")
        #expect(status == 200, "the guard must let a legitimate request through to the route")
    }

    @Test("A client that sends no Origin is unaffected, and GET is untouched")
    func plainClientAndGetAreUnaffected() async throws {
        let fixture = try await crossOriginServer()
        let server = fixture.server
        let session = fixture.session
        let base = fixture.base
        defer { server.stop() }

        // curl, the CLI and scripts send no Origin; requiring one would break them.
        let status = try await post(
            session, "\(base)/api/votes/clear", body: "{}",
            headers: ["Content-Type": "application/json"])
        #expect(status == 200)

        let (_, response) = try await session.data(from: URL(string: "\(base)/api/state")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}
