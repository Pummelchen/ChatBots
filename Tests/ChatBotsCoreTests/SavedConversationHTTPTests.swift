// ChatBotsCoreTests — reopening a kept conversation, over the wire
//
// The engine has been keeping every conversation on disk since the persistence work, and the
// commands to list, load, delete and start fresh existed with no front end asking for any of
// them. Both front ends now do, and these tests drive the requests they actually send — over a
// real socket, at the real paths, parsed as JSON — because a route table that is only exercised
// in-process is exactly how a front end ends up calling something that was never wired up.
//
// The list is also the one reply that is an array rather than a snapshot, so a front end reading
// it as `{seats: …}` would find nothing and draw an empty panel rather than an error.

import ChatBotsCore
import Foundation
import Testing

/// A seat that answers without a model, so a conversation can be run and kept in a test.
private actor KeptStub: LLMEngine {
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

/// A server on a port of its own, with its own store, so tests cannot see each other.
///
/// Ports come from the shared allocator rather than from `UUID().uuidString.hashValue % 90`,
/// which was not distinct between two tests running in parallel — so two servers occasionally
/// took the same port and one served nothing. Nondeterminism in a fixture is indistinguishable
/// from a bug in the code under test.
///
/// The retry is for whatever else is on the machine: a test that fails because something else is
/// listening is a test that lies.
@MainActor
private func liveServer(topic: String = "A question worth keeping")
    async throws -> (APIServer, ConversationEngine, URLSession, String)
{
    let specs = AgentSpec.makeSeats(count: 2)
    let stubs = specs.map { KeptStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 2
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    engine.setTopic(topic)
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "kept-\(UUID().uuidString)"))
    let session = URLSession(configuration: .ephemeral)
    for _ in 0..<8 {
        let port = allocateTestPort()
        let server = APIServer(engine: engine, store: store, port: port)
        try server.start()
        // `start()` returning is not evidence that anything is listening; a taken port is
        // reported asynchronously. Asking is the only way to know.
        if await server.waitUntilReady() {
            return (server, engine, session, "http://127.0.0.1:\(port)")
        }
        server.stop()
    }
    throw HTTPTestError.noPort
}

private enum HTTPTestError: Error {
    case noPort
}

private func get(_ session: URLSession, _ url: String) async throws -> (Int, Data) {
    var request = URLRequest(url: URL(string: url)!)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

private func post(_ session: URLSession, _ url: String, _ body: [String: String]) async throws
    -> (Int, Data)
{
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await session.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

@MainActor
@Suite("Kept conversations over HTTP")
struct SavedConversationHTTPTests {

    @Test("A conversation links a running engine to the store it is written into")
    func aConversationIsKept() async throws {
        let (server, engine, session, base) = try await liveServer()
        defer { server.stop() }

        engine.start()
        await engine.waitUntilFinished()

        let (status, data) = try await get(session, "\(base)/api/conversations")
        #expect(status == 200)
        let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(list?.count == 1, "the run should have been kept")
        #expect(list?.first?["topic"] as? String == "A question worth keeping")
        // The summary carries the count a list wants without carrying the transcript.
        #expect((list?.first?["replies"] as? Int ?? 0) >= 1)
        #expect(list?.first?["id"] as? String != nil)
    }

    @Test("A kept conversation comes back with its transcript and its topic")
    func aConversationIsReopened() async throws {
        let (server, engine, session, base) = try await liveServer()
        defer { server.stop() }

        engine.start()
        await engine.waitUntilFinished()
        let keptTurns = engine.conversation.turns.filter { $0.kind == .chat }.count

        // Clear the screen the way the front end's New button does, then reopen the kept one.
        let (newStatus, newData) = try await post(
            session, "\(base)/api/conversations/new", [:])
        #expect(newStatus == 200)
        let cleared = try JSONSerialization.jsonObject(with: newData) as? [String: Any]
        #expect((cleared?["messages"] as? [[String: Any]])?.isEmpty == true)

        let (_, listData) = try await get(session, "\(base)/api/conversations")
        let list = try JSONSerialization.jsonObject(with: listData) as? [[String: Any]]
        let id = try #require(list?.first?["id"] as? String)

        let (status, data) = try await post(
            session, "\(base)/api/conversations/load", ["value": id])
        #expect(status == 200)
        let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(snapshot?["topic"] as? String == "A question worth keeping")
        let messages = snapshot?["messages"] as? [[String: Any]] ?? []
        #expect(messages.count > keptTurns, "the topic and brief come back with the transcript")
    }

    @Test("Deleting removes it from disk, and says so by returning the shorter list")
    func aConversationIsDeleted() async throws {
        let (server, engine, session, base) = try await liveServer()
        defer { server.stop() }

        engine.start()
        await engine.waitUntilFinished()

        let (_, listData) = try await get(session, "\(base)/api/conversations")
        let list = try JSONSerialization.jsonObject(with: listData) as? [[String: Any]]
        let id = try #require(list?.first?["id"] as? String)

        let (status, data) = try await post(
            session, "\(base)/api/conversations/delete", ["value": id])
        #expect(status == 200)
        let remaining = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(remaining?.isEmpty == true, "the reply is the list, so the panel can redraw")

        let (_, after) = try await get(session, "\(base)/api/conversations")
        let settled = try JSONSerialization.jsonObject(with: after) as? [[String: Any]]
        #expect(settled?.isEmpty == true, "and it is gone on the next read, not just from the reply")
    }

    @Test("Opening something that is not there is refused, not answered with a blank conversation")
    func openingAnUnknownIdIsRefused() async throws {
        let (server, _, session, base) = try await liveServer()
        defer { server.stop() }

        let (status, data) = try await post(
            session, "\(base)/api/conversations/load", ["value": UUID().uuidString])
        // 409 rather than 500: the command was understood and refused, which is an answer.
        #expect(status == 409)
        let error = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((error?["error"] as? String)?.contains("no saved conversation") == true)
    }

    @Test("A malformed id is refused rather than deleting something at random")
    func aMalformedIdIsRefused() async throws {
        let (server, _, session, base) = try await liveServer()
        defer { server.stop() }

        let (status, data) = try await post(
            session, "\(base)/api/conversations/delete", ["value": "not-an-id"])
        #expect(status == 409)
        let error = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((error?["error"] as? String)?.contains("valid id") == true)
    }

    @Test("The reply accessors the front ends use agree with the wire format")
    func replyAccessorsMatchTheWire() {
        // The SwiftUI controller reads `reply.saved` and `reply.refusal`; the browser reads the
        // same replies as JSON. A test for one and not the other is how they drift.
        let summaries = [
            SavedConversationSummary(
                id: "1", topic: "t", summary: "s", replies: 2, updatedAt: .now, startedAt: .now)
        ]
        #expect(EngineReply.savedConversations(summaries).saved?.count == 1)
        #expect(EngineReply.refused("no").refusal == "no")
        #expect(EngineReply.savedConversations(summaries).refusal == nil)
        #expect(EngineReply.refused("no").saved == nil)
    }
}
