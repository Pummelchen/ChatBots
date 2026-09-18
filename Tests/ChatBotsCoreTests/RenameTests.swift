// ChatBotsCoreTests — renaming a seat
//
// A rename has to reach further than the label in the window: it changes how the models are
// told each participant is called, and how the shared log tags what they say. Both are
// asserted here, because a rename that only changed the UI would quietly leave the models
// talking about "Agent 1" while the moderator looks at "Mira".

import ChatBotsCore
import Testing

/// Records the prompt it was handed, so the rendered text can be inspected.
private actor PromptRecordingStub: LLMEngine {
    nonisolated let spec: AgentSpec
    private(set) var prompts: [[PromptMessage]] = []
    private var liveName: String

    init(spec: AgentSpec) {
        self.spec = spec
        self.liveName = spec.displayName
    }

    var isLoaded: Bool { true }
    var contextWindow: Int { spec.contextWindow }
    var currentSpec: AgentSpec {
        var copy = spec
        copy.displayName = liveName
        return copy
    }
    func load() async throws {}
    func unload() async {}
    func compact(prompt: String, maxTokens: Int) async throws -> String { "" }
    func setThinking(_ mode: ThinkingMode) async {}
    func setPersona(_ personaID: String) async {}
    func setDisplayName(_ name: String) async { liveName = name }

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        prompts.append(messages)
        let text = "\(liveName) speaking"
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 3, stopReason: "stop")))
        return text
    }
}

@Suite("Renaming a seat")
struct RenameTests {

    @Test("The system message refers to a seat by the name it was given")
    func systemMessageUsesTheName() {
        var spec = AgentSpec.seat(index: 0)
        spec.displayName = "Mira"
        let other = AgentSpec.seat(index: 1)  // "Agent 2"

        let message = PromptBuilder.systemMessage(for: spec, others: [other], topic: "Eggs")
        #expect(message.contains("You are Mira"))
        // And the internal id is not used as though it were a name.
        #expect(!message.contains("You are Agent 1"))
        // The counterpart is named by its own name, not its seat number.
        #expect(message.contains("Agent 2"))
    }

    @Test("Parts of the prompt name participants by their given names")
    func promptNamesParticipants() {
        var spec = AgentSpec.seat(index: 0)
        spec.displayName = "Mira"
        var other = AgentSpec.seat(index: 1)
        other.displayName = "Otto"

        let conversation = Conversation(
            topic: "Eggs",
            turns: [
                Turn(sequence: 1, speakerName: "Moderator", kind: .topic, content: "Why?"),
                Turn(sequence: 2, speakerName: "Otto", kind: .chat, content: "Because."),
            ])
        let prompt = PromptBuilder.prompt(for: spec, others: [other], conversation: conversation)
        let body = prompt.map(\.content).joined(separator: "\n")

        #expect(body.contains("You are Mira"))
        #expect(body.contains("Otto"))
        #expect(body.contains("It is your turn — Mira"))
        #expect(!body.contains("It is your turn — Agent 1"))
    }

    @Test("The introduction lists participants by their given names")
    func introductionUsesNames() {
        var first = AgentSpec.seat(index: 0)
        first.displayName = "Mira"
        var second = AgentSpec.seat(index: 1)
        second.displayName = "Otto"

        let text = PromptBuilder.introduction(specs: [first, second], topic: "Eggs")
        #expect(text.contains("Mira"))
        #expect(text.contains("Otto"))
        // The seat numbers are an implementation detail, not something a model needs.
        #expect(!text.contains("Agent 1"))
    }

    @Test("A logged turn keeps the name it was spoken under")
    func transcriptKeepsHistoricalNames() {
        // A rename does not rewrite history: the tag comes from the turn, so earlier
        // turns keep the name they were made under rather than being retroactively
        // attributed to the new one.
        var spec = AgentSpec.seat(index: 0)
        spec.displayName = "Mira"
        let conversation = Conversation(
            topic: "Eggs",
            turns: [
                Turn(sequence: 1, speakerName: "Agent 1", kind: .chat, content: "Earlier point.")
            ])
        let prompt = PromptBuilder.prompt(
            for: spec, others: [AgentSpec.seat(index: 1)], conversation: conversation)
        #expect(prompt[1].content.contains("[Agent 1]\nEarlier point."))
    }

    @Test("A renamed seat is named in the prompt the engine actually receives")
    @MainActor
    func renameReachesTheEngine() async {
        let specs = AgentSpec.makeSeats(count: 2)
        let stubs = specs.map { PromptRecordingStub(spec: $0) }
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        configuration.maxTurns = 2
        let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
        let engine = ConversationEngine(seats: seats, configuration: configuration)

        // Rename exactly as the window does, through the engine's live configuration.
        await stubs[0].setDisplayName("Mira")
        engine.start(topic: "Why are bird eggs ovoid?")
        await engine.waitUntilFinished()

        let prompts = await stubs[0].prompts
        #expect(!prompts.isEmpty)
        let body = prompts[0].map(\.content).joined(separator: "\n")
        #expect(body.contains("You are Mira"), "the engine was not told the new name")
    }

    @Test("A renamed seat's reply is logged under the new name")
    @MainActor
    func replyIsLoggedUnderTheNewName() async {
        let specs = AgentSpec.makeSeats(count: 1)
        let stub = PromptRecordingStub(spec: specs[0])
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        configuration.maxTurns = 1
        let engine = ConversationEngine(
            seats: [.init(spec: specs[0], engine: stub)], configuration: configuration)

        await stub.setDisplayName("Mira")
        engine.start(topic: "Why are bird eggs ovoid?")
        await engine.waitUntilFinished()

        let chat = engine.conversation.turns.filter { $0.kind == .chat }
        #expect(chat.count == 1)
        // The transcript is tagged from the seat's live name, so the log and the window
        // agree about who is speaking.
        #expect(chat[0].speakerName == "Mira")
    }

    @Test("Renaming does not disturb identity, model or sampler")
    func renameIsCosmeticToConfiguration() {
        var spec = AgentSpec.seat(index: 0)
        let before = (spec.id, spec.modelID, spec.personaID, spec.thinking, spec.temperature)
        spec.displayName = "Mira"
        #expect(spec.id == before.0, "the seat id must stay stable for the log and settings")
        #expect(spec.modelID == before.1)
        #expect(spec.personaID == before.2)
        #expect(spec.thinking == before.3)
        #expect(spec.temperature == before.4)
    }
}
