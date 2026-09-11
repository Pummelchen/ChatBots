// ChatBotsCoreTests — four seats, which had never been watched end to end
//
// The engine rotated through as many seats as it was given, but "it should work" is not the
// same as a conversation that was read. These check the things that only appear at three and
// four: that every seat actually speaks, that the rotation returns to the first, and that a
// seat cannot talk twice before the others have.

import ChatBotsCore
import Foundation
import Testing

/// Records what it was asked, so a turn can be attributed to the seat that produced it.
private actor NamingStub: LLMEngine {
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
    ) async throws -> String {
        // The seat's own name, so the log says who spoke.
        let text = "\(spec.displayName) replies."
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 4, stopReason: "stop")))
        return text
    }
}

@MainActor
private func makeEngine(seats count: Int, turns: Int) -> ConversationEngine {
    let specs = (0..<count).map { index -> AgentSpec in
        var spec = AgentSpec.seat(index: index)
        spec.displayName = ["Ann", "Ben", "Cleo", "Dara"][index]
        return spec
    }
    let stubs = specs.map { NamingStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = turns
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    engine.setTopic("A topic")
    return engine
}

@MainActor
@Suite("Four seats")
struct FourSeatTests {

    @Test("Four seats are supported and built")
    func fourSeatsBuild() {
        #expect(AgentSpec.supportedSeatCount == 4)
        let specs = AgentSpec.makeSeats(count: 4)
        #expect(specs.count == 4)
        // Each seat is a distinct participant, not four names for one.
        #expect(Set(specs.map(\.id)).count == 4)
    }

    @Test("Every seat speaks, in order, in a four-way conversation")
    func everyoneSpeaks() async {
        // The failure this is looking for is a seat that is never reached — a rotation that
        // stops at two, or one that skips.
        let engine = makeEngine(seats: 4, turns: 8)
        engine.start(topic: "A topic")
        await engine.waitUntilFinished()

        let speakers = engine.displayTurns
            .filter { $0.kind == .chat }
            .map(\.speakerName)
        #expect(speakers.count >= 4, "four seats should produce at least four turns by eight")
        let unique = Set(speakers)
        #expect(unique.count == 4, "every seat should have spoken; got \(unique.sorted())")

        // And the order repeats rather than drifting: the fifth turn belongs to the seat that
        // opened, which is what makes the rotation a rotation.
        if speakers.count >= 5 {
            #expect(speakers[4] == speakers[0], "the rotation should return to the first seat")
        }
    }

    @Test("No seat speaks twice before the others have spoken")
    func rotationIsFair() async {
        let engine = makeEngine(seats: 4, turns: 8)
        engine.start(topic: "A topic")
        await engine.waitUntilFinished()

        let speakers = engine.displayTurns.filter { $0.kind == .chat }.map(\.speakerName)
        // Every window of four consecutive turns should be four different people.
        for start in 0..<max(0, speakers.count - 3) {
            let window = Set(speakers[start..<(start + 4)])
            #expect(window.count == 4, "turns \(start)…\(start + 3) repeated a speaker: \(Array(speakers[start..<(start + 4)]))")
        }
    }

    @Test("A three-seat conversation also rotates through all three")
    func threeSeats() async {
        let engine = makeEngine(seats: 3, turns: 6)
        engine.start(topic: "A topic")
        await engine.waitUntilFinished()
        let speakers = Set(engine.displayTurns.filter { $0.kind == .chat }.map(\.speakerName))
        #expect(speakers.count == 3)
    }

    @Test("Every seat is described to the others, not just the pair")
    func everyoneIsInThePrompt() async {
        // With four seats the participants list has to name all of them or a seat will refer
        // to someone it has not been told about.
        let engine = makeEngine(seats: 4, turns: 1)
        let prompt = PromptBuilder.prompt(
            for: engine.specs[0], others: Array(engine.specs.dropFirst()),
            conversation: Conversation(topic: "A topic")
        ).map(\.content).joined(separator: "\n")
        for name in ["Ben", "Cleo", "Dara"] {
            #expect(prompt.contains(name), "\(name) is missing from the prompt")
        }
    }

    @Test("Four seats each keep their own persona")
    func personasAreIndependent() async {
        let engine = makeEngine(seats: 4, turns: 1)
        engine.updateSeat({
            var spec = engine.specs[2]; spec.personaID = "troll"; return spec
        }())
        #expect(engine.specs[2].personaID == "troll")
        // And the others are untouched, which is the thing a shared roster would get wrong.
        #expect(engine.specs[0].personaID != "troll")
        #expect(engine.specs[3].personaID != "troll")
    }
}
