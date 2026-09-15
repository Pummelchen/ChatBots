// ChatBotsCoreTests — the transport listener's session rules (A157).
//
// Four things the WebTransport listener did not do, all of them the HTTP listener's job two findings
// earlier:
//
//   * it had no deadline at all, so a client that connected and said nothing held one of the sixteen
//     connection slots for as long as its connection ticked — and sixteen of those are the whole budget;
//   * one `lastSessionError` per server was overwritten by concurrent sessions, and nothing read it;
//   * a frame that neither decoder could read was dropped in silence, where the neighbouring framing
//     branch answered with the reason and closed;
//   * a second `start()` overwrote `listener` and `acceptTask` without stopping the first.
//
// The first two need a client that misbehaves on purpose — one that connects and never speaks, one that
// sends a payload no decoder can read — which `ChatBotsCore`'s own client cannot do. So this file speaks
// the transport's own protocol through the library, which is why the test target depends on it.

import Foundation
import Testing
import WebTransportNetworkRuntime

@testable import ChatBotsCore

/// An engine that does nothing, so these tests are about the transport.
private actor QuietTransportStub: LLMEngine {
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

/// A server that has not been started yet, with everything `start()` needs.
private struct TransportFixture {
    let server: WebTransportEngineServer
    let port: UInt16
    let directory: URL

    func stop() async {
        await server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func makeTransportFixture(
    startupTimeout: TimeInterval = 30, maximumConnections: Int = 16
) async throws -> TransportFixture {
    let specs = AgentSpec.makeSeats(count: 1)
    let seats = specs.map { ConversationEngine.Seat(spec: $0, engine: QuietTransportStub(spec: $0)) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
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
        port: port, directory: directory)
}

/// A raw client, so a test can connect without speaking or send a payload no decoder can read.
@MainActor
private func connectRaw(
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
private func makeEngineClient(port: UInt16, timeoutMilliseconds: Int32 = 4_000)
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
private func readFrame(
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
private func readReply(
    from stream: WebTransportNetworkBidirectionalStream, within timeout: Duration = .seconds(5)
) async throws -> EngineReply? {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        guard let frame = try await readFrame(from: stream, within: .seconds(2)) else { return nil }
        if let reply = frame.asReply { return reply }
    }
    return nil
}

@MainActor
@Suite("The transport keeps the reasons its sessions ended (A157)")
struct SessionErrorRingTests {

    @Test("The ring is bounded, newest first, and lastSessionError is its head")
    func theRingIsBoundedAndNewestFirst() async throws {
        // One slot used to hold the most recent reason, so concurrent sessions overwrote each other's —
        // a client that disconnected for two different reasons left only the second, which cannot describe
        // "it keeps disconnecting".
        let fixture = try await makeTransportFixture()
        defer { TransportTeardown.register { await fixture.stop() } }

        #expect(fixture.server.recentSessionErrors.isEmpty)
        #expect(fixture.server.lastSessionError == nil)
        for index in 1...WebTransportEngineServer.sessionErrorHistoryLimit * 2 {
            fixture.server.note("session \(index) ended")
        }

        let errors = fixture.server.recentSessionErrors
        #expect(errors.count == WebTransportEngineServer.sessionErrorHistoryLimit, "the ring grew past its bound")
        // `#require` rather than `#expect` for the length: the two orderings below index the array, and a
        // short ring must fail this test rather than trap and take the whole process with it (measured: the
        // "one slot instead of a ring" mutation did exactly that).
        try #require(errors.count >= 2, "the ring is too short to say anything about its order")
        #expect(errors.first?.reason == "session \(WebTransportEngineServer.sessionErrorHistoryLimit * 2) ended")
        #expect(errors.last?.reason == "session \(WebTransportEngineServer.sessionErrorHistoryLimit + 1) ended")
        #expect(fixture.server.lastSessionError == errors.first?.reason, "the head is the last error")
        #expect(errors[0].at >= errors[1].at, "time moves forward in the ring")
    }
}

@MainActor
@Suite("A session that never finishes a frame gives its slot back (A157)", .serialized, TransportSerialized())
struct SilentSessionTests {

    @Test("One byte is not a request, and cannot hold the only connection slot")
    func aHalfSentFrameIsReaped() async throws {
        // Measured before the fix, and the finding's premise needed correcting: a client that connects and
        // sends *nothing* never reaches the server's session table and does **not** hold a slot — with
        // `maximumConnections = 1`, a second connection was admitted and the silent client never saw a state
        // push. One byte is enough: the server serves the session (11,890 bytes of state were pushed to it),
        // it holds the only slot, and with no deadline it kept it — the QUIC idle timeout never fires,
        // because the server is the one talking.
        // Four seconds, not one: the "while it holds the slot" attempt below has to happen well inside the
        // deadline, or the test races the reaper and fails for the wrong reason.
        let fixture = try await makeTransportFixture(startupTimeout: 4, maximumConnections: 1)
        defer { TransportTeardown.register { await fixture.stop() } }
        try await fixture.server.start()

        let (_, session, stream) = try await connectRaw(to: fixture.port)
        defer { TransportTeardown.register { try? await session.close(applicationErrorCode: 0) } }
        // A partial length prefix: a frame has begun and will never be finished.
        try await stream.send(Data([0x00]))

        // The server has the session: it pushes the current state as soon as the stream exists.
        guard let first = try await readFrame(from: stream, within: .seconds(5)) else {
            Issue.record("the server never served the session")
            return
        }
        #expect(first.asEvent != nil, "the first frame should be the unprompted state push")

        // While it holds the only slot, the app's own client is refused. That is the harm, measured.
        let blocked = makeEngineClient(port: fixture.port, timeoutMilliseconds: 1_500)
        var admitted = false
        do {
            try await blocked.connect()
            admitted = true
        } catch {
            // Expected: the budget is one and the half-sent frame has it.
        }
        await blocked.disconnect()
        #expect(!admitted, "a second connection was admitted while a half-sent frame held the only slot")

        // After the deadline the slot is back: a real client connects and is served.
        let healthy = makeEngineClient(port: fixture.port)
        defer { TransportTeardown.register { await healthy.disconnect() } }
        var connected = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while ContinuousClock.now < deadline, !connected {
            do {
                try await healthy.connect()
                connected = true
            } catch {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        #expect(connected, "the half-sent frame never gave its slot back")
        #expect(try await healthy.state() != nil, "the client that got the slot was not served")

        let reasons = fixture.server.recentSessionErrors.map(\.reason)
        #expect(
            reasons.contains { $0.contains("did not finish a frame") },
            "the server should say why it closed the session: \(reasons)")
    }

    @Test("A client that sends a whole frame is not touched by the deadline")
    func aFinishedFrameKeepsTheSession() async throws {
        // The counterweight. A deadline that also reaped working clients would break every real one: the app
        // sends `.fetchState` and then says nothing at all for as long as the conversation runs.
        let fixture = try await makeTransportFixture(startupTimeout: 1)
        defer { TransportTeardown.register { await fixture.stop() } }
        try await fixture.server.start()

        let (_, session, stream) = try await connectRaw(to: fixture.port)
        defer { TransportTeardown.register { try? await session.close(applicationErrorCode: 0) } }
        try await stream.send(
            try LengthFraming.frameChecked(try ProtocolCodec.encode(EngineRequest.fetchState)))

        guard case .state? = try await readReply(from: stream) else {
            Issue.record("a whole frame was not answered")
            return
        }
        // Well past the deadline, the session is still there: ask it something else and be answered.
        try? await Task.sleep(for: .seconds(2))
        try await stream.send(
            try LengthFraming.frameChecked(try ProtocolCodec.encode(EngineRequest.fetchState)))
        guard case .state? = try await readReply(from: stream) else {
            Issue.record("the deadline closed a session that had spoken")
            return
        }
        #expect(fixture.server.recentSessionErrors.isEmpty, "a working session was recorded as an error")
    }
}

@MainActor
@Suite("A frame the server cannot read is answered (A157)", .serialized, TransportSerialized())
struct UndecodableFrameTests {

    @Test("A payload no decoder can read is answered with the reason, and the session lives on")
    func anUndecodableFrameIsAnswered() async throws {
        let fixture = try await makeTransportFixture(startupTimeout: 10)
        defer { TransportTeardown.register { await fixture.stop() } }
        try await fixture.server.start()

        let (_, session, stream) = try await connectRaw(to: fixture.port)
        defer { TransportTeardown.register { try? await session.close(applicationErrorCode: 0) } }

        // Well framed, so the length prefix is intact and later frames are reachable — and not a request in
        // either spelling. This used to be dropped: no reply, no close, nothing said.
        let garbage = try LengthFraming.frameChecked(Data("this is not a request".utf8))
        try await stream.send(garbage)

        guard case .failed(let reason)? = try await readReply(from: stream) else {
            Issue.record("an undecodable frame was answered with nothing")
            return
        }
        #expect(reason.contains("Could not decode"), "the reason should be the codec's: \(reason)")

        // And because the framing was never in doubt, the session is still usable: a real request after the
        // garbage is served, which is the difference between this branch and the framing one.
        let request = try LengthFraming.frameChecked(try ProtocolCodec.encode(EngineRequest.fetchState))
        try await stream.send(request)
        guard case .state? = try await readReply(from: stream) else {
            Issue.record("the session was unusable after an undecodable frame")
            return
        }
    }
}

@MainActor
@Suite("A second start does not leave the first listening (A157)", .serialized, TransportSerialized())
struct DoubleStartTests {

    @Test("Starting twice keeps one listener, and stop() ends it")
    func aSecondStartReplacesTheFirst() async throws {
        let fixture = try await makeTransportFixture()
        defer { TransportTeardown.register { await fixture.stop() } }

        try await fixture.server.start()
        // The second start replaces the first. Before the fix this overwrote `listener` and `acceptTask`
        // without stopping anything, so whichever listener was left behind could never be shut down — and
        // `stop()` would then leave a client able to connect to a server that had been told to stop.
        try await fixture.server.start()

        let client = makeEngineClient(port: fixture.port)
        try await client.connect()
        #expect(try await client.state() != nil, "the surviving listener did not serve a client")
        await client.disconnect()

        await fixture.server.stop()

        // Nothing may be listening now. A leaked first listener answers here, which is the whole of the
        // finding: a server that has stopped is still serving.
        let after = makeEngineClient(port: fixture.port, timeoutMilliseconds: 2_000)
        var stillServing = false
        do {
            try await after.connect()
            stillServing = true
        } catch {
            // Expected.
        }
        await after.disconnect()
        #expect(!stillServing, "a listener was still serving after stop()")
    }
}
