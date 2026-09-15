// ChatBotsCoreTests — a WebTransport server and the clients that talk to it.
//
// Extracted from `AuditS3TransportSessionRulesTests` (A157) when a second suite needed it (A158). The
// fixture knows three things the transport tests all need: a real listener with a stub engine behind it, a
// raw client that can misbehave — connect without speaking, send a payload no decoder reads — and the two
// readers that turn a stream back into frames.

import Foundation
import Testing
import WebTransportNetworkRuntime

@testable import ChatBotsCore

/// An engine that does nothing, so these tests are about the transport.
actor QuietTransportStub: LLMEngine {
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
    ) async throws -> String { "a reply" }
}

/// A seat that writes `fragments` short output events in its one turn, paced a little so the events reach
/// the wire as fast as they are made: a burst that outran the server's writer would be dropped *there*, and
/// a test about the client's own buffer would be measuring the wrong bound (A158).
actor ChattyTransportStub: LLMEngine {
    nonisolated let spec: AgentSpec
    private let fragments: Int

    init(spec: AgentSpec, fragments: Int) {
        self.spec = spec
        self.fragments = fragments
    }

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
        for index in 0..<fragments {
            await onEvent(.token(agentID: spec.id, text: "\(index % 10)"))
            try? await Task.sleep(for: .milliseconds(2))
        }
        return "the end"
    }
}

/// A server that has not been started yet, with everything `start()` needs.
struct TransportFixture {
    let server: WebTransportEngineServer
    /// The engine behind the listener, so a test can drive a burst of events through it.
    let engine: ConversationEngine
    /// The shared dispatch, for a test that wants a command to change the room.
    let service: EngineService
    let port: UInt16
    let directory: URL

    func stop() async {
        await server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
func makeTransportFixture(
    startupTimeout: TimeInterval = 30, maximumConnections: Int = 16, maximumTurns: Int = 40,
    engines makeEngine: (AgentSpec) -> any LLMEngine = { QuietTransportStub(spec: $0) }
) async throws -> TransportFixture {
    let specs = AgentSpec.makeSeats(count: 1)
    let seats = specs.map { ConversationEngine.Seat(spec: $0, engine: makeEngine($0)) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = maximumTurns
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    engine.setTopic("A transport rule test")

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "transport-rules-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let service = EngineService(engine: engine, store: ConversationStore(directory: directory))
    let identity = try CertificateStore.loadOrCreate(in: directory)

    var serverConfiguration = WebTransportEngineServer.Configuration()
    let port = allocateTestPort()
    serverConfiguration.port = port
    serverConfiguration.sessionStartupTimeout = startupTimeout
    serverConfiguration.maximumConnections = maximumConnections
    return TransportFixture(
        server: WebTransportEngineServer(
            service: service, identity: identity, configuration: serverConfiguration),
        engine: engine, service: service, port: port, directory: directory)
}

/// A raw client, so a test can connect without speaking or send a payload no decoder can read.
@MainActor
func connectRaw(
    to port: UInt16
) async throws -> (
    client: WebTransportQUICClient, session: WebTransportNetworkSession,
    stream: WebTransportNetworkBidirectionalStream
) {
    let client = WebTransportQUICClient(trustPolicy: .localDevelopmentSelfSigned)
    let session = try await client.connectSession(
        to: WebTransportNetworkEndpoint(host: "127.0.0.1", port: port),
        authority: "localhost",
        path: "/chatbots",
        origin: nil,
        protocols: [],
        optimisticCapsules: [],
        settingsValidation: .draft16Strict,
        timeoutMilliseconds: 5_000)
    let stream = try await session.openBidirectionalStream(timeoutMilliseconds: 5_000)
    return (client, session, stream)
}

@MainActor
func makeEngineClient(port: UInt16, timeoutMilliseconds: Int32 = 4_000)
    -> WebTransportEngineClient
{
    var configuration = WebTransportEngineClient.Configuration()
    configuration.port = port
    configuration.timeoutMilliseconds = timeoutMilliseconds
    return WebTransportEngineClient(configuration: configuration)
}

/// The next frame, or nil when the stream ends first.
///
/// One buffer for the whole read, because a frame can be split across reads and the framing holds partial
/// messages — the same rule the server follows.
@MainActor
func readFrame(
    from stream: WebTransportNetworkBidirectionalStream, within timeout: Duration = .seconds(5)
) async throws -> EngineFrame? {
    var buffer = Data()
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        let chunk = try await stream.receive(maximumBytes: 64 * 1024, timeoutMilliseconds: 1_500)
        if chunk.isEmpty { return nil }
        buffer.append(chunk)
        if case .message(let payload, let remainder) = try LengthFraming.read(from: buffer) {
            buffer = remainder
            return try ProtocolCodec.decodeFrame(payload)
        }
    }
    return nil
}

/// The next reply, skipping the state pushes the server sends unprompted.
@MainActor
func readReply(
    from stream: WebTransportNetworkBidirectionalStream, within timeout: Duration = .seconds(5)
) async throws -> EngineReply? {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        guard let frame = try await readFrame(from: stream, within: .seconds(2)) else { return nil }
        if let reply = frame.asReply { return reply }
    }
    return nil
}
