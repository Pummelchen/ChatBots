// ChatBotsCoreTests — A44: a restored, finished research session is not re-reported
//
// `load()` restores `conversation.research` including its finished latch, and `start()` skips
// `beginResearchSessionIfNeeded` because the session is already there. The loop's finished
// check therefore fired against the restored session and wrote a second report — a fresh
// minutes-long model call over a transcript with no new turns. `reset()` is the existing
// precedent for clearing that state, which is why "clear then start" was already fixed.

import ChatBotsCore
import Foundation
import Testing

/// A research seat that answers contributions with nothing new (so the session converges)
/// and writes a labelled report when the moderator asks for one.
private actor ReportStub: LLMEngine {
    nonisolated let spec: AgentSpec
    private(set) var reportRequests = 0

    init(spec: AgentSpec) { self.spec = spec }

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
        let joined = messages.map(\.content).joined(separator: "\n")
        let text: String
        if joined.contains("your job now is to write the report") {
            reportRequests += 1
            text = """
                # Executive Summary

                The question is not settled on the evidence gathered.

                ## Key Findings

                - **FACT:** registrations rose in 2024
                - **INFERENCE:** growth does not establish profitability

                ## Areas of Disagreement

                - The analysts read the same evidence differently.

                ## Unknowns / Evidence Gaps

                - Nobody established the capital cost.
                """
        } else {
            text = "A consideration that adds nothing new to the discussion."
        }
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 10, stopReason: "stop")))
        return text
    }
}

@MainActor
private func makeResearchEngine() -> (ConversationEngine, [ReportStub]) {
    let specs = AgentSpec.makeSeats(count: 2).map { seat -> AgentSpec in
        var copy = seat
        copy.mode = .research
        copy.personaID = seat.id == "Agent 1" ? "research-moderator" : "economist"
        return copy
    }
    let stubs = specs.map { ReportStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 40
    var budget = ResearchBudget.preset(.quick)
    budget.maxRounds = 4
    budget.maxSearches = 100
    budget.maxDuration = 3_600
    configuration.researchBudget = budget
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    return (ConversationEngine(seats: seats, configuration: configuration), stubs)
}

@MainActor
private func reportRequests(of stubs: [ReportStub]) async -> Int {
    var total = 0
    for stub in stubs { total += await stub.reportRequests }
    return total
}

@Suite("A finished research conversation is not reported twice")
struct AuditEngineStateResearchTests {

    @Test("Reopening a finished session and pressing Start writes no second report")
    @MainActor
    func finishedSessionIsNotReReported() async throws {
        // Run one investigation to completion so there is a real finished session and report.
        let (engine, _) = makeResearchEngine()
        engine.start(topic: "Should Company X enter the German EV market?")
        await engine.waitUntilFinished()

        let originalReport = try #require(engine.researchReport())
        let reportTurns = engine.conversation.turns.filter { $0.kind == .report }.count
        let chatTurns = engine.conversation.turns.filter { $0.kind == .chat }.count
        #expect(reportTurns == 1, "the run did not produce exactly one report to restore")

        let record = StoredConversation(
            id: engine.conversationID,
            conversation: engine.conversation,
            seats: engine.specs,
            startedAt: .now)

        // Reopen it in a fresh engine, exactly as the saved-conversation route does.
        let (reopened, reopenedStubs) = makeResearchEngine()
        #expect(reopened.load(record))
        #expect(reopened.researchReport() != nil, "the report should have come back with the record")

        reopened.start()
        await reopened.waitUntilFinished()

        #expect(
            await reportRequests(of: reopenedStubs) == 0,
            "the restored, already-finished session called the moderator for a second report")
        #expect(
            reopened.conversation.turns.filter { $0.kind == .report }.count == 1,
            "a second report was appended to the restored log")
        #expect(
            reopened.conversation.turns.filter { $0.kind == .chat }.count == chatTurns,
            "the finished run added turns it should not have")
        #expect(reopened.researchReport()?.question == originalReport.question)
    }

    @Test("A session saved mid-run is still resumed rather than suppressed")
    @MainActor
    func unfinishedSessionStillRuns() async throws {
        // The guard is about a report that already exists, not about refusing to run a
        // restored session: a session interrupted before it concluded must carry on.
        let (engine, _) = makeResearchEngine()
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        var unfinished = StoredConversation(
            id: engine.conversationID,
            conversation: engine.conversation,
            seats: engine.specs,
            startedAt: .now)
        let budget = try #require(unfinished.research?.budget)
        unfinished.research = ResearchSession(budget: budget, startedAt: .now)
        unfinished.report = nil
        unfinished.turns = unfinished.turns.filter { $0.kind != "report" }

        let (reopened, reopenedStubs) = makeResearchEngine()
        #expect(reopened.load(unfinished))
        reopened.start()
        await reopened.waitUntilFinished()

        #expect(
            await reportRequests(of: reopenedStubs) > 0,
            "a restored session that had not concluded was never resumed")
        #expect(reopened.conversation.turns.contains { $0.kind == .report })
    }
}
