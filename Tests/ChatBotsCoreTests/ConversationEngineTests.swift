// ChatBotsCoreTests — orchestration, prompt assembly and tool formatting
//
// These tests never load a real model: `StubEngine` implements the same
// `LLMEngine` protocol the MLX adapter does, which is the point of keeping the
// protocol that narrow.

import ChatBotsCore
import Foundation
import Testing

// MARK: - Stub seat

/// Records what it was asked and replies with scripted text.
actor StubEngine: LLMEngine {
    nonisolated let spec: AgentSpec

    private(set) var prompts: [[PromptMessage]] = []
    private(set) var toolNamesSeen: [String] = []
    private var replyCount = 0
    private(set) var delay: Duration = .zero

    func setDelay(_ duration: Duration) {
        delay = duration
    }
    /// Text returned for turn N (1-based), cycling.
    var replies: [String] = ["First reply.", "Second reply.", "Third reply."]

    init(spec: AgentSpec, replies: [String]? = nil) {
        self.spec = spec
        if let replies { self.replies = replies }
    }

    var isLoaded: Bool { true }
    var contextWindow: Int { 32_768 }

    func load() async throws {}
    func unload() async {}

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        prompts.append(messages)
        toolNamesSeen = tools.map(\.name)
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        let text = replies[replyCount % replies.count]
        replyCount += 1
        await onEvent(.token(agentID: spec.id, text: text))
        await onEvent(
            .turnFinished(
                agentID: spec.id,
                text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 3, stopReason: "stop")
            )
        )
        return text
    }
}

/// Bounded polling: yields to the main actor until `condition` holds or the
/// deadline passes. Prevents a broken loop from hanging the whole test run.
@MainActor
@discardableResult
private func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
private func makeSeats(
    repliesA: [String] = ["A1", "A2"],
    repliesB: [String] = ["B1", "B2"]
) -> (ConversationEngine, StubEngine, StubEngine) {
    let specA = AgentSpec.seatA()
    let specB = AgentSpec.seatB()
    let engineA = StubEngine(spec: specA, replies: repliesA)
    let engineB = StubEngine(spec: specB, replies: repliesB)
    let seats = [
        ConversationEngine.Seat(spec: specA, engine: engineA),
        ConversationEngine.Seat(spec: specB, engine: engineB),
    ]
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 4
    return (ConversationEngine(seats: seats, configuration: configuration), engineA, engineB)
}

// MARK: - Prompt assembly

@Test("Introduction names the topic and every participant")
func introductionMentionsTopicAndRoster() {
    let specs = [AgentSpec.seatA(), AgentSpec.seatB()]
    let text = PromptBuilder.introduction(specs: specs, topic: "Why are eggs not round?")

    #expect(text.contains("Why are eggs not round?"))
    #expect(text.contains("2 different LLMs"))
    #expect(text.contains("Agent A"))
    #expect(text.contains("Agent B"))
    // The moderator explicitly asked for no further rules beyond topic + intro.
    #expect(text.contains("Rules: there are none beyond the topic"))
}

@Test("Other seats are named in a seat's system message, never itself as an other")
func systemMessageListsCounterparts() {
    let specA = AgentSpec.seatA()
    let specB = AgentSpec.seatB()
    let message = PromptBuilder.systemMessage(for: specA, others: [specB], topic: "Eggs")

    #expect(message.contains("You are Agent A"))
    #expect(message.contains("Agent B"))
    #expect(!message.contains("The other participant(s): Agent A"))
}

@Test("A turn prompt is a valid system+user pair carrying every tagged log entry")
func promptCarriesTaggedLog() {
    let specA = AgentSpec.seatA()
    let conversation = Conversation(
        topic: "Eggs",
        turns: [
            Turn(sequence: 1, speakerName: "Moderator", kind: .topic, content: "Why are eggs not round?"),
            Turn(sequence: 2, speakerName: "Agent B", kind: .chat, content: "Because of oviposition."),
            Turn(sequence: 3, speakerName: "Moderator", kind: .steering, content: "What about ostriches?"),
        ]
    )

    let prompt = PromptBuilder.prompt(for: specA, others: [AgentSpec.seatB()], conversation: conversation)

    #expect(prompt.first?.role == .system)
    #expect(prompt.count == 2)
    #expect(prompt[1].role == .user)

    let body = prompt[1].content
    #expect(body.contains("[Moderator — topic]\nWhy are eggs not round?"))
    #expect(body.contains("[Agent B]\nBecause of oviposition."))
    #expect(body.contains("[Moderator]\nWhat about ostriches?"))
    #expect(body.contains("It is your turn — Agent A"))
}

@Test("Tool turns and thinking are kept out of the prompt log")
func promptExcludesToolTurns() {
    let conversation = Conversation(
        topic: "Eggs",
        turns: [
            Turn(sequence: 1, speakerName: "Moderator", kind: .topic, content: "Why?"),
            Turn(
                sequence: 2, speakerID: "Agent A", speakerName: "Agent A", kind: .tool,
                content: "web_search: 3 results", toolDetail: "secret payload"),
        ]
    )
    let prompt = PromptBuilder.prompt(
        for: AgentSpec.seatA(), others: [AgentSpec.seatB()], conversation: conversation)
    #expect(!prompt[1].content.contains("secret payload"))
    #expect(!prompt[1].content.contains("TOOL"))
}

// MARK: - Orchestration

@MainActor
@Test("Seats alternate and both see the identical shared log")
func seatsAlternate() async {
    let (engine, stubA, stubB) = makeSeats()
    engine.start(topic: "Why are eggs not round?")
    await engine.waitUntilFinished()

    let chatTurns = engine.conversation.turns.filter { $0.kind == .chat }
    #expect(chatTurns.count == 4)
    #expect(chatTurns.map(\.speakerName) == ["Agent A", "Agent B", "Agent A", "Agent B"])
    // Two turns each — the loop ran the configured 4 turns, not more.
    #expect(await stubA.prompts.count == 2)
    #expect(await stubB.prompts.count == 2)
}

@MainActor
@Test("The opening log is topic then introduction, numbered in order")
func openingTurnsAreOrdered() async {
    let (engine, _, _) = makeSeats()
    engine.start(topic: "Why are eggs not round?")
    await engine.waitUntilFinished()

    let kinds = engine.conversation.turns.prefix(2).map(\.kind)
    #expect(kinds == [.topic, .introduction])
    let sequences = engine.conversation.turns.map(\.sequence)
    #expect(sequences == sequences.sorted())
    #expect(Set(sequences).count == sequences.count)
}

@MainActor
@Test("Seat B reads seat A's message in its prompt")
func counterpartMessageIsVisible() async {
    let (engine, _, stubB) = makeSeats()
    engine.start(topic: "Eggs")
    await engine.waitUntilFinished()

    let prompts = await stubB.prompts
    #expect(!prompts.isEmpty)
    // Seat B's first turn must contain seat A's first message.
    #expect(prompts[0][1].content.contains("[Agent A]\nA1"))
    // And its own prior message on the second turn.
    #expect(prompts.count > 1)
    #expect(prompts[1][1].content.contains("[Agent B]\nB1"))
}

@MainActor
@Test("Start is refused without a topic")
func emptyTopicIsRejected() async {
    let (engine, stubA, _) = makeSeats()
    engine.start(topic: "   ")
    await Task.yield()

    #expect(engine.status == .failed(ChatBotsError.emptyTopic.localizedDescription))
    #expect(await stubA.prompts.isEmpty)
}

@MainActor
@Test("Stop ends the loop and leaves loaded weights alone")
func stopHaltsLoop() async {
    let (engine, stubA, _) = makeSeats()
    await stubA.setDelay(.milliseconds(40))
    engine.start(topic: "Eggs")
    engine.stop()
    await engine.waitUntilFinished()

    #expect(engine.status == .stopped)
    #expect(engine.conversation.turns.filter { $0.kind == .chat }.count < 4)
}

@MainActor
@Test("Pause stops new turns; resume continues the rotation")
func pauseAndResume() async {
    let (engine, stubA, _) = makeSeats()
    await stubA.setDelay(.milliseconds(60))
    engine.start(topic: "Eggs")
    // Let the first turn land, then pause before the second.
    let landed = await waitUntil { engine.conversation.turns.contains { $0.kind == .chat } }
    #expect(landed)
    engine.pause()

    // The loop must be parked, not racing ahead through the remaining turns.
    try? await Task.sleep(for: .milliseconds(250))
    let afterPause = engine.conversation.turns.filter { $0.kind == .chat }.count
    #expect(afterPause >= 1)
    #expect(afterPause < 4)
    #expect(engine.status.isPaused)

    engine.resume()
    await engine.waitUntilFinished()
    #expect(engine.conversation.turns.filter { $0.kind == .chat }.count == 4)
}

@MainActor
@Test("Mid-turn steering is queued, delivered once, and seen by both seats")
func steeringIsDeliveredOnceToBoth() async {
    let (engine, stubA, stubB) = makeSeats()
    await stubA.setDelay(.milliseconds(60))
    engine.start(topic: "Eggs")

    // Type while the first turn is generating.
    let started = await waitUntil { engine.startedTurns >= 1 }
    #expect(started)
    engine.steer("What about ostriches?")

    // Accepted immediately, but not yet in the delivered log.
    #expect(engine.queuedSteering.count == 1)
    #expect(engine.displayTurns.contains { $0.content == "What about ostriches?" })

    await engine.waitUntilFinished()

    let delivered = engine.conversation.turns.filter { $0.kind == .steering }
    #expect(delivered.count == 1)
    #expect(engine.queuedSteering.isEmpty)

    // The turn immediately after the steering (seat B's first) must carry it, and
    // seat A must see it too on its next turn.
    let promptsB = await stubB.prompts
    #expect(promptsB.first?[1].content.contains("[Moderator]\nWhat about ostriches?") == true)
    let promptsA = await stubA.prompts
    #expect(promptsA.count > 1)
    #expect(promptsA[1][1].content.contains("[Moderator]\nWhat about ostriches?"))
}

@MainActor
@Test("Steering an idle conversation starts it")
func steeringStartsIdleConversation() async {
    let (engine, stubA, _) = makeSeats()
    engine.steer("Why are eggs not round?")
    await engine.waitUntilFinished()

    #expect(engine.conversation.topic == "Why are eggs not round?")
    #expect(engine.conversation.turns.contains { $0.kind == .steering })
    #expect(await stubA.prompts.isEmpty == false)
}

@MainActor
@Test("Reset clears the log and the turn counters")
func resetClearsState() async {
    let (engine, _, _) = makeSeats()
    engine.start(topic: "Eggs")
    await engine.waitUntilFinished()
    #expect(!engine.conversation.turns.isEmpty)

    engine.reset()
    #expect(engine.conversation.turns.isEmpty)
    #expect(engine.displayTurns.isEmpty)
    #expect(engine.status == .idle)
}

@MainActor
@Test("Turn limit pauses the loop instead of running forever")
func turnLimitPauses() async {
    let specA = AgentSpec.seatA()
    let specB = AgentSpec.seatB()
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 2
    let engine = ConversationEngine(
        seats: [
            .init(spec: specA, engine: StubEngine(spec: specA)),
            .init(spec: specB, engine: StubEngine(spec: specB)),
        ],
        configuration: configuration
    )

    engine.start(topic: "Eggs")
    await engine.waitUntilFinished()

    // The loop must exit rather than park: Resume cannot lift a spent budget.
    #expect(engine.status == .limitReached)
    #expect(!engine.isLoopRunning)
    #expect(engine.conversation.turns.filter { $0.kind == .chat }.count == 2)
}

@MainActor
@Test("Web tools are offered only to seats that enable them")
func toolsFollowTheSeatSpec() async {
    var specA = AgentSpec.seatA()
    specA.webSearchEnabled = false
    let specB = AgentSpec.seatB()
    let stubA = StubEngine(spec: specA)
    let stubB = StubEngine(spec: specB)
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 2
    let engine = ConversationEngine(
        seats: [
            .init(spec: specA, engine: stubA),
            .init(spec: specB, engine: stubB),
        ],
        configuration: configuration
    )

    engine.start(topic: "Eggs")
    await engine.waitUntilFinished()

    #expect(await stubA.toolNamesSeen.isEmpty)
    #expect(await stubB.toolNamesSeen.sorted() == ["fetch_page", "web_search"])
}

// MARK: - Seats are genuinely independent

@Test("Each seat carries its own model id and sampling parameters")
func seatsAreIndependent() {
    var specB = AgentSpec.seatB(modelID: "mlx-community/Qwen3.5-9B-MLX-4bit")
    specB.temperature = 1.1

    let specA = AgentSpec.seatA()
    #expect(specA.modelID != specB.modelID)
    #expect(specA.temperature != specB.temperature)
    // Distinct seeds keep two copies of the same weights from converging.
    #expect(specA.samplingSeed != AgentSpec.seatB().samplingSeed)
}
