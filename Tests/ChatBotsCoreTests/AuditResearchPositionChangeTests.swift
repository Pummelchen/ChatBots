// ChatBotsCoreTests — A71: a position change is progress, not silence
//
// `ConflictState` declared `.positionChange` and handled it, but `ConflictReader` never emitted
// it, while `ConversationEngine` counted a turn as progress only when it brought `.newEvidence`
// or `.positionChange`. The second branch could therefore never fire: a turn that revised its
// conclusion without an evidence marker incremented `quietRounds`, and after two to four such
// turns the session reported that the analysts had "converged and further discussion is not
// adding anything" while their positions were moving.
//
// These tests hold the emitted signal, the engine-level consequence, and the narrowed claim.

import ChatBotsCore
import Foundation
import Testing

@Suite("A revision is read as a position change (A71)")
struct AuditResearchPositionChangeTests {

    private func kinds(_ text: String) -> [TurnSignal.Kind] {
        ConflictReader.signals(
            in: text, from: "eco", others: ["eco", "sta"], addressing: "sta"
        ).map(\.kind)
    }

    @Test("Explicit self-revision is a position change")
    func revisionIsRead() {
        #expect(kinds("On reflection, I now think the market is smaller.").contains(.positionChange))
        #expect(kinds("I was wrong about the shell thickness.").contains(.positionChange))
        #expect(kinds("Having re-read the filing, I revise my estimate down.").contains(.positionChange))
    }

    @Test("A concession moves the speaker's position too")
    func concessionIsAPositionChange() {
        // Conceding is the clearest case of a position moving, and the research engine must
        // count it as progress rather than as a turn that added nothing.
        #expect(kinds("You're right, I hadn't considered that.").contains(.positionChange))
    }

    @Test("An ordinary message is still silent")
    func neutralIsStillSilent() {
        #expect(kinds("The shell hardens in the oviduct, so the shape is set before laying.").isEmpty)
    }

    @Test("The convergence claim says what the app can actually detect")
    func theClaimIsNarrower() {
        let explanation = ResearchStop.converged.explanation
        #expect(explanation.contains("converged"))
        #expect(explanation.contains("moved no position"), "the claim must name the signal it checks")
    }
}

// MARK: - Through the real engine

/// A research seat that returns a revision with no evidence marker, so the only signal in the
/// turn is that its position moved.
private actor RevisionStub: LLMEngine {
    nonisolated let spec: AgentSpec
    private let text: String

    init(spec: AgentSpec, text: String) {
        self.spec = spec
        self.text = text
    }

    var isLoaded: Bool { true }
    var contextWindow: Int { spec.contextWindow }
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
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 10, stopReason: "stop")))
        return text
    }
}

@MainActor
private func revisionEngine(rounds: Int) -> ConversationEngine {
    var specs = AgentSpec.makeSeats(count: 2).map { seat -> AgentSpec in
        var copy = seat
        copy.mode = .research
        copy.personaID = seat.id == "Agent 1" ? AnalystLibrary.moderatorID : "economist"
        return copy
    }
    for index in specs.indices { specs[index].id = ["mod", "eco"][index] }
    let stubs = specs.map {
        RevisionStub(spec: $0, text: "On reflection, I now think the market is smaller.")
    }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 40
    var budget = ResearchBudget.preset(.quick)
    budget.maxRounds = rounds
    budget.maxSearches = 100
    budget.maxDuration = 3_600
    configuration.researchBudget = budget
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    return ConversationEngine(seats: seats, configuration: configuration)
}

@Suite("A room that keeps revising its position has not converged (A71)")
@MainActor
struct AuditResearchPositionChangeEngineTests {

    @Test("A revising turn resets the convergence count instead of adding to it")
    func revisionIsProgress() async {
        // A quick budget's convergence threshold is two. Under the old reader every one of these
        // turns counted as adding nothing, so the session would have stopped as `.converged`
        // after two turns and claimed the analysts had converged.
        let engine = revisionEngine(rounds: 6)
        engine.start(topic: "Should Company X enter the German EV market?")
        await engine.waitUntilFinished()

        let session = engine.researchSession
        #expect(session?.stop != .converged, "a room that is still moving cannot have converged")
        #expect((session?.quietRounds ?? 0) == 0, "each revision should reset the quiet count")
    }
}
