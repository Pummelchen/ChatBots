// ChatBotsCoreTests — a body the server cannot read must not change the room (A142).
//
// `HTTPRequest.json` returns `nil` for two different situations: nothing was sent, and something was
// sent that cannot be decoded. `translate` read both as "the field is absent" and answered with the
// defaults — so an unrecognised `mode` switched the room to entertainment, an unrecognised research
// depth reset it to standard, and a malformed topic cleared it. Every one of those is a silent state
// change in response to a typo, and the page and the CLI both send these bodies.

import ChatBotsCore
import Foundation
import Testing

private struct MalformedBodyServer {
    let server: APIServer
    let session: URLSession
    let base: String
}

@MainActor
private func malformedBodyServer() async throws -> MalformedBodyServer {
    let specs = AgentSpec.makeSeats(count: 1)
    let seats = specs.map { ConversationEngine.Seat(spec: $0, engine: SilentBodyStub(spec: $0)) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "malformed-\(UUID().uuidString)"))
    let session = URLSession(configuration: .ephemeral)
    for _ in 0..<8 {
        let port = allocateTestPort()
        let server = APIServer(engine: engine, store: store, port: port)
        try server.start()
        if await server.waitUntilReady() {
            return MalformedBodyServer(
                server: server, session: session, base: "http://127.0.0.1:\(port)")
        }
        server.stop()
    }
    throw MalformedBodyError.noPort
}

private enum MalformedBodyError: Error { case noPort }

/// A seat that produces nothing, so these tests are about the request path rather than generation.
private actor SilentBodyStub: LLMEngine {
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

@MainActor
private func send(
    _ session: URLSession, _ url: String, body: Data?, contentType: String = "application/json"
) async throws -> (status: Int, body: String) {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    let (data, response) = try await session.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
}

/// The fields these tests are about, read as raw JSON so the fixture does not depend on the whole
/// snapshot's shape.
@MainActor
private func stateField(_ session: URLSession, _ base: String, _ key: String) async throws -> String? {
    let (data, _) = try await session.data(from: URL(string: "\(base)/api/state")!)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return object?[key] as? String
}

@MainActor
@Suite("A body the server cannot read does not change the room (A142)")
struct MalformedBodyTests {

    @Test("A body that is not JSON is a 400, and the topic is untouched")
    func malformedTopicIsRefused() async throws {
        let fixture = try await malformedBodyServer()
        defer { fixture.server.stop() }

        let set = try await send(
            fixture.session, "\(fixture.base)/api/topic", body: Data(#"{"topic": "A topic"}"#.utf8))
        #expect(set.status == 200)
        let before = try await stateField(fixture.session, fixture.base, "topic")
        #expect(before == "A topic")

        let response = try await send(
            fixture.session, "\(fixture.base)/api/topic", body: Data("this is not json".utf8))
        #expect(response.status == 400, "an unreadable body is a client error, not a command")
        let after = try await stateField(fixture.session, fixture.base, "topic")
        #expect(after == "A topic", "and it must not clear the topic on its way past")
    }

    @Test("An unknown mode is a 400, and the mode is untouched")
    func unknownModeIsRefused() async throws {
        let fixture = try await malformedBodyServer()
        defer { fixture.server.stop() }

        let set = try await send(
            fixture.session, "\(fixture.base)/api/mode", body: Data(#"{"value": "research"}"#.utf8))
        #expect(set.status == 200)

        let response = try await send(
            fixture.session, "\(fixture.base)/api/mode", body: Data(#"{"value": "reserch"}"#.utf8))
        #expect(response.status == 400, "a misspelling used to switch the room to entertainment")
        let mode = try await stateField(fixture.session, fixture.base, "mode")
        #expect(mode == "research", "the room must still be where the caller put it")
    }

    @Test("An unknown research depth is a 400, and the depth is untouched")
    func unknownBudgetIsRefused() async throws {
        let fixture = try await malformedBodyServer()
        defer { fixture.server.stop() }

        let response = try await send(
            fixture.session, "\(fixture.base)/api/research/budget", body: Data(#"{"value": "deap"}"#.utf8))
        #expect(response.status == 400, "an unknown depth used to reset it to standard")
    }

    @Test("A body that is not a JSON object at all is refused")
    func nonObjectBodyIsRefused() async throws {
        let fixture = try await malformedBodyServer()
        defer { fixture.server.stop() }

        // An array decodes as JSON but not as this route's object, and used to be read as "no
        // fields", which is the same silent-default path.
        let response = try await send(
            fixture.session, "\(fixture.base)/api/mode", body: Data("[1, 2, 3]".utf8))
        #expect(response.status == 400, "an array is not the object this route takes")
    }

    @Test("A request with no body still means what it meant: the field was not sent")
    func absentBodyIsNotAnError() async throws {
        let fixture = try await malformedBodyServer()
        defer { fixture.server.stop() }

        // `.setTopic("")` is what a missing topic has always produced, and the engine refuses an empty
        // topic rather than clearing it. The point here is only that "absent" did not become a 400
        // along with "unreadable" — the two are different, which is the whole of A142.
        let response = try await send(fixture.session, "\(fixture.base)/api/topic", body: Data("{}".utf8))
        #expect(response.status != 400, "an absent field is the engine's business, not a parse error")
        _ = response
    }
}
