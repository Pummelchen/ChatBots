// ChatBotsCoreTests — the search budget counts the calls a turn actually made
//
// `searches += searchCount` was the only input to the budget check, and the caller passed at
// most one per turn from a sequence-window heuristic. A turn making several tool calls therefore
// counted as one — so a session could run past `maxSearches` arbitrarily, the stated ceiling "so
// a session cannot run up a bill" — and the heuristic credited a seat a search it had not made,
// because its own previous turn's tool turn was still inside the window, which could trip
// `.searchesReached` early and change the report's stop reason.
//
// The engine now counts the tool calls at the callback and charges exactly those.

import ChatBotsCore
import Foundation
import Testing

/// A research seat that makes a scripted number of web tool calls each turn, reporting each one
/// the way a real engine does (a tool call callback and a `.toolResult` event).
private actor ToolCallStub: LLMEngine {
    nonisolated let spec: AgentSpec
    /// How many tool calls the next turn makes, consumed in order; the last value repeats.
    private var script: [Int]
    private let reportsResults: Bool
    /// What each reported result says it cost upstream. A tool that retried reports two.
    private let billedPerCall: Int
    private let text: String
    private var turn = 0

    init(spec: AgentSpec, script: [Int], reportsResults: Bool, billedPerCall: Int = 1, text: String) {
        self.spec = spec
        self.script = script
        self.reportsResults = reportsResults
        self.billedPerCall = billedPerCall
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
        let count = script.isEmpty ? 0 : script[min(turn, script.count - 1)]
        if turn < script.count { turn += 1 }
        for index in 0..<max(0, count) {
            await onToolCall("web_search", "query \(index)")
            if reportsResults {
                await onEvent(
                    .toolResult(
                        agentID: spec.id, name: "web_search", summary: "result \(index)",
                        detail: "result \(index)", billedUnits: billedPerCall))
            }
        }
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 10, stopReason: "stop")))
        return text
    }
}

@MainActor
private func budgetEngine(
    scripts: [[Int]],
    maxSearches: Int,
    rounds: Int,
    reportsResults: Bool = true,
    billedPerCall: Int = 1
) -> (ConversationEngine, [ToolCallStub]) {
    let specs = AgentSpec.makeSeats(count: 2).map { seat -> AgentSpec in
        var copy = seat
        copy.mode = .research
        copy.personaID = seat.id == "Agent 1" ? AnalystLibrary.moderatorID : "economist"
        copy.webSearchEnabled = true
        return copy
    }
    let stubs = specs.enumerated().map { index, spec in
        ToolCallStub(
            spec: spec,
            script: index < scripts.count ? scripts[index] : [],
            reportsResults: reportsResults,
            billedPerCall: billedPerCall,
            // Sourced so the turn counts as progress and the session does not converge before
            // the search ceiling is what stops it, and naming no subject so it cannot claim the
            // investigation is answered.
            text: "According to the filings, a consideration that adds nothing new.")
    }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 40
    var budget = ResearchBudget.preset(.quick)
    budget.maxRounds = rounds
    budget.maxSearches = maxSearches
    budget.maxDuration = 3_600
    configuration.researchBudget = budget
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    return (ConversationEngine(seats: seats, configuration: configuration), stubs)
}

@Suite("The search budget counts real tool calls")
@MainActor
struct ResearchSearchBudgetTests {

    @Test("A turn that makes three tool calls is charged three, not one")
    func multiCallTurnIsChargedInFull() async {
        // The first seat makes three calls on its first turn and none afterwards; the second
        // never searches. The old window heuristic charged one for the first turn, and then
        // charged later turns for the first turn's tool turns.
        let (engine, _) = budgetEngine(
            scripts: [[3, 0], []], maxSearches: 100, rounds: 12)
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        #expect(engine.researchSession?.searches == 3, "three calls must cost three")
    }

    @Test("A turn that makes no call is charged nothing even after one that did")
    func noPhantomCredit() async {
        // Three calls in one turn and none in any other. Anything other than three means a turn
        // was credited for a search it did not make.
        let (engine, _) = budgetEngine(
            scripts: [[3, 0], []], maxSearches: 100, rounds: 12)
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        let recorded = engine.researchSession?.searches ?? -1
        #expect(recorded == 3, "the budget recorded \(recorded) for three real calls")
    }

    @Test("The ceiling stops the session on the count that was spent")
    func ceilingBinds() async {
        // One call a turn: with a ceiling of two, the session must stop `.searchesReached`
        // after two turns rather than after one (a phantom credit) or never (a missed count).
        let (engine, _) = budgetEngine(scripts: [[1], [1]], maxSearches: 2, rounds: 12)
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        let session = engine.researchSession
        #expect(session?.searches == 2)
        #expect(session?.stop == .searchesReached)
        #expect(session?.rounds == 2, "it must not spend a round beyond the ceiling")
    }

    @Test("An unbounded session stops at the ceiling rather than running past it")
    func theBudgetBindsRatherThanBeingAdvisory() async {
        // A ceiling of four with one call a turn. The old accounting still stopped eventually
        // here, but each multi-call turn could overshoot arbitrarily; this holds the ceiling
        // for the per-turn-counts-what-it-spent rule.
        let (engine, _) = budgetEngine(scripts: [[2], [2]], maxSearches: 4, rounds: 12)
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        let session = engine.researchSession
        #expect(session?.stop == .searchesReached)
        #expect((session?.searches ?? 0) >= 4, "the ceiling was reached")
        #expect(session?.rounds == 2, "two turns of two calls is the ceiling")
    }

    @Test("A call that reports two billed searches is charged two, not one")
    func retriedCallIsChargedTwice() async {
        // `web_search` retries at advanced depth when the basic search comes back empty, so one
        // tool call can cost two billed calls. The dispatch callback charges one; the result's
        // `billedUnits` is what makes up the difference. With one call a turn at two units, a
        // ceiling of two must be reached after one turn, not two.
        let (engine, _) = budgetEngine(
            scripts: [[1], [1]], maxSearches: 2, rounds: 12, billedPerCall: 2)
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        let session = engine.researchSession
        #expect(session?.searches == 2, "the retry was charged")
        #expect(session?.stop == .searchesReached)
        #expect(session?.rounds == 1, "one turn of two billed calls is the ceiling")
    }
}
