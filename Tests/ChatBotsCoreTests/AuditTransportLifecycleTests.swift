// ChatBotsCoreTests — a connect that fails leaves no session behind (audit A38)
//
// `connect()` assigned `self.session` after the handshake and then opened the bidirectional
// stream. When `openBidirectionalStream()` threw, the outer catch rethrew without closing or
// clearing the session, so `isConnected` (`session != nil`) reported a healthy client with no
// stream and no reader — every command threw "not connected", a caller's
// `guard client.isConnected` passed, and the server kept an admission slot per attempt.
//
// The stream-open failure itself is not reproducible from a test: the client owns the whole
// handshake-and-open sequence, and there is no seam between the two where the transport can be
// made to fail deterministically. What *is* testable, and is the same invariant, is the retry:
// a client that already holds a session and then fails to connect must not leave the old one
// assigned. That is asserted here against a real listener that has been stopped.

import ChatBotsCore
import Foundation
import Testing

/// An engine that does nothing, so these tests are about the transport.
private actor QuietStub: LLMEngine {
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

private struct RunningEngine {
    let server: WebTransportEngineServer
    let port: UInt16
    let directory: URL

    func stop() async {
        await server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func startEngine() async throws -> RunningEngine {
    let specs = (0..<2).map { index -> AgentSpec in
        var spec = AgentSpec.seat(index: index)
        spec.displayName = "Seat \(index + 1)"
        return spec
    }
    let stubs = specs.map { QuietStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    engine.setTopic("A transport lifecycle test")

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "transport-lifecycle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = ConversationStore(directory: directory)
    let service = EngineService(engine: engine, store: store)

    let identity = try CertificateStore.loadOrCreate(in: directory)
    var serverConfiguration = WebTransportEngineServer.Configuration()
    let port = allocateTestPort()
    serverConfiguration.port = port
    let server = WebTransportEngineServer(
        service: service, identity: identity, configuration: serverConfiguration)
    try await server.start()
    return RunningEngine(server: server, port: port, directory: directory)
}

@MainActor
private func makeClient(port: UInt16) -> WebTransportEngineClient {
    var configuration = WebTransportEngineClient.Configuration()
    configuration.port = port
    // Short, because one test deliberately connects to a listener that has gone: the failure
    // has to arrive as a failure rather than as a ten-second wait.
    configuration.timeoutMilliseconds = 2_000
    return WebTransportEngineClient(configuration: configuration)
}

@MainActor
@Suite("A failed connect leaves no session behind", .serialized, TransportSerialized())
struct AuditTransportLifecycleTests {

    /// The observable half of A38: a client that has a session and is asked to connect again
    /// must tear the old session down first, so a failure cannot leave `isConnected` true with
    /// nothing behind it.
    @Test("A client whose retry fails does not report itself connected")
    func failedRetryIsNotConnected() async throws {
        let running = try await startEngine()
        defer { Task { await running.stop() } }

        let client = makeClient(port: running.port)
        try await client.connect()
        #expect(client.isConnected)
        #expect(client.greeting != nil, "the greeting is connect()'s reply")

        // The listener goes away. The client's session reference survives it, which is the
        // state the finding is about: `session != nil` is not proof of a live channel.
        await running.server.stop()

        var refused = false
        do {
            try await client.connect()
        } catch {
            refused = true
        }
        #expect(refused, "connecting to a stopped listener should fail")
        #expect(
            !client.isConnected,
            "a failed connect left the previous session assigned, so isConnected lied")
        await client.disconnect()
    }
}
