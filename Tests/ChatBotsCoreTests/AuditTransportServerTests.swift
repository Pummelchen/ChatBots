// ChatBotsCoreTests — stopping the WebTransport engine stops its sessions (audit A40)
//
// `stop()` cancelled only `acceptTask`, finished the subscribers and called
// `listener.shutdown()`. Each session's `serve` task was untracked and uncancelled, `serve`
// never closed its session, and the library documents `shutdown()` as severing nothing cleanly.
// So a connected client kept its receive loop, kept driving the shared `EngineService` and
// kept its admission slot after the server had been told to stop.
//
// The test asks the only question that matters from outside: after `stop()` returns, can the
// connected client still be served? Before the fix it could, indefinitely.

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
    engine.setTopic("A server shutdown test")

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "server-shutdown-\(UUID().uuidString)")
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
    // Short, so a send into a session that no longer answers is reported rather than waited
    // out for the polling loop's whole deadline.
    configuration.timeoutMilliseconds = 2_000
    return WebTransportEngineClient(configuration: configuration)
}

@MainActor
@Suite("Stopping the engine stops its sessions", .serialized, TransportSerialized())
struct AuditTransportServerTests {

    @Test("A connected client is no longer served after the server stops")
    func stoppedServerStopsServing() async throws {
        let running = try await startEngine()
        defer { Task { await running.stop() } }

        let client = makeClient(port: running.port)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        #expect(running.server.sessionCount == 1, "the session should be subscribed")
        let before = try await client.state()
        #expect(before?.topic == "A server shutdown test")

        await running.server.stop()
        #expect(running.server.sessionCount == 0)

        // Before the fix the serve task was still looping, so every one of these would have
        // been answered by the shared engine: the session outlived the server that owned it.
        var refused = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            do {
                _ = try await client.state()
            } catch {
                refused = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(refused, "a stopped server was still answering a live session")
    }
}
