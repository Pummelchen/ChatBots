// ChatBotsCoreTests — A33: a restarted conversation keeps its new loop
//
// The bug was a lost reference, not a race that resolves itself: `runLoop` cleared
// `generationTask` unconditionally, and a loop cancelled by a restart wakes up *after* the
// replacement is installed, so its tail cleared the replacement's reference. Stop and Pause
// then had nothing to act on and a further Start could launch a second loop over one log.
//
// These tests park generation in a stub so the old loop is still suspended when the restart
// happens, which is the only way to reach the late tail deterministically.

import ChatBotsCore
import Foundation
import Testing

/// An engine that parks inside `generate` until the test releases it, so a turn can be held
/// in flight while the conversation is restarted underneath it.
private actor GatedLoopEngine: LLMEngine {
    nonisolated let spec: AgentSpec

    private(set) var generateCalls = 0
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
        generateCalls += 1
        let call = generateCalls
        // `withCheckedContinuation` deliberately ignores cancellation, so a cancelled turn
        // stays parked until the test wakes it — which is exactly the real timing the audit
        // describes: cancellation is observed only when the task next resumes.
        if !autoRelease {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        if Task.isCancelled { throw CancellationError() }
        let text = "reply \(call)"
        await onEvent(.token(agentID: spec.id, text: text))
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 3, stopReason: "stop")))
        return text
    }

    /// Wake the oldest parked generation — the predecessor of a restart.
    func releaseFirst() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    /// Let every parked generation finish, and every later one run straight through.
    func releaseAll() {
        autoRelease = true
        let parked = waiters
        waiters = []
        for waiter in parked { waiter.resume() }
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
private func makeLoop() -> (ConversationEngine, GatedLoopEngine) {
    var spec = AgentSpec.seat(index: 0)
    spec.webSearchEnabled = false
    let stub = GatedLoopEngine(spec: spec)
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 4
    let engine = ConversationEngine(
        seats: [.init(spec: spec, engine: stub)], configuration: configuration)
    return (engine, stub)
}

@Suite("A restarted conversation keeps its new loop")
struct AuditEngineStateRestartTests {

    @Test("A cancelled predecessor does not clear the replacement's task reference")
    @MainActor
    func staleTailDoesNotOrphanTheNewLoop() async {
        let (engine, stub) = makeLoop()

        engine.start(topic: "Why are eggs not round?")
        #expect(await poll { await stub.generateCalls >= 1 }, "the first turn never generated")

        // Restart while that first turn is still in flight. The old task is cancelled here
        // but has not resumed yet, so its tail is still to come.
        engine.startOrRestart()
        #expect(await poll { await stub.generateCalls >= 2 }, "the replacement loop never ran")

        // Wake the predecessor only, then give its tail every chance to run.
        await stub.releaseFirst()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(
            engine.isLoopRunning,
            "the stale loop's tail cleared the replacement's generationTask, so Stop and Pause would have nothing to act on")

        // Let the replacement finish so the test leaves nothing parked.
        await stub.releaseAll()
        await engine.waitUntilFinished()
        #expect(!engine.isLoopRunning)
        #expect(engine.conversation.turns.filter { $0.kind == .chat }.count == 4)
    }

    @Test("Stop after a restart stops the loop that is actually running")
    @MainActor
    func stopStillStopsAfterARestart() async {
        let (engine, stub) = makeLoop()

        engine.start(topic: "Why are eggs not round?")
        #expect(await poll { await stub.generateCalls >= 1 })

        engine.startOrRestart()
        #expect(await poll { await stub.generateCalls >= 2 })

        // Let the predecessor's late tail run first: without the generation check it would
        // have cleared the reference, leaving Stop with nothing to cancel.
        await stub.releaseFirst()
        try? await Task.sleep(for: .milliseconds(200))

        engine.stop()
        await stub.releaseAll()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(engine.status == .stopped)
        // The replacement was cancelled, so it never wrote the turns it would have written.
        #expect(
            engine.conversation.turns.filter { $0.kind == .chat }.count < 4,
            "Stop cancelled nothing: the replacement loop was still running")
    }
}
