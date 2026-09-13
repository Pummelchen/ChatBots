// ChatBotsCoreTests — A45: auto-compaction is measured against the engine's own window
//
// `contextUsage` and `compactIfNeeded` both read `spec.contextWindow`, while `currentSpec`
// overrides only thinking, persona and displayName. The MLX backend reads the real window from
// the checkpoint config, so the number the engine actually works with never reached the
// threshold — a 32 768-token model was measured against the spec's 262 144 and compaction
// never fired before the provider silently truncated the start of the discussion.

import ChatBotsCore
import Testing

/// Reports a context window that is deliberately different from the spec's, and records what
/// it was asked to condense.
private actor WindowReportingEngine: LLMEngine {
    nonisolated let spec: AgentSpec
    private let reportedWindow: Int
    private(set) var compactPrompts: [String] = []
    private(set) var generatedTurns = 0

    init(spec: AgentSpec, reportedWindow: Int) {
        self.spec = spec
        self.reportedWindow = reportedWindow
    }

    var isLoaded: Bool { true }
    var contextWindow: Int { reportedWindow }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}

    func compact(prompt: String, maxTokens: Int) async throws -> String {
        compactPrompts.append(prompt)
        return "Established: eggs are ovoid."
    }

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        generatedTurns += 1
        // Long replies so the estimated prompt grows quickly.
        let text =
            "\(spec.id) reply \(generatedTurns) " + String(repeating: "filler words here ", count: 60)
        // The rendered prompt is what a real engine counts, and it is what makes the threshold
        // mean anything.
        let overhead = 900
        let transcript = messages.reduce(0) { $0 + max(1, $1.content.count / 4) }
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(
                    promptTokens: overhead + transcript, generationTokens: 100, stopReason: "length")))
        return text
    }
}

@MainActor
private func makeWindowEngine(
    specWindow: Int,
    reportedWindow: Int,
    threshold: Double = 0.2,
    keep: Int = 2,
    autoCompact: Bool = true
) -> (ConversationEngine, [WindowReportingEngine]) {
    let specs = (0..<2).map { index -> AgentSpec in
        var spec = AgentSpec.seat(index: index)
        spec.contextWindow = specWindow
        return spec
    }
    let stubs = specs.map { WindowReportingEngine(spec: $0, reportedWindow: reportedWindow) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 6
    configuration.autoCompact = autoCompact
    configuration.compactThreshold = threshold
    configuration.compactKeepRecentTurns = keep
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    return (ConversationEngine(seats: seats, configuration: configuration), stubs)
}

@Suite("Compaction follows the engine's context window")
struct AuditEngineStateContextWindowTests {

    @Test("The threshold fires against the engine's window, not the spec's")
    @MainActor
    func compactionUsesTheEngineWindow() async {
        // The spec claims the 262 144-token default; the engine reports the 2 500 it is really
        // working with. Measuring against the spec would put the threshold far out of reach.
        let (engine, stubs) = makeWindowEngine(
            specWindow: AgentSpec.defaultContextWindow, reportedWindow: 2_500)
        engine.start(topic: "Why are eggs ovoid? Discuss at length.")
        await engine.waitUntilFinished()

        let prompts = await stubs[0].compactPrompts
        #expect(
            !prompts.isEmpty,
            "compaction never ran: the threshold was measured against the spec's window")
        #expect(
            engine.contextUsage.window == 2_500,
            "the reported usage was measured against the spec's window")
    }

    @Test("An engine that reports no window falls back to the spec's")
    @MainActor
    func fallsBackToTheSpecWindow() async {
        let (engine, _) = makeWindowEngine(specWindow: 5_000, reportedWindow: 0)
        engine.start(topic: "Why are eggs ovoid? Discuss at length.")
        await engine.waitUntilFinished()

        #expect(engine.contextUsage.window == 5_000)
    }

    @Test("With neither window set, the shared default is used")
    @MainActor
    func fallsBackToTheDefaultWindow() {
        // The old arithmetic returned the spec's 0 here, which made the fraction zero and the
        // threshold unreachable rather than falling back at all.
        let (engine, _) = makeWindowEngine(specWindow: 0, reportedWindow: 0)
        #expect(engine.contextUsage.window == AgentSpec.defaultContextWindow)
    }
}
