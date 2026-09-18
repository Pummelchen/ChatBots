// ChatBotsCoreTests — a running engine behind an HTTP server, for tests that drive its routes over a
// real socket.
//
// Extracted from `MalformedBodyTests` when a second suite needed it. The two are
// about the same rule one step apart: a body the server cannot read must not change the room, whether
// it cannot be read because it is not the JSON the route takes or because the framing around it was
// never decoded.

import ChatBotsCore
import Foundation
import Testing

struct APIServerFixture {
    let server: APIServer
    let session: URLSession
    let base: String
    /// The port again, because a test driving the socket by hand needs the number rather than a URL.
    let port: UInt16
}

/// A seat that produces nothing, so the tests that use it are about the request path rather than
/// generation.
actor SilentSeatStub: LLMEngine {
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

enum APIServerFixtureError: Error { case noPort }

/// Start an engine with `seats` silent seats on a free port.
///
/// The seat count matters to the readiness tests, which are not here: one seat is what the request-path
/// tests need, and the loop over candidate ports is because a port can be taken between the probe and
/// the bind.
@MainActor
func makeAPIServerFixture(seats: Int = 1, sessionToken: String? = nil) async throws -> APIServerFixture {
    let specs = AgentSpec.makeSeats(count: seats)
    let made = specs.map { ConversationEngine.Seat(spec: $0, engine: SilentSeatStub(spec: $0)) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    let engine = ConversationEngine(seats: made, configuration: configuration)
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "api-fixture-\(UUID().uuidString)"))
    let session = URLSession(configuration: .ephemeral)
    for _ in 0..<8 {
        let port = allocateTestPort()
        let server = APIServer(
            engine: engine, store: store, port: port, sessionToken: sessionToken)
        try server.start()
        if await server.waitUntilReady() {
            return APIServerFixture(
                server: server, session: session, base: "http://127.0.0.1:\(port)", port: port)
        }
        server.stop()
    }
    throw APIServerFixtureError.noPort
}

/// The fields a test is about, read as raw JSON so the fixture does not depend on the whole
/// snapshot's shape.
@MainActor
func stateField(_ session: URLSession, _ base: String, _ key: String) async throws -> String? {
    let url = try #require(URL(string: "\(base)/api/state"))
    let (data, _) = try await session.data(from: url)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return object?[key] as? String
}

/// One seat's display name from the snapshot, for the tests about a change that was refused.
@MainActor
func seatName(_ session: URLSession, _ base: String, id: String) async throws -> String? {
    let url = try #require(URL(string: "\(base)/api/state"))
    let (data, _) = try await session.data(from: url)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let seats = object?["seats"] as? [[String: Any]]
    return seats?.first { $0["id"] as? String == id }?["name"] as? String
}
