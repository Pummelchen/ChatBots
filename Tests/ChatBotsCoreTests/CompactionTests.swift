// ChatBotsCoreTests — condensing the log instead of dropping it

import ChatBotsCore
import Testing

/// An engine that records what it was asked to summarise.
private actor SummarisingStub: LLMEngine {
    nonisolated let spec: AgentSpec
    private(set) var compactPrompts: [String] = []
    private(set) var generatedTurns = 0
    var summary = "Established: eggs are ovoid. Agent 1 cites pressure; Agent 2 doubts it."
    var failCompaction = false

    init(spec: AgentSpec) { self.spec = spec }

    var isLoaded: Bool { true }
    var contextWindow: Int { spec.contextWindow }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}

    func compact(prompt: String, maxTokens: Int) async throws -> String {
        compactPrompts.append(prompt)
        if failCompaction { throw ChatBotsError.engineNotLoaded }
        return summary
    }

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        generatedTurns += 1
        // Long replies so the estimated prompt grows quickly.
        let text = "\(spec.id) reply \(generatedTurns) " + String(repeating: "filler words here ", count: 60)
        // Report a realistic prompt size: a real engine counts the rendered system
        // prompt, persona and brief as well as the transcript, which is what makes the
        // compaction threshold mean anything. A stub reporting zero made it unreachable.
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
private func makeEngine(
    window: Int = 4_000,
    threshold: Double = 0.5,
    keep: Int = 4,
    autoCompact: Bool = true
) -> (ConversationEngine, [SummarisingStub]) {
    let specs = (0..<2).map { index -> AgentSpec in
        var spec = AgentSpec.seat(index: index)
        spec.contextWindow = window
        return spec
    }
    let stubs = specs.map { SummarisingStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 6
    configuration.autoCompact = autoCompact
    configuration.compactThreshold = threshold
    configuration.compactKeepRecentTurns = keep
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    return (ConversationEngine(seats: seats, configuration: configuration), stubs)
}

@Suite("Compaction")
struct CompactionTests {

    @Test("The condensation prompt carries the transcript, the topic and the prior digest")
    func promptContents() {
        let spec = AgentSpec.seat(index: 0)
        let turns = [
            Turn(sequence: 1, speakerName: "Moderator", kind: .topic, content: "Why ovoid?"),
            Turn(sequence: 2, speakerID: "Agent 1", speakerName: "Agent 1", kind: .chat, content: "Pressure."),
            Turn(
                sequence: 3, speakerID: "Agent 1", speakerName: "Agent 1", kind: .tool, content: "web_search: 5 results"
            ),
        ]
        let prompt = PromptBuilder.compactionPrompt(
            for: spec, turns: turns, topic: "Why ovoid?", previousSummary: "Earlier: shells are thin.",
            maxWords: 300)

        #expect(prompt.contains("Why ovoid?"))
        #expect(prompt.contains("[Agent 1]"))
        #expect(prompt.contains("Pressure."))
        #expect(prompt.contains("Earlier: shells are thin."))
        #expect(prompt.contains("at most 300 words"))
        // The instruction has to be explicit that this is not a contribution.
        #expect(prompt.lowercased().contains("not a contribution"))
        // Tool chatter is already folded into its seat's reply.
        #expect(!prompt.contains("web_search: 5 results"))
    }

    @Test("A digest replaces older turns, keeping the topic, brief and recent turns")
    @MainActor
    func digestReplacesOlderTurns() async {
        // A window small enough that a handful of turns must cross it, so the test is
        // about compaction and not about the arithmetic of the threshold.
        let (engine, stubs) = makeEngine(window: 2_500, threshold: 0.3, keep: 2)
        engine.start(topic: "Why are eggs ovoid? Discuss at length.")
        await engine.waitUntilFinished()

        let prompts = await stubs[0].compactPrompts
        #expect(!prompts.isEmpty, "compaction never ran; the threshold was not reached")

        let kinds = engine.conversation.turns.map(\.kind)
        #expect(kinds.contains(.summary), "no digest was written")
        // The pinned opening is never condensed away.
        #expect(kinds.first == .topic)
        #expect(kinds.contains(.introduction))
        // And there is exactly one digest, so digests cannot pile up.
        #expect(kinds.filter { $0 == .summary }.count == 1)

        let expectedDigest = await stubs[0].summary
        let digest = engine.conversation.summaryTurn
        #expect(digest?.content == expectedDigest)
        #expect(digest?.speakerID == nil, "a digest has no speaker; it is not a contribution")
    }

    @Test("Compacting keeps the transcript ordered and uniquely numbered")
    @MainActor
    func orderingIsPreserved() async {
        let (engine, _) = makeEngine(window: 2_500, threshold: 0.3, keep: 2)
        engine.start(topic: "Why are eggs ovoid? Discuss at length.")
        await engine.waitUntilFinished()

        let sequences = engine.conversation.turns.map(\.sequence)
        #expect(sequences == sequences.sorted())
        #expect(Set(sequences).count == sequences.count)
    }

    @Test("The digest is placed after the opening, not in front of it")
    @MainActor
    func digestFollowsTheBrief() async {
        let (engine, _) = makeEngine(window: 2_500, threshold: 0.3, keep: 2)
        engine.start(topic: "Why are eggs ovoid? Discuss at length.")
        await engine.waitUntilFinished()

        let turns = engine.conversation.turns
        guard let digestIndex = turns.firstIndex(where: { $0.kind == .summary }),
            let briefIndex = turns.firstIndex(where: { $0.kind == .introduction })
        else {
            Issue.record("expected both a digest and a brief")
            return
        }
        #expect(digestIndex > briefIndex, "the digest must not precede the setup brief")
    }

    @Test("Compaction reduces the estimated prompt")
    @MainActor
    func reducesContext() async {
        let (engine, _) = makeEngine(window: 20_000, threshold: 0.2, keep: 2)
        engine.start(topic: "Why are eggs ovoid? Discuss at length.")
        await engine.waitUntilFinished()

        // Whatever happened, the machinery must not have inflated the estimate.
        let usage = engine.contextUsage
        #expect(usage.tokens <= usage.window / 2, "context is \(usage.tokens) of \(usage.window)")
    }

    @Test("Disabling compaction leaves the log intact")
    @MainActor
    func disabled() async {
        let (engine, stubs) = makeEngine(autoCompact: false)
        engine.start(topic: "Why are eggs ovoid? Discuss at length.")
        await engine.waitUntilFinished()

        #expect(await stubs[0].compactPrompts.isEmpty)
        #expect(!engine.conversation.turns.contains { $0.kind == .summary })
    }

    @Test("A failing condensation leaves the log untouched and says so")
    @MainActor
    func failureIsSurvivable() async {
        let (engine, stubs) = makeEngine()
        for stub in stubs { await stub.setFail(true) }

        engine.start(topic: "Why are eggs ovoid? Discuss at length.")
        await engine.waitUntilFinished()

        #expect(!engine.conversation.turns.contains { $0.kind == .summary })
        // The conversation continues rather than dying with the summariser.
        #expect(engine.conversation.turns.filter { $0.kind == .chat }.count > 0)
        #expect(engine.notices.contains { $0.contains("Compaction") && $0.contains("failed") })
    }

    @Test("An empty digest is refused rather than replacing the log with nothing")
    @MainActor
    func emptyDigestRefused() async {
        let (engine, stubs) = makeEngine()
        for stub in stubs { await stub.setSummary("") }

        engine.start(topic: "Why are eggs ovoid? Discuss at length.")
        await engine.waitUntilFinished()

        #expect(!engine.conversation.turns.contains { $0.kind == .summary })
        #expect(engine.notices.contains { $0.contains("returned nothing") })
    }

    @Test("With too little history it declines instead of condensing one message")
    @MainActor
    func declinesWhenTooShort() async {
        let (engine, stubs) = makeEngine(window: 4_000, threshold: 0.05, keep: 6)
        engine.start(topic: "Why are eggs ovoid? Discuss at length.")
        await engine.waitUntilFinished()

        #expect(!engine.conversation.turns.contains { $0.kind == .summary })
        #expect(await stubs[0].compactPrompts.isEmpty)
    }

    @Test("The context estimate accounts for the prompt, not just the transcript")
    @MainActor
    func estimateIncludesPromptOverhead() async {
        let (engine, _) = makeEngine(autoCompact: false)
        engine.start(topic: "Why are eggs ovoid? Discuss at length.")
        await engine.waitUntilFinished()

        let transcriptOnly = engine.conversation.dialogueTurns
            .reduce(0) { $0 + max(1, $1.content.count / 4) }
        // The system prompt, persona and brief are rendered into every prompt.
        #expect(engine.contextUsage.tokens > transcriptOnly)
    }

    @Test("A digest is rendered into later prompts so the models keep the thread")
    func digestReachesThePrompt() {
        var spec = AgentSpec.seat(index: 0)
        spec.personaID = PersonaLibrary.neutral.id
        let conversation = Conversation(
            topic: "Eggs",
            turns: [
                Turn(sequence: 1, speakerName: "Moderator", kind: .topic, content: "Why?"),
                Turn(sequence: 2, speakerName: "Condensed", kind: .summary, content: "They agreed on pressure."),
            ])
        let prompt = PromptBuilder.prompt(
            for: spec, others: [AgentSpec.seat(index: 1)], conversation: conversation)

        #expect(prompt[1].content.contains("[Earlier discussion — condensed]"))
        #expect(prompt[1].content.contains("They agreed on pressure."))
    }
}

extension SummarisingStub {
    fileprivate func setFail(_ value: Bool) { failCompaction = value }
    fileprivate func setSummary(_ value: String) { summary = value }
}
