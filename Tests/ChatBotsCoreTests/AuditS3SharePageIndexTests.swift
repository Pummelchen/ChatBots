// ChatBotsCoreTests — a share link does not stall the engine (A147)
//
// A kept conversation lives in one index file, `conversations.json`, holding every record — that is
// deliberate, and A137 is why the write is a single atomic replacement of that one file. A *read* of
// it therefore decodes every kept conversation, and `/s/<id>` did that on the main actor, for an
// unknown id as much as a known one. The engine's turn loop is on the same actor, so a share link
// opened while a conversation was streaming stalled the stream for the length of the decode.
//
// The fix is not a new storage format (that is a migration, not an S3) but the actor the read runs on:
// `ConversationStore.listOffMainActor()` and `conversationOffMainActor(id:)` hand the decode to a
// detached task, and the request paths that trigger it use them. This is the shape A15 used for
// document conversion, and the test is the same shape: hold the expensive work open with a semaphore
// and ask whether the main actor is still answering.
//
// Nothing here is timed. A first version measured how many ticks a main-actor loop managed during a
// large decode. It passed alone and failed under the instrumented suite the gate runs, where the whole
// test process shares one main actor — the sampler was measuring the suite, not the read.

import Foundation
import Synchronization
import Testing

@testable import ChatBotsCore

private actor IndexStub: LLMEngine {
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

/// Wait for a semaphore without blocking the caller's executor.
///
/// `DispatchSemaphore.wait` is unavailable from an async context, and waiting on the main actor is
/// what the test below must not do, so the wait happens on a dispatch queue. The same helper A15's
/// conversion test uses, for the same reason.
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

/// Wait until `flag` is set, or `timeout` passes. Off the main actor, so the task that sets it can run.
private func waitForSignal(_ flag: borrowing Atomic<Bool>, timeout: DispatchTime) async -> Bool {
    while DispatchTime.now() < timeout {
        if flag.load(ordering: .relaxed) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return flag.load(ordering: .relaxed)
}

/// Not on the main actor: waiting for a read that is supposed to have left the main actor must not
/// itself depend on that actor.
@Suite("A share link and the conversation index (A147)")
struct SharePageIndexTests {

    /// An index of `records` conversations of `turns` turns each, written the way the store writes it.
    ///
    /// Written directly rather than through `save`, which rewrites the whole file per record and would
    /// make the fixture the slow part. The read is what is under test, and it does not care how the
    /// file got there.
    private func makeIndex(
        records: Int, turns: Int, charactersPerTurn: Int
    ) throws -> (store: ConversationStore, directory: URL, wanted: UUID) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConversationStore(directory: directory)
        let seats = AgentSpec.makeSeats(count: 2)
        let filler = String(repeating: "x", count: charactersPerTurn)
        var stored: [StoredConversation] = []
        var wanted = UUID()
        for record in 0..<records {
            let id = UUID()
            let conversation = Conversation(
                topic: "Topic \(record)",
                turns: (0..<turns).map { turn in
                    Turn(
                        sequence: turn, speakerName: "Agent 1", kind: .chat,
                        content: "\(record)-\(turn) \(filler)")
                })
            if record == records / 2 { wanted = id }
            stored.append(
                StoredConversation(
                    id: id, conversation: conversation, seats: seats, startedAt: .now))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stored).write(to: directory.appending(path: "conversations.json"))
        return (store, directory, wanted)
    }

    @MainActor
    private func makeService(store: ConversationStore) -> EngineService {
        EngineService(engine: makeEngine(), store: store)
    }

    @MainActor
    private func makeServer(store: ConversationStore) -> APIServer {
        APIServer(engine: makeEngine(), store: store, port: 7999)
    }

    @MainActor
    private func makeEngine() -> ConversationEngine {
        let specs = AgentSpec.makeSeats(count: 2)
        let seats = specs.map { ConversationEngine.Seat(spec: $0, engine: IndexStub(spec: $0)) }
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        let engine = ConversationEngine(seats: seats, configuration: configuration)
        engine.setTopic("A share test")
        return engine
    }

    @Test("A share link finds its conversation, and an unknown one gets the page that says so")
    func thePagesAreServed() async throws {
        let fixture = try makeIndex(records: 40, turns: 20, charactersPerTurn: 200)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let server = await MainActor.run { makeServer(store: fixture.store) }

        let found = await server.handle(
            HTTPRequest(method: "GET", path: "/s/\(fixture.wanted.uuidString)"))
        #expect(found.status == 200)
        let page = String(data: found.body, encoding: .utf8) ?? ""
        #expect(page.contains("Topic 20"), "the record's own topic should be in the page")

        let missing = await server.handle(
            HTTPRequest(method: "GET", path: "/s/\(UUID().uuidString)"))
        #expect(missing.status == 404)
        #expect((String(data: missing.body, encoding: .utf8) ?? "").contains("No conversation"))

        // A malformed id never reaches the store at all, which is also the cheapest 404 there is.
        let malformed = await server.handle(HTTPRequest(method: "GET", path: "/s/not-a-uuid"))
        #expect(malformed.status == 404)
    }

    @Test("The Kept list comes through the same off-actor read")
    func theKeptListIsServed() async throws {
        let fixture = try makeIndex(records: 5, turns: 3, charactersPerTurn: 40)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = await MainActor.run { makeService(store: fixture.store) }

        let reply = await service.handle(.listSavedConversations)
        guard case .savedConversations(let list) = reply else {
            Issue.record("expected a list, got \(reply)")
            return
        }
        #expect(list.count == 5)
        #expect(list.contains { $0.id == fixture.wanted.uuidString })
    }

    /// The finding, made measurable: the read is held open, and a main-actor task has to run while it
    /// is still open. On the old code the read was inside the main-actor request, so that task could
    /// not start until the read finished.
    @Test("The main actor answers while the conversation index is being read")
    func theMainActorIsFreeWhileTheIndexIsRead() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let fixture = try makeIndex(records: 40, turns: 20, charactersPerTurn: 200)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var store = fixture.store
        store.readIndex = { url in
            entered.signal()
            release.wait()
            return try? Data(contentsOf: url)
        }
        let server = await MainActor.run { makeServer(store: store) }

        let request = Task {
            await server.handle(
                HTTPRequest(method: "GET", path: "/s/\(fixture.wanted.uuidString)"))
        }

        // The read has to be under way before the question is asked, and this wait is deliberately off
        // the main actor: on the old code the read is inside a synchronous call on that actor, and this
        // would be behind it.
        let started = await waitForSignal(entered, timeout: .now() + 10)
        #expect(started, "the index was never read")

        let answered = Atomic(false)
        let probe = Task { @MainActor in
            answered.store(true, ordering: .relaxed)
        }
        // Waiting with a bound rather than sampling once at 200 ms. The property is whether the main
        // actor can run *at all* while the read is held open, and on the old code it cannot: the read is
        // inside a synchronous main-actor call and the semaphore is released only below. A single sample
        // measured the machine's load as much as the code — it has failed in a busy gate while the code
        // was correct — so the wait is generous and the release still comes after it.
        let responsive = await waitForSignal(answered, timeout: .now() + 5)

        // Release before asserting: a failure on the old code must finish the request rather than leave
        // the main actor holding a semaphore.
        release.signal()
        _ = await probe.value
        let response = await request.value

        #expect(
            responsive,
            "the main actor could not run while the conversation index was being read")
        #expect(response.status == 200)
    }
}
