// ChatBotsCoreTests — readiness for rosters larger than two
//
// The app ships with two seats. These tests exist so that adding a third or fourth is a
// configuration change rather than a refactor: they assert the properties a larger roster
// depends on, at 3 and 4 seats, including a full round of turn rotation.

import ChatBotsCore
import Testing

/// Records what it was asked, per seat.
private actor MultiStubEngine: LLMEngine {
    nonisolated let spec: AgentSpec
    private(set) var prompts: [[PromptMessage]] = []
    private var replies = 0

    init(spec: AgentSpec) { self.spec = spec }

    var isLoaded: Bool { true }
    var contextWindow: Int { 32_768 }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}

    func compact(prompt: String, maxTokens: Int) async throws -> String {
        "stub digest"
    }

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        prompts.append(messages)
        replies += 1
        let text = "\(spec.id) reply \(replies)"
        await onEvent(.token(agentID: spec.id, text: text))
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 1, generationTokens: 2, stopReason: "stop")))
        return text
    }
}

@MainActor
private func makeRoster(_ count: Int, rounds: Int) -> (ConversationEngine, [MultiStubEngine]) {
    let specs = AgentSpec.makeSeats(count: count)
    let engines = specs.map { MultiStubEngine(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = count * rounds
    let seats = zip(specs, engines).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    return (ConversationEngine(seats: seats, configuration: configuration), engines)
}

@Suite("Roster size")
struct RosterTests {

    @Test("Seats are generated with distinct ids, up to the supported maximum")
    func seatGeneration() {
        for count in 1...AgentSpec.supportedSeatCount {
            let specs = AgentSpec.makeSeats(count: count)
            #expect(specs.count == count)
            let ids = specs.map(\.id)
            #expect(Set(ids).count == count, "seat ids must be unique")
            #expect(ids == (1...count).map { "Agent \($0)" })
        }
    }

    @Test("A count beyond the supported maximum is clamped, not crashed")
    func countIsClamped() {
        #expect(AgentSpec.makeSeats(count: 99).count == AgentSpec.supportedSeatCount)
        #expect(AgentSpec.makeSeats(count: 0).count == 1)
        #expect(AgentSpec.makeSeats(count: -3).count == 1)
    }

    @Test("Each generated seat gets its own style, so a roster is not four of a kind")
    func personasAreDistinct() {
        let specs = AgentSpec.makeSeats(count: AgentSpec.supportedSeatCount)
        let personas = specs.map(\.personaID)
        #expect(Set(personas).count == specs.count, "got \(personas)")
        for spec in specs {
            #expect(spec.persona.id != PersonaLibrary.neutral.id, "\(spec.id) has no style")
        }
    }

    @Test("Each seat can be pointed at a different checkpoint")
    func perSeatModels() {
        let specs = AgentSpec.makeSeats(
            count: 3,
            modelIDs: [
                "mlx-community/Qwen3.5-4B-MLX-4bit",
                "mlx-community/Qwen3.5-9B-MLX-4bit",
                "mlx-community/Qwen3.5-0.8B-MLX-4bit",
            ])
        #expect(specs.count == 3)
        #expect(Set(specs.map(\.modelID)).count == 3, "each seat should keep its own model")
        // A short list must not drop seats; the rest fall back to the default.
        let partial = AgentSpec.makeSeats(count: 3, modelIDs: ["only/one"])
        #expect(partial.count == 3)
        #expect(partial[0].modelID == "only/one")
        #expect(partial[1].modelID == AgentSpec.defaultModelID)
    }

    @Test("Seats have distinct sampling seeds, so identical weights do not converge")
    func distinctSeeds() {
        let seeds = AgentSpec.makeSeats(count: AgentSpec.supportedSeatCount).map(\.samplingSeed)
        #expect(Set(seeds).count == seeds.count)
    }

    @Test("Turn order rotates through every seat and then repeats")
    @MainActor
    func rotationThroughAllSeats() async {
        let (engine, _) = makeRoster(3, rounds: 2)
        engine.start(topic: "Why are eggs not round?")
        await engine.waitUntilFinished()

        let speakers = engine.conversation.turns.filter { $0.kind == .chat }.map(\.speakerName)
        #expect(speakers == ["Agent 1", "Agent 2", "Agent 3", "Agent 1", "Agent 2", "Agent 3"])
    }

    @Test("Four seats rotate in order too")
    @MainActor
    func rotationOfFour() async {
        let (engine, _) = makeRoster(4, rounds: 2)
        engine.start(topic: "Eggs")
        await engine.waitUntilFinished()

        let speakers = engine.conversation.turns.filter { $0.kind == .chat }.map(\.speakerName)
        #expect(speakers == ["Agent 1", "Agent 2", "Agent 3", "Agent 4", "Agent 1", "Agent 2", "Agent 3", "Agent 4"])
    }

    @Test("Every seat reads the contributions of all the others")
    @MainActor
    func crossSeatContext() async {
        let (engine, engines) = makeRoster(4, rounds: 2)
        engine.start(topic: "Eggs")
        await engine.waitUntilFinished()

        // Seat 4's second turn must contain all three other seats' first contributions.
        let prompts = await engines[3].prompts
        #expect(prompts.count == 2)
        let second = prompts[1][1].content
        for speaker in ["Agent 1", "Agent 2", "Agent 3"] {
            #expect(second.contains("[\(speaker)]"), "seat 4 never saw \(speaker)")
        }
        // And its own earlier reply, so it can avoid repeating itself.
        #expect(second.contains("[Agent 4]"))
    }

    @Test("The introduction names every participant of a four-seat roster")
    func introductionNamesAll() {
        let specs = AgentSpec.makeSeats(count: 4)
        let text = PromptBuilder.introduction(specs: specs, topic: "Eggs")
        #expect(text.contains("4 different LLMs"))
        for spec in specs {
            #expect(text.contains(spec.id))
        }
    }

    @Test("A seat is told about all the other seats, and never about itself as an other")
    func systemMessageListsEveryCounterpart() {
        let specs = AgentSpec.makeSeats(count: 4)
        let message = PromptBuilder.systemMessage(for: specs[0], others: Array(specs.dropFirst()), topic: "Eggs")
        #expect(message.contains("You are Agent 1"))
        for other in specs.dropFirst() {
            #expect(message.contains(other.id))
        }
        #expect(!message.contains("The other participant(s): Agent 1,"))
    }

    @Test("The turn limit scales with the roster in the default configuration")
    @MainActor
    func turnLimitIsReachable() async {
        let (engine, _) = makeRoster(4, rounds: 1)
        engine.start(topic: "Eggs")
        await engine.waitUntilFinished()
        #expect(engine.status == .limitReached)
        #expect(engine.conversation.turns.filter { $0.kind == .chat }.count == 4)
    }
}

@Suite("Seat roster configuration")
struct SeatRosterTests {

    @Test("The shipping roster is two seats")
    func defaultIsTwo() {
        #expect(AgentSpec.SeatRoster.count(environment: [:]) == 2)
        #expect(AgentSpec.SeatRoster.specs(environment: [:]).count == 2)
    }

    @Test("The roster size can be raised by environment override")
    func environmentOverride() {
        let key = AgentSpec.SeatRoster.environmentKey
        #expect(AgentSpec.SeatRoster.count(environment: [key: "3"]) == 3)
        #expect(AgentSpec.SeatRoster.count(environment: [key: "4"]) == 4)
        #expect(
            AgentSpec.SeatRoster.specs(environment: [key: "4"]).map(\.id)
                == ["Agent 1", "Agent 2", "Agent 3", "Agent 4"])
    }

    @Test("A bad or oversized override falls back safely")
    func badOverride() {
        let key = AgentSpec.SeatRoster.environmentKey
        #expect(AgentSpec.SeatRoster.count(environment: [key: "nonsense"]) == 2)
        #expect(AgentSpec.SeatRoster.count(environment: [key: ""]) == 2)
        #expect(
            AgentSpec.SeatRoster.count(environment: [key: "50"]) == AgentSpec.supportedSeatCount)
        #expect(AgentSpec.SeatRoster.count(environment: [key: "0"]) == 1)
    }
}
