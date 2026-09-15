// ChatBotsCoreTests — replies are matched to requests, not to queue position (audit A39)
//
// The client appended a continuation per send and the reader gave every reply to
// `pendingReplies.first`, then each completing send removed the first. The file *claimed*
// "only one pending reply at a time" and enforced nothing. `ChatController` polls `state()` at
// 1 Hz beside the user's commands, so two sends overlap routinely; the two `stream.send` calls
// can reach the wire in either order, and a reply was then delivered to the wrong waiter or
// dropped. The client reported "the engine did not answer" for a reply it had actually received.
//
// The crossing is made deterministic here without a race in the test: a slow conversion makes
// one request time out and leave its reply owed, and the next request is already waiting when
// that reply arrives. A reply for the first request reaching the second is exactly the defect,
// and `listRosters` is used because its answer cannot be mistaken for anything else.

import ChatBotsCore
import Dispatch
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

/// An extractor held open by the test, so a request can outlive the client's patience while the
/// engine is still working on it.
private struct BlockingExtractor: DocumentExtracting {
    let entered: DispatchSemaphore
    let release: DispatchSemaphore

    func extract(data: Data, from url: URL, kind: DocumentKind, limits: AttachmentLimits) throws
        -> AttachedDocument
    {
        _ = entered.signal()
        // Bounded, so a test that fails before it signals cannot wedge the suite.
        _ = release.wait(timeout: .now() + 20)
        return AttachedDocument(name: "", kind: kind, text: "the slow document's text")
    }
}

/// Wait for a semaphore without blocking the main actor.
private func waitForSignal(_ semaphore: DispatchSemaphore, timeout: DispatchTime) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            switch semaphore.wait(timeout: timeout) {
            case .success: continuation.resume(returning: true)
            case .timedOut: continuation.resume(returning: false)
            }
        }
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
private func startEngine(ingestor: DocumentIngestor) async throws -> RunningEngine {
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
    engine.setTopic("A reply-matching test")

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "reply-matching-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = ConversationStore(directory: directory)
    let service = EngineService(engine: engine, store: store, attachmentIngestor: { ingestor })

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
private func makeClient(port: UInt16, timeoutMilliseconds: Int32 = 10_000)
    -> WebTransportEngineClient
{
    var configuration = WebTransportEngineClient.Configuration()
    configuration.port = port
    configuration.timeoutMilliseconds = timeoutMilliseconds
    return WebTransportEngineClient(configuration: configuration)
}

@MainActor
@Suite("Replies are matched to requests", .serialized, TransportSerialized())
struct AuditReplyMatchingTests {

    /// The defect, deterministically. Request A is a conversion held open by the test, so A can
    /// be abandoned while its reply is still owed — its task is cancelled, which is the other
    /// way a wait ends besides the timeout, and the one that does not also expire the reader.
    /// Request B — `listRosters`, whose answer is unmistakable — is sent while A's reply is
    /// still coming. The reader has to consume A's `.state` as the abandoned request's reply
    /// and leave B's own `.rosters` for B. Handing A's snapshot to B leaves B's `rosters` nil.
    @Test("An abandoned request's reply is not delivered to the next request")
    func abandonedReplyDoesNotAnswerTheNextRequest() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let ingestor = DocumentIngestor(extractors: [
            .plainText: BlockingExtractor(entered: entered, release: release)
        ])
        let running = try await startEngine(ingestor: ingestor)
        defer { TransportTeardown.register { await running.stop() } }

        let client = makeClient(port: running.port)
        try await client.connect()
        defer { TransportTeardown.register { await client.disconnect() } }

        let attachment = Task {
            try await client.send(
                .addAttachment(filename: "slow.txt", contents: Data("some words".utf8)))
        }
        #expect(await waitForSignal(entered, timeout: .now() + 5), "the conversion never started")

        // Give up on A while the engine is still working. Its reply is now owed and will arrive
        // after B is already waiting.
        attachment.cancel()
        _ = await attachment.result
        #expect(client.readerError == nil, "cancelling a send must not stop the reader")

        // B is started while A's reply is still owed, and given time to register and reach the
        // wire — which it can, because A released the request slot when it gave up.
        let next = Task { try await client.send(.listRosters(.entertainment)) }
        try? await Task.sleep(for: .milliseconds(300))

        // Now let the held conversion finish. A's reply is the first one on the wire, and it
        // belongs to the request that gave up, not to B.
        _ = release.signal()
        let reply = try await next.value

        #expect(
            reply.rosters != nil,
            "the reply to the abandoned request was delivered to the next request")
    }

    /// The enforcement behind the fix: overlapping sends are serialised, so each reply belongs
    /// to the request that is waiting for it even when four of them are issued at once.
    @Test("Overlapping requests each receive their own reply")
    func overlappingRequestsEachGetTheirOwnReply() async throws {
        // The real extractors are fine here: this test sends no attachment, only reads.
        let running = try await startEngine(ingestor: SystemDocumentExtractor.ingestor)
        defer { TransportTeardown.register { await running.stop() } }

        let client = makeClient(port: running.port)
        try await client.connect()
        defer { TransportTeardown.register { await client.disconnect() } }

        // Tasks rather than a task group: `addTask` with a `@MainActor` closure trips the
        // region-based isolation checker, and the overlap this test wants does not need the
        // group's structure.
        var probes: [Task<String, Never>] = []
        for _ in 0..<4 {
            probes.append(
                Task { @MainActor in
                    guard let reply = try? await client.send(.listRosters(.entertainment))
                    else { return "failed" }
                    return reply.rosters == nil ? "crossed" : "ok"
                })
            probes.append(
                Task { @MainActor in
                    guard let reply = try? await client.send(.fetchState) else { return "failed" }
                    return reply.snapshot == nil ? "crossed" : "ok"
                })
        }
        var outcomes: [String] = []
        for probe in probes { outcomes.append(await probe.value) }

        #expect(outcomes.count == 8)
        #expect(outcomes.allSatisfy { $0 == "ok" }, "got \(outcomes)")
    }
}
