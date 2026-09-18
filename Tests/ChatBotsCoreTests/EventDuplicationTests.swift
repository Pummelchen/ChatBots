// ChatBotsCoreTests — every engine event is published once
//
// `runTurn`'s `onEvent` closure called `publishEvent(event)` and then `handle(event, from:)`,
// and `handle` ends every branch with `publishEvent(event)` as well. So `record(event)` ran
// twice: `liveState[...].text` and `.reasoning` were doubled, `toolLog` got duplicate entries
// (which is what the interface draws), and every `observeEvents` subscriber and the `events`
// stream saw each token and tool event twice. No test caught it because every existing test
// asserts `conversation.turns`, which `handle` appends exactly once.
//
// These tests watch the two paths that were duplicated instead: the `observeEvents` callback
// the HTTP and WebTransport servers subscribe with, and the `events` stream itself.

import ChatBotsCore
import Foundation
import Testing

/// Emits a known burst of tokens plus one tool result per turn, like a real generation does.
private actor CountingEngine: LLMEngine {
    nonisolated let spec: AgentSpec
    private let tokens: [String]

    init(spec: AgentSpec, tokens: [String]) {
        self.spec = spec
        self.tokens = tokens
    }

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
        for token in tokens {
            await onEvent(.token(agentID: spec.id, text: token))
        }
        await onEvent(
            .toolResult(
                agentID: spec.id, name: "search", summary: "one result", detail: "the detail",
                billedUnits: 1))
        let text = tokens.joined()
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(
                    promptTokens: 10, generationTokens: tokens.count, stopReason: "stop")))
        return text
    }
}

@MainActor
private final class EventLog {
    private(set) var events: [TurnEvent] = []
    func append(_ event: TurnEvent) { events.append(event) }
}

private func tokenTexts(_ events: [TurnEvent]) -> [String] {
    events.compactMap { event in
        if case .token(_, let text) = event { return text }
        return nil
    }
}

private func isTurnFinished(_ event: TurnEvent) -> Bool {
    if case .turnFinished = event { return true }
    return false
}

private func isToolResult(_ event: TurnEvent) -> Bool {
    if case .toolResult = event { return true }
    return false
}

@MainActor
private func makeEngine(tokens: [String]) -> (ConversationEngine, CountingEngine) {
    let spec = AgentSpec.seat(index: 0)
    let stub = CountingEngine(spec: spec, tokens: tokens)
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 1
    configuration.autoCompact = false
    let engine = ConversationEngine(
        seats: [.init(spec: spec, engine: stub)], configuration: configuration)
    return (engine, stub)
}

@Suite("Engine events are published once")
struct EventDuplicationTests {

    @Test("An observeEvents subscriber sees each token once, in order")
    @MainActor
    func subscriberSeesEachEventOnce() async throws {
        let tokens = ["one ", "two ", "three "]
        let (engine, _) = makeEngine(tokens: tokens)

        let log = EventLog()
        engine.observeEvents { event in log.append(event) }

        engine.start(topic: "Why are eggs not round?")
        await engine.waitUntilFinished()

        // The duplicated path delivered every token twice; this is the assertion that fails
        // on that behaviour and passes on one publish.
        #expect(tokenTexts(log.events) == tokens, "each token must arrive exactly once")
        #expect(log.events.filter(isTurnFinished).count == 1, "one terminal event, not two")
        #expect(log.events.filter(isToolResult).count == 1, "one tool result, not two")

        // `liveSeats` is rebuilt by `record` from the same events and is what the interface
        // draws; doubling showed up here as the answer written twice.
        let live = try #require(engine.liveSeats.first)
        #expect(live.text == tokens.joined(), "the live answer was doubled")
        #expect(live.toolLog == ["one result"], "the tool log was duplicated")
    }

    @Test("The events stream also carries each event once")
    @MainActor
    func streamCarriesEachEventOnce() async throws {
        let tokens = ["alpha ", "beta "]
        let (engine, _) = makeEngine(tokens: tokens)

        let log = EventLog()
        let reader = Task { @MainActor in
            for await event in engine.events { log.append(event) }
        }

        engine.start(topic: "Why are eggs not round?")
        await engine.waitUntilFinished()
        try? await Task.sleep(for: .milliseconds(250))
        reader.cancel()

        #expect(tokenTexts(log.events) == tokens, "the stream delivered each token twice")
        #expect(log.events.filter(isTurnFinished).count == 1)
        #expect(log.events.filter(isToolResult).count == 1)
    }
}
