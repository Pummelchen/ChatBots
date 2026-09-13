// ChatBotsCoreTests — the transport the desktop app actually talks over
//
// The engine's dispatch is tested without a socket elsewhere. These tests are the opposite:
// they start a real WebTransport listener on a real UDP port and connect to it with the real
// client. Every failure this file exists for was invisible to a dispatch test.
//
// A note on how to read them. The client owns its reader: `connect()` starts one task that
// consumes the stream and routes each frame to the reply waiter or to `client.events`. The
// tests that want a reply use `state()` or `send`, which is a round trip through that reader.
// The one test that wants a *push* reads `client.events`, because that stream is where the
// reader puts what it was sent — and it takes a fresh connection, so it is the only consumer.

import ChatBotsCore
import Foundation
import Testing

/// An engine that does nothing, so these tests are about the transport rather than generation.
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

/// A running engine, for the duration of one test.
private struct RunningEngine {
    let service: EngineService
    let server: WebTransportEngineServer
    let port: UInt16
    let directory: URL

    func stop() async {
        await server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Start a real listener on a port of its own.
@MainActor
private func startEngine(maximumConnections: Int? = nil) async throws -> RunningEngine {
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
    engine.setTopic("A transport test")

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "transport-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = ConversationStore(directory: directory)
    let service = EngineService(engine: engine, store: store)

    // Generated rather than shipped: a certificate in the repository would be a private key in
    // the repository.
    let identity = try CertificateStore.loadOrCreate(in: directory)
    var serverConfiguration = WebTransportEngineServer.Configuration()
    let port = allocateTestPort()
    serverConfiguration.port = port
    if let maximumConnections {
        serverConfiguration.maximumConnections = maximumConnections
    }
    let server = WebTransportEngineServer(
        service: service, identity: identity, configuration: serverConfiguration)
    try await server.start()
    return RunningEngine(service: service, server: server, port: port, directory: directory)
}

@MainActor
private func makeClient(port: UInt16) -> WebTransportEngineClient {
    var configuration = WebTransportEngineClient.Configuration()
    configuration.port = port
    configuration.timeoutMilliseconds = 6_000
    return WebTransportEngineClient(configuration: configuration)
}

@MainActor
@Suite("Engine transport", .serialized)
struct WebTransportSessionTests {

    @Test("A client can ask the engine for its state and get it")
    func stateRoundTrip() async throws {
        let running = try await startEngine()
        defer { Task { await running.stop() } }

        let client = makeClient(port: running.port)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        let snapshot = try #require(await client.state())
        #expect(snapshot.seats.count == 2)
        #expect(snapshot.topic == "A transport test")
    }

    /// A pause between connecting and the first request does not cost the client its session.
    ///
    /// `connect()` writes one frame, and then a caller may sit on the connection before asking
    /// anything. Nothing about that idle gap should drop it — the app connects on launch and the
    /// user may not touch it for a while, and the supervisor's probe is deliberately a
    /// connect-ask-close in quick succession.
    ///
    /// The greeting assertion is the other half: it comes from the reply to the frame `connect()`
    /// sends, which is there because the engine does not serve the stream, and so pushes nothing,
    /// until a byte arrives. WebTransport#24 is why that is the reason rather than the stream
    /// prefix.
    @Test("A client is still served after sitting idle on its connection")
    func idleClientIsStillServed() async throws {
        let running = try await startEngine()
        defer { Task { await running.stop() } }

        let client = makeClient(port: running.port)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        try? await Task.sleep(for: .seconds(1))

        let snapshot = try #require(await client.state())
        #expect(snapshot.topic == "A transport test")
        #expect(client.greeting?.topic == "A transport test", "the greeting is connect()'s reply")
    }

    /// The supervisor's probe, then the app's real connection.
    ///
    /// This is the sequence that produced "the app connects but the thread stays empty": the
    /// supervisor probes for an engine, and only then does the app connect for real. The probe
    /// must leave nothing behind — both because the app's connection has to be the one the
    /// engine serves, and because a probe that leaks its session costs the next connection a
    /// socket.
    @Test("After probing, the real client still reaches the engine")
    func probeThenConnect() async throws {
        let running = try await startEngine()
        defer { Task { await running.stop() } }

        // Five rounds, each a connect and a clean close: what `isEngineAnswering` does over a
        // slow startup, plus the retries around it.
        for _ in 0..<5 {
            let probe = makeClient(port: running.port)
            try await probe.connect()
            let answered = try await probe.state()
            #expect(answered != nil)
            await probe.disconnect()
        }
        // The server drops each session when its reader sees the connection go, which is a
        // moment after the client has closed it.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while running.server.sessionCount > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(running.server.sessionCount == 0)

        let client = makeClient(port: running.port)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        let snapshot = try #require(await client.state())
        #expect(snapshot.topic == "A transport test")
    }

    /// The engine takes a new client after the last one has gone, over and over, against a
    /// ceiling far below the number of connections it is asked to serve.
    ///
    /// Sequentially, not simultaneously, and the difference is the point. Two *concurrently
    /// connected* WebTransport clients from one process is not something this transport or
    /// Network.framework does here: the second `nw_connection` is refused by the kernel with
    /// `POSIXErrorCode 12 - Cannot allocate memory` even when the listener will accept it, and
    /// with a limit far above two. That is a property of the platform rather than of this code,
    /// and the desktop app never does it — it holds one connection per engine, and the website
    /// does not use this transport at all.
    ///
    /// So the ceiling is what makes this a regression test rather than a smoke test. Until
    /// WebTransport 1.3.7, `maxConcurrentConnections` was a budget for the listener's *whole
    /// life*: a ceiling of four served four connections and then refused everything forever, and
    /// this project carried a 4096 ceiling to hide that. Twenty-four sequential connections
    /// against a ceiling of four is the shape that proves the slot is now returned — nothing here
    /// is concurrent, so all twenty-four have to be admitted.
    @Test("The engine serves a new client after the previous one has gone")
    func clientAfterClient() async throws {
        let ceiling = 4
        let running = try await startEngine(maximumConnections: ceiling)
        defer { Task { await running.stop() } }

        for round in 0..<24 {
            // Let the previous session finish being torn down before the next arrives, so this
            // tests the listener returning a slot rather than how fast a close propagates. The
            // wait is bounded: if slots were never returned, `sessionCount` would stay pinned at
            // the ceiling, the deadline would pass, and the connect below would fail — which is
            // the failure this test exists for.
            let settle = ContinuousClock.now.advanced(by: .seconds(5))
            while running.server.sessionCount >= ceiling, ContinuousClock.now < settle {
                try? await Task.sleep(for: .milliseconds(20))
            }

            let client = makeClient(port: running.port)
            try await client.connect()
            let snapshot = try await client.state()
            #expect(snapshot?.topic == "A transport test", "round \(round) got no state")
            await client.disconnect()
        }
        // Every client let go of its session. The last one's teardown is observed by the
        // server's reader, not by `disconnect()` returning, so this is waited for rather than
        // assumed — and the wait is what makes it an assertion about a leak instead of a race
        // with one.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while running.server.sessionCount > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(running.server.sessionCount == 0)
    }

    @Test("A command over the transport changes the engine state")
    func requestChangesState() async throws {
        let running = try await startEngine()
        defer { Task { await running.stop() } }

        let client = makeClient(port: running.port)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        let reply = try await client.send(.setTopic("A new subject"))
        #expect(reply.snapshot?.topic == "A new subject")

        // And the change is visible to the next reader, not only in the reply.
        let after = try await client.state()
        #expect(after?.topic == "A new subject")
    }

    /// The push path, which is what makes the thread view update without being asked.
    ///
    /// A change made by anyone is broadcast to every attached session. This is asserted
    /// through `client.events`, which the client's reader fills — not by reading the transport
    /// directly, which would compete with that reader for the same frames.
    @Test("A change is pushed to an attached client")
    func changeIsPushed() async throws {
        let running = try await startEngine()
        defer { Task { await running.stop() } }

        let client = makeClient(port: running.port)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        // Connect pushes the current state, so the stream is already carrying something. Take
        // that first, so the assertion below is about the change rather than the greeting.
        // The connection is subscribed the moment its stream exists, which is the whole point
        // of the transport: a change made anywhere reaches this client without it asking.
        let greeting = await nextState(from: client, within: .seconds(6))
        #expect(greeting?.topic == "A transport test")

        // A change made on the engine's behalf, as another front end or a timer would make it.
        _ = await running.service.handle(.setTopic("Changed elsewhere"))

        let pushed = await nextState(from: client, within: .seconds(6))
        #expect(pushed?.topic == "Changed elsewhere")
        #expect(pushed?.topic == "Changed elsewhere")
    }

    /// A request the framing will not carry fails at the sender, with the size named, and the
    /// session it was going to travel on is still usable afterwards.
    ///
    /// The shape this replaces: `LengthFraming.read` threw `messageTooLarge`, `try?` discarded
    /// it, the buffer was never consumed, and every later frame was unreachable — a session
    /// that stayed connected and answered nothing for the rest of its life. It was not only
    /// adversarial: the protocol cap was 32 MB while the engine accepted 64 MB attachments, and
    /// the request base64-encodes, so a legitimate upload over roughly 24 MB hit it.
    @Test("A request too large to frame fails at the sender and leaves the session usable")
    func oversizeRequestFailsFast() async throws {
        let running = try await startEngine()
        defer { Task { await running.stop() } }

        let client = makeClient(port: running.port)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        // Over the cap once the bytes are base64-encoded into the request JSON.
        let contents = Data(repeating: 0x41, count: ProtocolLimits.maximumMessageBytes)
        do {
            _ = try await client.send(.addAttachment(filename: "too-large.bin", contents: contents))
            Issue.record("an over-cap request should fail at the sender")
        } catch let error as WebTransportEngineClient.ClientError {
            // The reason names the limit rather than the request timeout: the sender refused it,
            // it did not sit on a session that would never answer.
            #expect(error.errorDescription?.contains("refused") == true)
            #expect(error.errorDescription?.contains("did not answer") == false)
        }

        // Not hung, and not desynced: the same connection still answers.
        let snapshot = try #require(await client.state())
        #expect(snapshot.topic == "A transport test")
    }
}

/// The next pushed state, or `nil` if none arrived in time.
///
/// A direct `next()` on an empty stream waits forever, which in a test is a hang rather than a
/// failure, so the wait is raced against a deadline.
@MainActor
private func nextState(
    from client: WebTransportEngineClient, within timeout: Duration
) async -> APISnapshot? {
    guard let stream = client.events else { return nil }
    return await withTaskGroup(of: APISnapshot?.self) { group in
        group.addTask {
            for await event in stream {
                if case .state(let snapshot) = event { return snapshot }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
