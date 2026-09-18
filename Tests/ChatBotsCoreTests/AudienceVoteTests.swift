// ChatBotsCoreTests — the audience's verdict
//
// Two things are being pinned here. The first is the arithmetic and the persistence, which are
// ordinary. The second is the boundary: a vote is the audience's opinion *about* the transcript,
// and the one thing it must never do is reach a model. A score that leaked into a prompt would
// let the audience's judgement of one seat steer another seat's next turn, which is exactly what
// a shared log exists to prevent — and it would do it invisibly, because nobody reads a prompt.

import ChatBotsCore
import Foundation
import Testing

/// A seat that answers without a model, keeping the prompts it was given.
private actor PromptLogStub: LLMEngine {
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
        prompts.append(messages.map(\.content).joined(separator: "\n"))
        let text = "According to the filings, a consideration."
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 10, stopReason: "stop")))
        return text
    }
}

// MARK: - The scorecard itself

@Suite("The audience's scorecard")
struct AudienceScorecardTests {

    private let firstTurn = UUID()
    private let secondTurn = UUID()
    private let thirdTurn = UUID()

    @Test("A vote is recorded against the seat that spoke")
    func castAndRead() {
        var card = AudienceScorecard()
        card.cast(.strong, for: firstTurn, seatID: "eco")
        #expect(card.vote(for: firstTurn)?.verdict == .strong)
        #expect(card.vote(for: firstTurn)?.seatID == "eco")
    }

    @Test("Voting twice changes the vote rather than counting twice")
    func oneVotePerContribution() {
        // Otherwise a reader could inflate a score by clicking, and the scorecard would be
        // measuring persistence rather than judgement.
        var card = AudienceScorecard()
        card.cast(.strong, for: firstTurn, seatID: "eco")
        card.cast(.weak, for: firstTurn, seatID: "eco")
        #expect(card.votes.count == 1)
        #expect(card.vote(for: firstTurn)?.verdict == .weak)
        #expect(card.scores.first?.weak == 1)
        #expect(card.scores.first?.strong == 0)
    }

    @Test("A vote can be withdrawn, so a mis-click is not reversed by its opposite")
    func withdraw() {
        var card = AudienceScorecard()
        card.cast(.strong, for: firstTurn, seatID: "eco")
        card.withdraw(turnID: firstTurn)
        #expect(card.votes.isEmpty)
        #expect(card.scores.isEmpty)
    }

    @Test("The scorecard is sorted by score and then by seat, so two readers see one order")
    func ordering() {
        var card = AudienceScorecard()
        card.cast(.weak, for: firstTurn, seatID: "eco")
        card.cast(.strong, for: secondTurn, seatID: "eco")
        card.cast(.strong, for: thirdTurn, seatID: "sta")
        // eco: +1 -1 = 0. sta: +1. sta leads.
        #expect(card.scores.map(\.seatID) == ["sta", "eco"])
        #expect(card.leader?.seatID == "sta")
    }

    @Test("A tie has no leader rather than an arbitrary winner")
    func tieHasNoLeader() {
        var card = AudienceScorecard()
        card.cast(.strong, for: firstTurn, seatID: "eco")
        card.cast(.strong, for: secondTurn, seatID: "sta")
        #expect(card.leader == nil, "picking one would be inventing a winner")

        // And a level but negative scorecard has no leader either: nobody was ahead.
        var negative = AudienceScorecard()
        negative.cast(.weak, for: firstTurn, seatID: "eco")
        #expect(negative.leader == nil)
    }

    @Test("A seat with a positive score leads even when another has more votes")
    func leaderByScoreNotVolume() {
        var card = AudienceScorecard()
        card.cast(.weak, for: firstTurn, seatID: "eco")
        card.cast(.weak, for: secondTurn, seatID: "eco")
        card.cast(.strong, for: thirdTurn, seatID: "sta")
        #expect(card.leader?.seatID == "sta")
    }
}

// MARK: - Through the engine

@MainActor
private func votingEngine() -> (EngineService, ConversationEngine, [PromptLogStub]) {
    let specs = AgentSpec.makeSeats(count: 2)
    let stubs = specs.map { PromptLogStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 2
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    engine.setTopic("A question")
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "vote-\(UUID().uuidString)"))
    return (EngineService(engine: engine, store: store), engine, stubs)
}

/// A research pair, for the tests that need a report to exist.
@MainActor
private func researchService() -> (EngineService, ConversationEngine) {
    let specs = AgentSpec.makeSeats(count: 2).map { seat -> AgentSpec in
        var copy = seat
        copy.mode = .research
        copy.personaID = seat.id == "Agent 1" ? AnalystLibrary.moderatorID : "economist"
        return copy
    }
    let stubs = specs.map { PromptLogStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    var budget = ResearchBudget.preset(.quick)
    budget.maxRounds = 2
    budget.maxSearches = 50
    budget.maxDuration = 3_600
    configuration.researchBudget = budget
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "research-vote-\(UUID().uuidString)"))
    return (EngineService(engine: engine, store: store), engine)
}

@Suite("Voting on a conversation")
@MainActor
struct AudienceVotingTests {

    @Test("A contribution can be scored, and the scorecard comes back")
    func voteReachesTheSnapshot() async {
        let (service, engine, _) = votingEngine()
        engine.start()
        await engine.waitUntilFinished()

        let contribution = engine.conversation.turns.first { $0.kind == .chat }
        let id = contribution?.id.uuidString ?? ""
        let reply = await service.handle(.castVote(turnID: id, verdict: .strong))
        let snapshot = reply.snapshot
        #expect(snapshot?.votes.count == 1)
        #expect(snapshot?.audience.first?.strong == 1)
        #expect(snapshot?.audience.first?.score == 1)
        // Named, so a scorecard is not a row of seat identifiers.
        #expect(snapshot?.audience.first?.name.isEmpty == false)
    }

    @Test("Only a contribution can be scored")
    func onlyContributionsCanBeScored() async {
        let (service, engine, _) = votingEngine()
        engine.start()
        await engine.waitUntilFinished()

        // The topic, the opening brief and the moderator's turns are not arguments, and a score
        // against them would be a judgement of something nobody said.
        for turn in engine.conversation.turns where turn.kind != .chat {
            let reply = await service.handle(
                .castVote(turnID: turn.id.uuidString, verdict: .strong))
            #expect(reply.refusal != nil)
        }
    }

    @Test("An id that names nothing is refused, as is one that is not an id")
    func badIdentifiers() async {
        let (service, _, _) = votingEngine()
        let unknown = await service.handle(
            .castVote(turnID: UUID().uuidString, verdict: .strong))
        #expect(unknown.refusal?.contains("no contribution") == true)

        let malformed = await service.handle(.castVote(turnID: "not-an-id", verdict: .strong))
        #expect(malformed.refusal?.contains("valid message id") == true)
    }

    @Test("A vote survives being saved and reopened")
    func votesAreKept() async {
        let (service, engine, _) = votingEngine()
        engine.start()
        await engine.waitUntilFinished()
        let id = engine.conversation.turns.first { $0.kind == .chat }?.id.uuidString ?? ""
        _ = await service.handle(.castVote(turnID: id, verdict: .weak))

        let kept = service.store.list()
        #expect(kept.count == 1)
        #expect(kept.first?.votes?.count == 1)
        #expect(kept.first?.conversation().votes.first?.verdict == .weak)

        // And through the engine's own load path, which is what a front end calls.
        _ = await service.handle(.newConversation)
        let reloaded = await service.handle(.loadSavedConversation(id: kept.first?.id.uuidString ?? ""))
        #expect(reloaded.snapshot?.votes.count == 1)
        #expect(engine.conversation.votes.first?.verdict == .weak)
    }

    @Test("A reopened investigation keeps its report, which is the deliverable")
    func reportsAreKept() async {
        // Without this, reopening a finished research session returned the argument and lost
        // the answer — keeping the half nobody needs and dropping the half they do.
        let (service, engine) = researchService()

        engine.start(topic: "A question")
        await engine.waitUntilFinished()
        #expect(engine.researchReport() != nil)

        let kept = service.store.list()
        #expect(kept.first?.report != nil, "the report must be written to disk")
        #expect(kept.first?.research != nil, "and so must the budget accounting")

        _ = await service.handle(.newConversation)
        #expect(engine.researchReport() == nil)
        _ = await service.handle(.loadSavedConversation(id: kept.first?.id.uuidString ?? ""))
        #expect(engine.researchReport() != nil, "reopening must restore the deliverable")
        #expect(engine.researchSession != nil)
    }

    @Test("Clearing the votes empties the scorecard")
    func clearing() async {
        let (service, engine, _) = votingEngine()
        engine.start()
        await engine.waitUntilFinished()
        let id = engine.conversation.turns.first { $0.kind == .chat }?.id.uuidString ?? ""
        _ = await service.handle(.castVote(turnID: id, verdict: .strong))
        let reply = await service.handle(.clearVotes)
        #expect(reply.snapshot?.votes.isEmpty == true)
        #expect(reply.snapshot?.audience.isEmpty == true)
    }

    @Test("A vote never reaches a prompt")
    func votesStayOutOfThePrompt() async {
        // The boundary the whole design rests on. A score that leaked into a prompt would let
        // the audience's opinion of one seat shape another seat's turn, invisibly, because
        // nobody reads a prompt.
        //
        // Asserted as an equality rather than by looking for words: the prompt with votes and
        // the prompt without them must be byte-for-byte the same. Searching for "strong" or
        // "audience" would fail on the mode's own rules — which really do say "strong
        // personalities" and "the audience is watching" — and a test that fails on unrelated
        // prose is a test nobody will keep.
        let (service, engine, _) = votingEngine()
        engine.start()
        await engine.waitUntilFinished()

        let id = engine.conversation.turns.first { $0.kind == .chat }?.id.uuidString ?? ""
        let without = renderedPrompt(engine)

        _ = await service.handle(.castVote(turnID: id, verdict: .strong))
        _ = await service.handle(.castVote(turnID: id, verdict: .weak))
        #expect(engine.conversation.votes.count == 1)

        #expect(renderedPrompt(engine) == without)
    }

    private func renderedPrompt(_ engine: ConversationEngine) -> String {
        PromptBuilder.prompt(
            for: engine.specs[0], others: [engine.specs[1]], conversation: engine.conversation
        ).map(\.content).joined(separator: "\n")
    }

    @Test("Clearing a finished investigation leaves it able to run again")
    func clearingAllowsAnotherRun() async {
        // The bug this pins: the research session survived a reset with its stop reason latched,
        // so Clear then Start found a session that was already over, wrote a report with no
        // turns behind it, and appeared to do nothing.
        let (service, engine) = researchService()
        engine.start(topic: "A question")
        await engine.waitUntilFinished()
        #expect(engine.researchReport() != nil)

        _ = await service.handle(.newConversation)
        #expect(engine.researchReport() == nil, "the deliverable belongs to the conversation")
        #expect(engine.researchSession == nil, "and so does the budget")
        #expect(engine.conversation.votes.isEmpty)

        engine.start()
        await engine.waitUntilFinished()
        #expect(
            engine.conversation.turns.contains { $0.kind == .chat },
            "a cleared investigation must be able to run again")
    }
}
