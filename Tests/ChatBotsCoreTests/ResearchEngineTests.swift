// ChatBotsCoreTests — the research session driven through the real engine

import ChatBotsCore
import Foundation
import Testing

/// A research seat that returns a labelled report, so the engine's own path can be exercised
/// without a model.
private actor ResearchStub: LLMEngine {
    nonisolated let spec: AgentSpec
    private(set) var prompts: [String] = []

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
        let joined = messages.map(\.content).joined(separator: "\n")
        prompts.append(joined)
        // The synthesis prompt is the one that asks for the sections. Matched on a short,
        // stable phrase: an earlier version tested a long sentence, failed to match, and
        // quietly exercised the "no labels" path instead — which is exactly why that warning
        // exists, and why this test now also covers it.
        let text: String
        if joined.contains("You are the Research Moderator. The investigation is finished")
            || joined.contains("write the report")
        {
            text = """
                # Executive Summary

                Entry looks unattractive at current capital costs.

                ## Key Findings

                - **FACT:** registrations rose in 2024
                - **INFERENCE:** growth does not establish profitability

                ## Areas of Disagreement

                - The Economist expects growth; the Investor expects margin pressure.

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
private func researchEngine(
    rounds: Int = 4,
    quietTurns: Int = 0
) -> (ConversationEngine, [ResearchStub]) {
    let specs = AgentSpec.makeSeats(count: 2).map { seat -> AgentSpec in
        var copy = seat
        copy.mode = .research
        copy.personaID = seat.id == "Agent 1" ? "research-moderator" : "economist"
        return copy
    }
    let stubs = specs.map { ResearchStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 40
    var budget = ResearchBudget.preset(.quick)
    budget.maxRounds = rounds
    budget.maxSearches = 100
    budget.maxDuration = 3_600
    configuration.researchBudget = budget
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    return (ConversationEngine(seats: seats, configuration: configuration), stubs)
}

@Suite("A research session end to end")
struct ResearchEngineTests {

    @Test("The session starts with the configured budget")
    @MainActor
    func sessionStarts() async {
        let (engine, _) = researchEngine()
        engine.start(topic: "Should Company X enter the German EV market?")
        // Starting is enough: the session exists and is being counted against.
        #expect(engine.researchSession != nil)
        #expect(engine.researchStatus()?.maxRounds == 4)
        engine.stop()
    }

    @Test("Entertainment starts no session, because it has no end condition")
    @MainActor
    func entertainmentHasNoSession() async {
        let specs = AgentSpec.makeSeats(count: 2)  // default mode is entertainment
        let stubs = specs.map { ResearchStub(spec: $0) }
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        configuration.maxTurns = 2
        let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
        let engine = ConversationEngine(seats: seats, configuration: configuration)
        engine.start(topic: "Why are eggs not round?")
        #expect(engine.researchSession == nil)
        #expect(engine.researchStatus() == nil)
        await engine.waitUntilFinished()
    }

    @Test("The session stops at its round budget and a report is produced")
    @MainActor
    func sessionStopsAndReports() async {
        // Four rounds: two for each seat, then the session is over.
        let (engine, _) = researchEngine(rounds: 4)
        engine.start(topic: "Should Company X enter the German EV market?")
        await engine.waitUntilFinished()

        // The stub never adds anything new, so convergence is reached before the round
        // budget is: two quiet contributions, which is the quick preset's threshold. That is
        // the intended behaviour — stopping when the work stops advancing rather than
        // spending the budget restating the same point.
        let session = engine.researchSession
        #expect(session?.rounds ?? 0 >= 2)
        #expect(session?.quietRounds ?? 0 >= session?.convergenceThreshold ?? 0)

        let report = engine.researchReport()
        #expect(report != nil, "a finished session must produce a report")
        #expect(report?.labelledStatements ?? 0 == 2)
        #expect(report?.isLabelled == true)
        #expect(report?.question == "Should Company X enter the German EV market?")
    }

    @Test("The report is logged as its own kind of turn, not as a contribution")
    @MainActor
    func reportIsItsOwnTurn() async {
        let (engine, _) = researchEngine(rounds: 4)
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        let reports = engine.conversation.turns.filter { $0.kind == .report }
        #expect(reports.count == 1)
        // It is the deliverable, so a front end presents it differently and the log does not
        // treat it as another message in the argument.
        #expect(reports.first?.content.contains("Executive Summary") == true)
        #expect(reports.first?.content.contains("Claim labels") == true)
    }

    @Test("The report says how far the investigation went and why it stopped")
    @MainActor
    func reportIsSelfDescribing() async {
        let (engine, _) = researchEngine(rounds: 4)
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        let markdown = engine.researchReport()?.markdown() ?? ""
        #expect(markdown.contains("How far this went"))
        #expect(markdown.contains("Ended because"))
        // The reason matters: a report that hit its round budget should not read as one that
        // concluded the question was settled.
        #expect(markdown.contains("contributions"))
    }

    @Test("The moderator writes the report, and is told it is organising rather than adding")
    @MainActor
    func moderatorWritesIt() async {
        let (engine, stubs) = researchEngine(rounds: 4)
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        // `spec` is `nonisolated let`, so finding the stub is synchronous; only reading its
        // recorded `prompts` crosses into the actor.
        let moderator = stubs.first { $0.spec.personaID == AnalystLibrary.moderatorID }
        let prompts = await moderator?.prompts ?? []
        #expect(prompts.contains { $0.contains("your job now is to write the report") })
        #expect(prompts.contains { $0.contains("not adding to it") })
        // And the analysts were never asked to write it.
        let analyst = stubs.first { $0.spec.personaID == "economist" }
        let analystPrompts = await analyst?.prompts ?? []
        #expect(!analystPrompts.contains { $0.contains("your job now is to write the report") })
    }

    @Test("The report reaches the API snapshot, with its warnings")
    @MainActor
    func reportReachesTheAPIServer() async {
        let (engine, _) = researchEngine(rounds: 4)
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        let server = APIServer(
            engine: engine,
            store: ConversationStore(
                directory: FileManager.default.temporaryDirectory
                    .appending(path: "research-\(UUID().uuidString)")),
            port: 7799)
        let snapshot = server.engineService.snapshot()
        #expect(snapshot.research != nil)
        #expect(snapshot.report != nil)
        #expect(snapshot.report?.isLabelled == true)
        #expect(snapshot.report?.labelledClaims == 2)
        // The report carries every section it did not cover, so the reader is told what is
        // missing rather than being left to assume the report is complete.
        #expect(snapshot.report?.missingSections.isEmpty == false)
        #expect(snapshot.report?.missingSections.contains("Risks") == true)
    }

    @Test("The budget cannot be changed once the investigation has started")
    @MainActor
    func budgetIsLockedOnceRunning() async {
        let (engine, _) = researchEngine(rounds: 4)
        engine.start(topic: "A question")
        #expect(!engine.setResearchBudget(.deep), "changing it midway would make progress meaningless")
        await engine.waitUntilFinished()
    }

    @Test("A budget can be chosen before the run")
    @MainActor
    func budgetIsSettableBeforeTheRun() async {
        let (engine, _) = researchEngine(rounds: 4)
        #expect(engine.setResearchBudget(.deep))
        #expect(engine.researchStatus()?.depth == "Deep")
        #expect(engine.researchStatus()?.maxRounds == ResearchBudget.preset(.deep).maxRounds)
    }

    @Test("A convergence stop produces a report too, and says why")
    @MainActor
    func convergenceAlsoReports() async {
        // The stub adds nothing new, so a quick session should decide it has converged rather
        // than spending its whole budget restating the same point.
        let (engine, _) = researchEngine(rounds: 30)
        engine.start(topic: "A question the analysts cannot advance")
        await engine.waitUntilFinished()

        let status = engine.researchStatus()
        #expect(status?.isFinished == true)
        #expect(status?.stopReason != nil)
        #expect(engine.researchReport() != nil, "a converged session still owes a report")
        // Converged, not out of time: stopping because the work is done is a better thing to
        // tell the moderator than stopping because a timer expired.
        #expect(status?.stopReason?.contains("converged") == true)
    }
}
