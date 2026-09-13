// ChatBotsCoreTests — A67: coverage is earned rather than read from a substring
//
// `.answered` latches when `ResearchReading` finds every sub-question covered, and coverage was
// recorded for any contribution whose text merely *contained* one of a short keyword list —
// `"law"`, `"source"`, `"figure"`, `"cost"` — matched as bare substrings. A paragraph about a
// flaw, a resource and a configuration therefore covered regulation and evidence, and an
// unsourced paragraph that named every subject covered all ten, so a session could report
// "every part of the question has been addressed" on the strength of a mention.
//
// These tests fix the two halves of that: the match must begin a word, and a subject counts as
// covered only when the contribution that names it also gives a basis for what it says. The
// third test drives the engine with a paragraph that names all ten subjects and gives no basis,
// which is the case the audit names, and requires that it no longer stops as `.answered`.

import ChatBotsCore
import Foundation
import Testing

// MARK: - Reading helpers

private func analyst(_ id: String, role: String, name: String? = nil) -> AgentSpec {
    var spec = AgentSpec.makeSeats(count: 1)[0]
    spec.id = id
    spec.personaID = role
    spec.displayName = name ?? id
    spec.mode = .research
    return spec
}

private func line(_ sequence: Int, from seatID: String, _ text: String) -> Turn {
    Turn(sequence: sequence, speakerID: seatID, speakerName: seatID, kind: .chat, content: text)
}

private var readingSeats: [AgentSpec] {
    [
        analyst("mod", role: AnalystLibrary.moderatorID),
        analyst("eco", role: "economist"),
        analyst("sta", role: "statistician"),
    ]
}

/// Names every one of the ten subjects and gives a basis for none of them. The evidence subject
/// is reached through "report says", which is in the subject's list but not in `hasBasis`.
private let unsourcedSoup = """
    Report says revenue and cost matter. The market is a million units. Competitors are many, \
    capacity is feasible, customers hesitate, regulation looms, the forecast is unclear, the \
    central premise is unchecked, and the sample method is weak.
    """

/// The same subjects, with a basis attached, so the other side of the rule is covered too.
private let sourcedCoverage = """
    According to the filing, revenue and cost matter, and the sample method is sound.
    """

// MARK: - The matcher

@Suite("A subject is named by a word, not by a fragment of one")
@MainActor
struct AuditS1SubjectMatcherTests {

    @Test("A marker inside a longer word is not a match")
    func fragmentIsNotAMatch() {
        // "flaw" and "outlaw" contain "law"; "resource" contains "source"; "configure"
        // contains "figure". As bare substrings these covered regulation and evidence.
        let disguised = ResearchDirector.subQuestions(
            in: "The flaw and the outlaw are a resource for the configure script.")
        #expect(!disguised.contains(.regulation), "'law' must not match 'flaw' or 'outlaw'")
        #expect(
            !disguised.contains(.evidence),
            "'source' must not match 'resource' and 'figure' must not match 'configure'")
    }

    @Test("A marker that begins a word still matches, including as a stem")
    func realWordsStillMatch() {
        #expect(ResearchDirector.subQuestions(in: "The law requires a licence.").contains(.regulation))
        #expect(ResearchDirector.subQuestions(in: "Our competitors are many.").contains(.competition))
        #expect(ResearchDirector.subQuestions(in: "Customers hesitate.").contains(.humanBehaviour))
    }

    @Test("A percentage sign only states a magnitude when a number is attached")
    func percentageNeedsANumber() {
        #expect(ResearchDirector.subQuestions(in: "The market grew 40%.").contains(.magnitude))
        #expect(!ResearchDirector.subQuestions(in: "The % symbol is on the keyboard.").contains(.magnitude))
    }
}

// MARK: - Coverage

@Suite("Coverage requires a basis")
@MainActor
struct AuditS1CoverageTests {

    @Test("An unsourced paragraph that names every subject covers none of them")
    func unsourcedMentionIsNotCoverage() {
        let read = ResearchReading.read(
            seats: readingSeats,
            turns: [line(1, from: "eco", unsourcedSoup)])

        // The audit's case: the text names all ten subjects, and under the old rule that made
        // every one of them covered.
        #expect(
            read.covered.isEmpty,
            "a mention with nothing behind it was read as coverage: \(read.covered.keys)")
    }

    @Test("A sourced contribution covers the subjects it names")
    func sourcedMentionIsCoverage() {
        let read = ResearchReading.read(
            seats: readingSeats,
            turns: [line(1, from: "eco", sourcedCoverage)])

        #expect(read.covered[.economics]?.contains("eco") == true)
        #expect(read.covered[.methodology]?.contains("eco") == true)
    }

    @Test("The answered reason no longer claims the subjects were answered")
    func theClaimIsNarrowerThanAnswered() {
        // The reading is a phrase matcher and cannot establish that a subject was settled. The
        // report must not say it did.
        #expect(ResearchStop.answered.explanation.contains("Every part of the question"))
        #expect(ResearchStop.answered.explanation.contains("raised"))
        #expect(!ResearchStop.answered.explanation.contains("has been addressed"))
    }
}

// MARK: - Through the real engine

/// A research seat that returns one fixed line, so the engine's own loop can be driven without
/// a model. What it says decides what the moderator does next, which is the point.
private actor S1Stub: LLMEngine {
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
private func soupEngine(contribution: String, rounds: Int) -> ConversationEngine {
    var specs = [
        analyst("mod", role: AnalystLibrary.moderatorID, name: "Chair"),
        analyst("eco", role: "economist", name: "Economist"),
        analyst("sta", role: "statistician", name: "Statistician"),
    ]
    for index in specs.indices { specs[index].id = ["mod", "eco", "sta"][index] }
    let stubs = specs.map { S1Stub(spec: $0, text: contribution) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 60
    // A deep budget's convergence threshold, so a contribution that adds nothing does not end
    // the run after two turns and the test can tell an early "answered" from convergence.
    var budget = ResearchBudget.preset(.deep)
    budget.maxRounds = rounds
    budget.maxSearches = 100
    budget.maxDuration = 3_600
    configuration.researchBudget = budget
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    return ConversationEngine(seats: seats, configuration: configuration)
}

@Suite("A session does not call unsourced keyword soup an answer")
@MainActor
struct AuditS1ResearchClaimTests {

    @Test("Naming every subject without a basis does not end the session as answered")
    func unsourcedSoupDoesNotAnswer() async {
        let engine = soupEngine(contribution: unsourcedSoup, rounds: 20)
        engine.start(topic: "Should Company X enter the German EV market?")
        await engine.waitUntilFinished()

        #expect(
            engine.researchSession?.stop != .answered,
            "an unsourced paragraph naming every subject must not read as answering them")
        #expect(
            (engine.researchSession?.rounds ?? 0) > 2,
            "the session must keep working rather than concluding after a mention")
    }

    @Test("A sourced contribution covering every subject can still conclude")
    func sourcedCoverageCanAnswer() async {
        // The other side of the rule: coverage is not made unreachable, only earned. This is
        // the shape the existing `theSessionEndsWhenNothingIsOutstanding` test uses.
        let complete = """
            According to the filings, the cost is 12 percent of a million units. Our competitors \
            are feasible, customers face regulation, and the forecast rests on one assumption \
            and a small sample.
            """
        let engine = soupEngine(contribution: complete, rounds: 20)
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        #expect(engine.researchSession?.stop == .answered)
        #expect((engine.researchSession?.rounds ?? 0) < 20, "it stops before the budget")
    }
}
