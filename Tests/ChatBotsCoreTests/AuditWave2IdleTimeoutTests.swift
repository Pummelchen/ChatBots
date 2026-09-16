// ChatBotsCoreTests — A100: the reader's idle timeout is its own value
//
// The client handed `configuration.timeoutMilliseconds` — the request deadline — to the
// transport session, and the transport applies a session's timeout to every stream receive as
// well as to connect. A stream that stayed silent longer than one request therefore killed the
// reader: measured with a 2-second client timeout, the reader died after 2 seconds of engine
// work. At the shipped 10-second default it is reachable in ordinary use, because A15 moved
// document conversion off the main actor, so a conversion can legitimately exceed ten seconds —
// and the command then reported a connection failure while `isConnected` stayed true.
//
// The fix uses the runtime's per-stream timeout override: the connect keeps the request
// deadline (so a listener that is not there still fails fast) and the stream gets its own
// `idleTimeoutMilliseconds`. These tests drive a real listener: a stream that is merely quiet
// must survive past the request deadline, and a channel whose peer has gone must still fail.

import ChatBotsCore
import Foundation
import Testing

/// An engine that does nothing, so the only frames on the wire are the ones the transport
/// itself sends.
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
    engine.setTopic("An idle-timeout test")

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "idle-timeout-\(UUID().uuidString)")
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
private func poll(
    timeout: Duration = .seconds(10),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
@Suite("A silent stream is not killed by the request timeout (A100)", .serialized, TransportSerialized())
struct AuditWave2IdleTimeoutTests {

    /// The finding itself. The stream is quiet for twice the request deadline, which under the
    /// old shared timeout killed the reader; then the same client must still answer.
    @Test("A stream quiet past the request deadline is still connected")
    func silentStreamSurvives() async throws {
        let running = try await startEngine()
        defer { TransportTeardown.register { await running.stop() } }

        var configuration = WebTransportEngineClient.Configuration()
        configuration.port = running.port
        configuration.timeoutMilliseconds = 1_500
        configuration.idleTimeoutMilliseconds = 5_000
        let client = WebTransportEngineClient(configuration: configuration)

        try await client.connect()
        #expect(client.isConnected)
        #expect(client.greeting != nil)

        // Longer than one request deadline, shorter than the idle one, with nothing asked and
        // nothing pushed.
        try await Task.sleep(for: .seconds(3))

        #expect(
            client.readerError == nil,
            "the reader died on silence: \(client.readerError ?? "no reason")")
        #expect(client.isConnected, "a silent stream must not tear the session down")

        // And it is genuinely usable, not merely not-yet-failed.
        let snapshot = try await client.state()
        #expect(snapshot != nil, "the engine did not answer after the quiet period")
        await client.disconnect()
    }

    /// The other half: a stream whose peer has gone must still be reported as dead, so the
    /// longer idle deadline does not turn a broken channel into a silent one.
    @Test("A channel whose peer has gone still fails")
    func deadChannelStillFails() async throws {
        let running = try await startEngine()

        var configuration = WebTransportEngineClient.Configuration()
        configuration.port = running.port
        configuration.timeoutMilliseconds = 1_500
        configuration.idleTimeoutMilliseconds = 5_000
        let client = WebTransportEngineClient(configuration: configuration)

        try await client.connect()
        #expect(client.isConnected)

        // The listener and its live sessions go away.
        await running.server.stop()
        try? FileManager.default.removeItem(at: running.directory)

        // The reader must notice rather than sitting on a quiet-but-dead stream: the pending
        // receive runs out its idle deadline and `read` reports the timeout.
        let noticed = await poll(timeout: .seconds(12)) { client.readerError != nil }
        #expect(
            noticed,
            "the reader never noticed that the peer had gone; a dead channel stayed silent")

        await client.disconnect()
    }
}
