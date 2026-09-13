// ChatBotsCoreTests — A35: the engine's live view is the authority on a turn ending
//
// The desktop app sees a turn end through `APISnapshot.live[].isGenerating`, because the event
// feed has no "finished" fragment — it carries only `token`, `reasoning`, `tool` and `started`.
// These tests pin that contract at its source: a turn in flight reports `isGenerating` true, a
// finished turn and a failed turn report false, and a state-only client receives the tool log
// by the same route. The app's own use of the field is not reachable from this test target,
// which links `ChatBotsCore` only and cannot import the `ChatBots` executable.

import ChatBotsCore
import Foundation
import Testing

/// Parks inside `generate` until the test releases it, so a turn can be held in flight while
/// the state a client would draw is read. That is the "connecting mid-turn" case as well as the
/// ordinary end-of-turn one.
private actor GatedTurnEngine: LLMEngine {
    nonisolated let spec: AgentSpec
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var autoRelease = false

    init(spec: AgentSpec) { self.spec = spec }

    var isLoaded: Bool { true }
    var contextWindow: Int { 32_768 }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}
    func compact(prompt: String, maxTokens: Int) async throws -> String { "" }

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        await onEvent(.token(agentID: spec.id, text: "The answer"))
        if !autoRelease {
            await withCheckedContinuation { continuation in waiters.append(continuation) }
        }
        if Task.isCancelled { throw CancellationError() }
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: "The answer",
                stats: TurnStats(promptTokens: 10, generationTokens: 3, stopReason: "stop")))
        return "The answer"
    }

    /// Let the parked turn finish, and every later one run straight through.
    func release() {
        autoRelease = true
        let parked = waiters
        waiters = []
        for waiter in parked { waiter.resume() }
    }
}

/// Fails every turn. A failure has no fragment of its own either, so it is the other half of
/// "the live view is where a turn's end is observed".
private actor FailingTurnEngine: LLMEngine {
    struct Boom: Error {}

    nonisolated let spec: AgentSpec
    init(spec: AgentSpec) { self.spec = spec }

    var isLoaded: Bool { true }
    var contextWindow: Int { 32_768 }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}
    func compact(prompt: String, maxTokens: Int) async throws -> String { "" }

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        throw Boom()
    }
}

/// Reports a tool call and its result, so the state's tool log is exercised.
private actor ToolTurnEngine: LLMEngine {
    nonisolated let spec: AgentSpec
    init(spec: AgentSpec) { self.spec = spec }

    var isLoaded: Bool { true }
    var contextWindow: Int { 32_768 }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}
    func compact(prompt: String, maxTokens: Int) async throws -> String { "" }

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        await onToolCall("web_search", "ev market")
        await onEvent(
            .toolResult(
                agentID: spec.id, name: "web_search", summary: "3 results",
                detail: "the three results"))
        let text = "A sourced answer"
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 3, stopReason: "stop")))
        return text
    }
}

@MainActor
private func poll(
    timeout: Duration = .seconds(10),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

@MainActor
private func makeTurn(
    _ stub: any LLMEngine, spec: AgentSpec, maxTurns: Int = 1
) -> (ConversationEngine, EngineService) {
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = maxTurns
    configuration.autoCompact = false
    let engine = ConversationEngine(
        seats: [.init(spec: spec, engine: stub)], configuration: configuration)
    // A store per test, in a directory of its own, so a run cannot see another's log.
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "audit-s1-turn-\(UUID().uuidString)"))
    return (engine, EngineService(engine: engine, store: store))
}

@Suite("A turn's end is observable in the engine's live view")
@MainActor
struct AuditS1TurnLifecycleTests {

    @Test("A turn in flight reports isGenerating, and its end clears it")
    func liveViewClearsWhenTheTurnEnds() async {
        var spec = AgentSpec.seat(index: 0)
        spec.webSearchEnabled = false
        let stub = GatedTurnEngine(spec: spec)
        let (engine, service) = makeTurn(stub, spec: spec, maxTurns: 2)

        engine.start(topic: "A question")

        // The seat is mid-turn. This is both the ordinary case and the "a client connected
        // while the model was writing" case, which the app used to draw as idle.
        #expect(
            await poll { service.snapshot().live.first?.isGenerating == true },
            "a turn in flight must be reported as generating")

        await stub.release()
        await engine.waitUntilFinished()

        // The bug A35 records: nothing ever cleared this, so the pane stayed "generating…"
        // for the life of the conversation once the last turn finished.
        #expect(
            service.snapshot().live.allSatisfy { !$0.isGenerating },
            "a finished turn must clear isGenerating in the state a client draws")
        #expect(engine.liveSeats.allSatisfy { !$0.isGenerating })
    }

    @Test("A failed turn clears isGenerating too")
    func failedTurnClears() async {
        var spec = AgentSpec.seat(index: 0)
        spec.webSearchEnabled = false
        let (engine, service) = makeTurn(FailingTurnEngine(spec: spec), spec: spec)

        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        #expect(
            service.snapshot().live.allSatisfy { !$0.isGenerating },
            "a turn that failed must not leave the seat stuck generating")
        #expect(engine.liveSeats.allSatisfy { !$0.isGenerating })
    }

    @Test("The tool log reaches a state-only client through the live view")
    func toolLogIsCarriedInTheState() async {
        var spec = AgentSpec.seat(index: 0)
        spec.webSearchEnabled = false
        let (engine, service) = makeTurn(ToolTurnEngine(spec: spec), spec: spec)

        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        // There is no `toolResult` fragment on the wire, so a client that draws from snapshots
        // can only see the tool log here. Reading it from `live` is what makes the tool log
        // reachable at all.
        let toolLog = service.snapshot().live.first?.toolLog ?? []
        #expect(toolLog.contains("3 results"), "the tool log was not carried in the live view")
    }
}
