// ChatBotsCoreTests — what a run reports back
//
// A save that failed, a turn that produced no text, an endpoint that changed while the engine was
// live, a generation that errored: each is a fact the engine has to expose, because the interface
// and the exit code read them. Split out of `ConversationEngineTests.swift`, which had grown past
// the repository's 500-line limit; `StubEngine` and the `waitUntil` poller stay there and are
// shared through the test target.

import ChatBotsCore
import Foundation
import Testing

// MARK: - What a run reports

@MainActor
@Test("A conversation the store cannot save is reported instead of silently lost")
func unsaveableConversationIsReported() throws {
    // A file where the store's directory must be makes `createDirectory` throw, which is one
    // of the failures `save` returns false for. `saveConversation` used to discard that Bool,
    // so the UI showed the conversation intact and it was gone at quit.
    let blocker = FileManager.default.temporaryDirectory
        .appending(path: "chatbots-store-blocker-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: blocker)
    defer { try? FileManager.default.removeItem(at: blocker) }

    let specA = AgentSpec.seatA()
    let specB = AgentSpec.seatB()
    let engine = ConversationEngine(
        seats: [
            .init(spec: specA, engine: StubEngine(spec: specA)),
            .init(spec: specB, engine: StubEngine(spec: specB)),
        ])
    engine.conversationStore = ConversationStore(directory: blocker)
    engine.seed([Turn(sequence: 1, speakerName: "A", kind: .chat, content: "hello")])

    #expect(
        engine.notices.contains { $0.contains("could not be saved") },
        "a failed save must reach the notices the interface shows")
}

@MainActor
@Test("A turn that produces no text still charges the research budget")
func emptyTurnStillChargesTheBudget() async {
    // The research `record` call sat in the non-empty branch of the turn handler, so a turn
    // whose rounds emitted only tool calls spent billed searches for free: `searches` never
    // moved, the `maxSearches` ceiling never dropped, and web tools stayed offered.
    var specA = AgentSpec.seatA()
    var specB = AgentSpec.seatB()
    // No web tools: this is about the accounting, not the search.
    specA.webSearchEnabled = false
    specB.webSearchEnabled = false
    let engineA = StubEngine(spec: specA, replies: [""])
    let engineB = StubEngine(spec: specB, replies: [""])
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 1
    let engine = ConversationEngine(
        seats: [
            .init(spec: specA, engine: engineA),
            .init(spec: specB, engine: engineB),
        ],
        configuration: configuration)
    engine.setMode(.research)
    engine.start(topic: "Eggs")
    await engine.waitUntilFinished()

    #expect(
        (engine.conversation.research?.rounds ?? 0) >= 1,
        "a turn that ran must advance the research accounting even with no answer text")
}

@MainActor
@Test("An endpoint change replaces the OpenAI engine rather than only being stored")
func endpointChangeReachesTheEngine() async {
    // `updateSeat` wrote the new base URL into the seat's spec and the snapshot reported it,
    // while the engine that sends the request kept the one it was built with — so the sheet
    // showed an endpoint the requests never used. The engine has to be rebuilt, because its
    // `spec` is immutable and its cached client holds a session for one endpoint.
    let specA = AgentSpec.seatA()
    let mlx = StubEngine(spec: specA)
    let openAI = StubEngine(spec: specA)
    var configuration = ConversationEngine.Configuration()
    configuration.makeOpenAIEngine = { StubEngine(spec: $0) }
    let engine = ConversationEngine(
        seats: [.init(spec: specA, mlx: mlx, openAI: openAI)],
        configuration: configuration)

    var changed = specA
    changed.openAI.baseURL = "https://example.test/v1"
    engine.updateSeat(changed)

    let live = engine.allSeats[0].openAI as? StubEngine
    #expect(live !== openAI, "the OpenAI engine must be replaced, not left on the old endpoint")
    #expect(
        live?.spec.openAI.baseURL == "https://example.test/v1",
        "the replacement carries the new endpoint")
}

@MainActor
@Test("A failed turn is counted, because the run's status does not stay failed")
func failedTurnsAreCounted() async {
    // A turn that throws leaves a notice and a `.turnFailed` event, but the run's status goes on
    // to `.finished` — so `lastError` is nil afterwards and the headless mode read a success. The
    // counter is the signal that survives, for the exit code the caller reads.
    let spec = AgentSpec.seatA()
    let stub = StubEngine(spec: spec)
    await stub.failNextTurn(with: ChatBotsError.emptyTopic)
    let engine = ConversationEngine(seats: [.init(spec: spec, engine: stub)])

    engine.start(topic: "A topic worth discussing")
    await waitUntil { engine.failedTurns > 0 }

    #expect(engine.failedTurns == 1)
    #expect(engine.lastError == nil, "the run's status is not the failure signal")
}
