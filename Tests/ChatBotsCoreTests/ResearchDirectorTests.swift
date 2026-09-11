// ChatBotsCoreTests — the moderator directing the investigation
//
// Two things are tested separately and deliberately. `ResearchReading` turns a transcript into
// a state, and `ResearchDirector` turns a state into a decision. Testing them through each other
// would mean a failure could be in either and the test could not say which — and the reading is
// the half most likely to be wrong, because it is guesswork over prose.
//
// Then one test drives a real `ConversationEngine` with stub seats, because the thing that was
// actually missing from this project was never a decision — it was a decision having any effect
// on a conversation. A unit test on `direction()` cannot show that.

import ChatBotsCore
import Foundation
import Testing

// MARK: - Helpers

/// A research analyst with a declared role, so the director can match method to question.
private func analyst(_ id: String, role: String, name: String? = nil, mode: DiscussionMode = .research) -> AgentSpec {
    var spec = AgentSpec.makeSeats(count: 1)[0]
    spec.id = id
    spec.personaID = role
    spec.displayName = name ?? id
    spec.mode = mode
    return spec
}

private func line(_ sequence: Int, from seatID: String, _ text: String) -> Turn {
    Turn(sequence: sequence, speakerID: seatID, speakerName: seatID, kind: .chat, content: text)
}

// MARK: - Reading a transcript

@Suite("Reading an investigation from its transcript")
@MainActor
struct ResearchReadingTests {

    private var seats: [AgentSpec] {
        [
            analyst("mod", role: AnalystLibrary.moderatorID),
            analyst("eco", role: "economist"),
            analyst("sta", role: "statistician"),
        ]
    }

    @Test("Only the analysts are counted, never the moderator")
    func moderatorIsNotAnAnalyst() {
        let read = ResearchReading.read(
            seats: seats,
            turns: [
                line(1, from: "mod", "According to the plan, the round begins."),
                line(2, from: "eco", "According to filings, marginal cost is 12 percent."),
                line(3, from: "sta", "The sample is small and the interval is wide."),
            ])

        #expect(read.contributions["eco"] == 1)
        #expect(read.contributions["sta"] == 1)
        #expect(read.contributions["mod"] == nil)
        #expect(read.analystIDs == ["eco", "sta"])
        // Whoever spoke most recently, so the moderator cannot hand the turn straight back.
        #expect(read.lastSpeakerID == "sta")
    }

    @Test("A contribution is read as covering the subjects it names")
    func coverageIsRead() {
        let read = ResearchReading.read(
            seats: seats,
            turns: [
                line(1, from: "eco", "According to the filing, capital cost per unit is the problem."),
                line(2, from: "sta", "The effect is statistically significant, though the sample is small."),
            ])

        #expect(read.covered[.economics]?.contains("eco") == true)
        #expect(read.covered[.methodology]?.contains("sta") == true)
        // The statistician said nothing about cost, so the gap is real rather than inferred.
        #expect(read.covered[.economics]?.contains("sta") != true)
    }

    @Test("A claim with nothing behind it is flagged, and named by what it claimed")
    func unsupportedClaimIsFlagged() {
        let read = ResearchReading.read(
            seats: seats,
            turns: [line(1, from: "eco", "Obviously the whole market is nonsense and will collapse.")])

        #expect(read.unsupported.count == 1)
        #expect(read.unsupported.first?.seatID == "eco")
        #expect(read.unsupported.first?.claim.isEmpty == false)
    }

    @Test("Once someone else takes the question up, the gap stops being reissued")
    func anAddressedGapIsDropped() {
        // The same claim, with and without a later methodological response. Without this the
        // director would ask the same question every turn until the budget ran out.
        let opened = [line(1, from: "eco", "Obviously the whole market is nonsense.")]

        let unanswered = ResearchReading.read(seats: seats, turns: opened)
        #expect(unanswered.unsupported.count == 1)

        let answered = ResearchReading.read(
            seats: seats,
            turns: opened + [line(2, from: "sta", "The method behind that cannot conclude it.")])
        #expect(answered.unsupported.isEmpty)
    }

    @Test("A challenge is paired with the claim it answered, as a conflict")
    func conflictIsPaired() {
        let read = ResearchReading.read(
            seats: seats,
            turns: [
                line(1, from: "eco", "According to the filing, capital cost is 12 percent."),
                line(2, from: "sta", "That does not follow — the capital cost was never measured."),
            ])

        let parties = read.conflicts[.economics] ?? []
        #expect(parties.contains("eco"))
        #expect(parties.contains("sta"))
    }

    @Test("A conflict the room has since worked on stops being pursued")
    func anEngagedConflictIsDropped() {
        let read = ResearchReading.read(
            seats: seats,
            turns: [
                line(1, from: "eco", "According to the filing, capital cost is 12 percent."),
                line(2, from: "sta", "That does not follow — the capital cost was never measured."),
                line(3, from: "eco", "According to the new filing, the capital cost was measured at 9 percent."),
            ])

        #expect(read.conflicts[.economics] == nil)
    }

    @Test("Agreement settles a question unless it is reopened afterwards")
    func settlementIsProvisional() {
        let agreed = ResearchReading.read(
            seats: seats,
            turns: [
                line(1, from: "eco", "According to the filing, capital cost is 12 percent."),
                line(2, from: "sta", "I agree with that cost figure."),
            ])
        #expect(agreed.settled.contains(.economics))

        let reopened = ResearchReading.read(
            seats: seats,
            turns: [
                line(1, from: "eco", "According to the filing, capital cost is 12 percent."),
                line(2, from: "sta", "I agree with that cost figure."),
                line(3, from: "eco", "That does not follow — the capital cost was never measured."),
            ])
        #expect(!reopened.settled.contains(.economics))
    }

    @Test("A research line-up with no declared roles is still read, rather than ignored")
    func rolesAreNotRequired() {
        // Two plain research seats. The director has no idea who is equipped for what, which is
        // a reason to direct badly — not a reason to sit the whole feature out.
        var first = AgentSpec.makeSeats(count: 1)[0]
        first.id = "one"
        first.personaID = ""
        first.mode = .research
        var second = first
        second.id = "two"
        second.displayName = "two"

        let read = ResearchReading.read(
            seats: [first, second],
            turns: [line(1, from: "one", "Obviously the market will collapse.")])

        #expect(read.analystIDs == ["one", "two"])
        #expect(read.contributions["one"] == 1)
        #expect(read.unsupported.count == 1)
    }

    @Test("An entertainment transcript produces no research state at all")
    func entertainmentIsNotRead() {
        let seats = [
            analyst("a", role: "economist", mode: .entertainment),
            analyst("b", role: "statistician", mode: .entertainment),
        ]
        let read = ResearchReading.read(
            seats: seats, turns: [line(1, from: "a", "Obviously the market will collapse.")])

        #expect(read.analystIDs.isEmpty)
        #expect(read.contributions.isEmpty)
        #expect(read.direction().seatID == nil)
    }
}

// MARK: - Reading prose, not stubs

@Suite("Reading a realistic investigation")
@MainActor
struct ResearchProseTests {

    /// The line-up a real research run uses: a moderator and three analysts with different
    /// methods. The contributions below are written the way a model writes them — paragraphs
    /// with sources, hedges and conclusions — because the reader is a phrase matcher and it is
    /// the *prose* it has to survive, not a one-line fixture.
    private var seats: [AgentSpec] {
        [
            analyst("mod", role: AnalystLibrary.moderatorID, name: "Chair"),
            analyst("eco", role: "economist", name: "Economist"),
            analyst("sta", role: "statistician", name: "Statistician"),
            analyst("law", role: "legal-analyst", name: "Legal Analyst"),
        ]
    }

    private var transcript: [Turn] {
        [
            line(
                10, from: "eco",
                """
                According to the 2024 registrations data, the segment grew 18 percent year on                 year, but the unit economics are unattractive: capital cost per vehicle is                 estimated at 4,200 euros against a gross margin of 11 percent. My inference is                 that volume growth does not by itself produce a return at this capital intensity.
                """),
            line(
                20, from: "sta",
                """
                The method behind that 18 percent figure concerns me. It comes from a single                 registry with a small sample in the final quarter, and the confidence interval                 is wide enough to include flat growth. Correlation between registrations and                 demand is being treated as causation here.
                """),
            line(
                30, from: "eco",
                """
                On the capital cost, the figure was measured directly from the audited filing,                 so I would defend that one. Obviously the whole market will collapse if nobody                 can fund the working capital.
                """),
        ]
    }

    @Test("Coverage is read from the subjects the prose actually discusses")
    func proseCoverage() {
        let read = ResearchReading.read(seats: seats, turns: transcript)

        #expect(read.contributions["eco"] == 2)
        #expect(read.contributions["sta"] == 1)
        #expect(read.covered[.economics]?.contains("eco") == true)
        #expect(read.covered[.methodology]?.contains("sta") == true)
        // Neither analyst has touched regulation, which is the gap the run should close.
        #expect(read.covered[.regulation] == nil)
    }

    @Test("Criticism that is not phrased as disagreement is read as coverage, not conflict")
    func implicitCriticismIsNotAConflict() {
        // The statistician's paragraph is a serious objection to the economist's method — and it
        // contains none of the phrases the reader looks for. So it is read as covering
        // methodology and *not* as a conflict, which is the honest limit of a phrase matcher:
        // it reads what is plainly there and deliberately refuses to judge what is merely
        // implied. Widening the list to catch this one example is how such a list starts
        // producing conflicts nobody raised.
        let read = ResearchReading.read(seats: seats, turns: transcript)

        #expect(read.conflicts.isEmpty, "implicit criticism must not be invented into a conflict")
        #expect(read.covered[.methodology]?.contains("sta") == true, "it is still read as coverage")
        // And the consequence for the moderator is stated in the test above it: coverage, not a
        // named disagreement, is what steers the next turn for this transcript.
    }

    @Test("A paragraph that asserts and gives no basis anywhere is flagged")
    func bareAssertionIsFlagged() {
        let read = ResearchReading.read(
            seats: seats,
            turns: [line(10, from: "eco", "Obviously the whole market will collapse.")])

        #expect(read.unsupported.count == 1)
        #expect(read.unsupported.first?.seatID == "eco")
        #expect(read.unsupported.first?.claim.lowercased().contains("collapse") == true)
    }

    @Test("A sourced sentence shelters an unsupported one beside it, which is a known limit")
    func aSourcedSentenceSheltersTheRest() {
        // "the figure was measured" and "filing" are evidence markers, so the turn as a whole is
        // read as sourced — even though the second sentence asserts a collapse with nothing
        // behind it. The reader works per contribution, not per sentence. Recorded as a limit
        // rather than fixed by making the reader sentence-splitting, which would trade a known
        // miss for a large number of unknown ones.
        let read = ResearchReading.read(seats: seats, turns: transcript)

        #expect(read.unsupported.isEmpty)
    }

    @Test("The moderator asks the legal analyst the question nobody has touched")
    func proseDirection() {
        let read = ResearchReading.read(seats: seats, turns: transcript)
        let direction = read.direction()

        // Nothing in this transcript was read as a conflict or a gap, so what is left is
        // coverage — and the assignment must still name a subject and a seat, not shrug.
        #expect(direction.isDirected)
        #expect(direction.seatID != "mod")
        #expect(direction.subQuestion != nil)
        #expect(!direction.instruction.isEmpty)

        // Once the two live problems are off the table, the gap that remains is the one the
        // legal analyst owns — which is the whole point of matching method to question.
        var quiet = read
        quiet.conflicts = [:]
        quiet.unsupported = []
        quiet.covered[.evidence] = ["eco", "sta"]
        quiet.covered[.magnitude] = ["eco"]
        quiet.covered[.assumptions] = ["eco"]
        quiet.covered[.outlook] = ["sta"]
        quiet.covered[.humanBehaviour] = ["eco"]
        quiet.covered[.competition] = ["sta"]
        quiet.covered[.feasibility] = ["sta"]
        let next = quiet.direction()
        #expect(next.subQuestion == ResearchSubQuestion.regulation.rawValue)
        #expect(next.seatID == "law", "the legal analyst is who owns this question")
    }
}

// MARK: - Deciding what to do next

@Suite("The moderator deciding what the investigation needs")
@MainActor
struct ResearchDirectorDecisionTests {

    private var seats: [AgentSpec] {
        [
            analyst("mod", role: AnalystLibrary.moderatorID),
            analyst("eco", role: "economist"),
            analyst("sta", role: "statistician"),
        ]
    }

    @Test("A claim with no basis is sent to the analyst whose method can check it")
    func unsupportedClaimGoesToMethodology() {
        let director = ResearchDirector(
            seats: seats,
            contributions: ["eco": 1],
            covered: [.economics: ["eco"]],
            unsupported: [(seatID: "eco", claim: "the market will collapse")],
            analystIDs: ["eco", "sta"])

        let direction = director.direction()
        #expect(direction.seatID == "sta", "the statistician is who checks a claim")
        #expect(direction.reason.contains("no evidence"))
        #expect(direction.instruction.contains("market will collapse"))
        #expect(direction.subQuestion == ResearchSubQuestion.methodology.rawValue)
    }

    @Test("An unanswered sub-question is directed at the analyst equipped for it")
    func unansweredGoesToTheFittingAnalyst() {
        // Everything covered except cost, and one seat on it already. The economist's declared
        // domain is where cost lives, so the economist is who gets asked.
        let director = ResearchDirector(
            seats: seats,
            contributions: ["eco": 1, "sta": 1],
            covered: [
                .evidence: ["eco"], .magnitude: ["sta"], .competition: ["eco"],
                .feasibility: ["sta"], .humanBehaviour: ["eco"], .regulation: ["sta"],
                .outlook: ["eco"], .assumptions: ["sta"], .methodology: ["sta"],
            ],
            analystIDs: ["eco", "sta"])

        let direction = director.direction()
        #expect(direction.subQuestion == ResearchSubQuestion.economics.rawValue)
        #expect(direction.seatID != nil)
        #expect(direction.instruction.contains("economics"))
    }

    @Test("The analyst who just spoke is not asked to answer themselves")
    func lastSpeakerIsSkipped() {
        let covered: [ResearchSubQuestion: Set<String>] = [
            .evidence: ["eco", "sta"], .magnitude: ["eco", "sta"], .economics: ["eco"],
            .competition: ["eco", "sta"], .feasibility: ["eco", "sta"],
            .humanBehaviour: ["eco", "sta"], .regulation: ["eco", "sta"],
            .outlook: ["eco", "sta"],
        ]
        // Only the statistician fits methodology, and the statistician has just spoken. The
        // assignment is skipped rather than handed back to the person who just made it.
        let director = ResearchDirector(
            seats: seats,
            contributions: ["eco": 1, "sta": 1],
            covered: covered,
            lastSpeakerID: "sta",
            analystIDs: ["eco", "sta"])

        let direction = director.direction()
        #expect(direction.seatID != "sta")
    }

    @Test("Nobody is directed when the room is level and everything is covered")
    func nothingOutstandingRotates() {
        var covered: [ResearchSubQuestion: Set<String>] = [:]
        for question in ResearchSubQuestion.allCases { covered[question] = ["eco", "sta"] }

        let director = ResearchDirector(
            seats: seats,
            contributions: ["eco": 2, "sta": 2],
            covered: covered,
            analystIDs: ["eco", "sta"])

        let direction = director.direction()
        #expect(direction.seatID == nil, "the rotation is the honest answer")
        #expect(direction.reason.contains("rotation"))
        #expect(direction.isDirected == false)
    }

    @Test("An analyst who has barely been heard from gets the floor")
    func quietestSeatIsDirectlyAsked() {
        var covered: [ResearchSubQuestion: Set<String>] = [:]
        for question in ResearchSubQuestion.allCases { covered[question] = ["eco"] }

        let director = ResearchDirector(
            seats: seats,
            contributions: ["eco": 4, "sta": 1],
            covered: covered,
            lastSpeakerID: "eco",
            analystIDs: ["eco", "sta"])

        let direction = director.direction()
        #expect(direction.seatID == "sta")
        #expect(direction.reason.contains("least"))
    }

    @Test("A conflict is sent to someone who can settle it, and named")
    func conflictIsNamedAndAssigned() {
        let director = ResearchDirector(
            seats: seats,
            contributions: ["eco": 1, "sta": 1],
            covered: [.economics: ["eco", "sta"]],
            conflicts: [.economics: ["eco", "sta"]],
            lastSpeakerID: "sta",
            analystIDs: ["eco", "sta"])

        let direction = director.direction()
        #expect(direction.subQuestion == ResearchSubQuestion.economics.rawValue)
        #expect(direction.reason.contains("conflict") || direction.reason.contains("Economist"))
        #expect(direction.instruction.contains("incompatible"))
    }

    @Test("The moderator is never assigned analytical work")
    func moderatorIsNeverAssigned() {
        // A line-up whose only declared role is the moderator's. There is nobody to direct, and
        // the answer to that is to rotate, not to set the moderator investigating itself.
        let seats = [analyst("mod", role: AnalystLibrary.moderatorID), analyst("eco", role: "economist")]
        let director = ResearchDirector(
            seats: seats, contributions: ["mod": 3], lastSpeakerID: "mod", analystIDs: ["eco"])

        let direction = director.direction()
        #expect(direction.seatID != "mod")
    }
}

// MARK: - Through the real engine

/// A research seat that returns one fixed line, so the engine's own loop can be driven without
/// a model. What it says decides what the moderator does next, which is the point.
private actor DirectedStub: LLMEngine {
    nonisolated let spec: AgentSpec
    private let text: String
    private(set) var prompts: [String] = []

    init(spec: AgentSpec, text: String) {
        self.spec = spec
        self.text = text
    }

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
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 10, stopReason: "stop")))
        return text
    }
}

@MainActor
private func directedEngine(
    contribution: String,
    rounds: Int = 8
) -> (ConversationEngine, [DirectedStub]) {
    // The moderator is seat one, which is exactly who a plain rotation would put first. That is
    // what makes the test able to tell directing apart from rotating.
    var specs = [
        analyst("mod", role: AnalystLibrary.moderatorID, name: "Chair"),
        analyst("eco", role: "economist", name: "Economist"),
        analyst("sta", role: "statistician", name: "Statistician"),
    ]
    for index in specs.indices { specs[index].id = ["mod", "eco", "sta"][index] }
    let stubs = specs.map { DirectedStub(spec: $0, text: contribution) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 60
    // A deep budget's convergence threshold, so a stub that adds nothing new does not end the
    // run after two turns — the point of the test is what the moderator does across a session.
    var budget = ResearchBudget.preset(.deep)
    budget.maxRounds = rounds
    budget.maxSearches = 100
    budget.maxDuration = 3_600
    configuration.researchBudget = budget
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    return (ConversationEngine(seats: seats, configuration: configuration), stubs)
}

@Suite("A directed investigation, driven through the engine")
@MainActor
struct DirectedEngineTests {

    @Test("The moderator assigns work instead of letting the rotation decide")
    func theDirectorDirects() async {
        let (engine, _) = directedEngine(contribution: "Obviously the market will collapse.")
        engine.start(topic: "Should Company X enter the German EV market?")
        await engine.waitUntilFinished()

        let directions = engine.conversation.turns.filter { $0.kind == .direction }
        #expect(directions.count >= 3, "the moderator should direct throughout, not once")
        #expect(directions.allSatisfy { $0.speakerName == "Research Moderator" })
        #expect(directions.allSatisfy { !$0.content.isEmpty })

        // Rotation would have opened with the chair, because it is seat one.
        let firstChat = engine.conversation.turns.first { $0.kind == .chat }
        #expect(firstChat?.speakerID != "mod", "the moderator does not investigate")
    }

    @Test("The seat that is assigned is the seat that speaks next")
    func theAssignmentIsFollowed() async {
        let (engine, _) = directedEngine(contribution: "Obviously the market will collapse.")
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        let turns = engine.conversation.turns
        // Each assignment must be followed by a contribution from an analyst, or the moderator
        // is writing instructions nobody acts on — which was the state of this feature before.
        let analysts = ["eco", "sta"]
        for (index, turn) in turns.enumerated() where turn.kind == .direction {
            guard let next = turns.dropFirst(index + 1).first(where: { $0.kind == .chat })
            else { continue }
            #expect(analysts.contains(next.speakerID ?? ""), "an assignment went nowhere")
        }
    }

    @Test("The assignment reaches the seat in its prompt, tagged as the moderator's")
    func theAssignmentReachesThePrompt() async {
        let (engine, stubs) = directedEngine(contribution: "Obviously the market will collapse.")
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        var dispatched: [String] = []
        for stub in stubs { dispatched.append(contentsOf: await stub.prompts) }
        #expect(
            dispatched.contains { $0.contains("[Research Moderator]") },
            "a directed turn must carry the assignment, or the decision had no effect")
    }

    @Test("What the analysts say decides what is asked next")
    func theGapDrivesTheNextAssignment() async {
        // No basis anywhere, so every assignment is the same one: check the unsupported claim.
        let (unsupported, _) = directedEngine(
            contribution: "Obviously the market will collapse.")
        unsupported.start(topic: "A question")
        await unsupported.waitUntilFinished()
        let gaps = unsupported.conversation.turns
            .filter { $0.kind == .direction }
            .map(\.content)
        #expect(gaps.contains { $0.contains("without a basis") })

        // A sourced contribution that settles nothing, so the assignments become coverage
        // rather than substantiation. Same engine, different transcript, different decision.
        let (covered, _) = directedEngine(
            contribution: "According to the filings, nothing here has been settled.")
        covered.start(topic: "A question")
        await covered.waitUntilFinished()
        let gaps2 = covered.conversation.turns
            .filter { $0.kind == .direction }
            .map(\.content)
        #expect(gaps2.contains { $0.contains("Nothing so far has addressed") })
        #expect(!gaps2.contains { $0.contains("without a basis") })
    }

    @Test("The moderator's assignments are visible in the exported transcript")
    func theAssignmentsAreInTheTranscript() async {
        let (engine, _) = directedEngine(contribution: "Obviously the market will collapse.")
        engine.start(topic: "A question")
        await engine.waitUntilFinished()

        let exported = TranscriptWriter.text(
            topic: "A question",
            turns: engine.conversation.turns,
            participants: engine.specs)
        #expect(exported.contains("RESEARCH MODERATOR — ASSIGNMENT"))
        // And it must not be filed as something the human said.
        #expect(!exported.contains("RESEARCH MODERATOR — ASSIGNMENT\n[Moderator]"))
    }

    @Test("An entertainment run is not directed at all")
    func entertainmentIsNotDirected() async {
        let specs = AgentSpec.makeSeats(count: 3)
        let stubs = specs.map { DirectedStub(spec: $0, text: "A remark about the topic.") }
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        configuration.maxTurns = 6
        let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
        let engine = ConversationEngine(seats: seats, configuration: configuration)
        engine.start(topic: "Why are eggs not round?")
        await engine.waitUntilFinished()

        #expect(engine.conversation.turns.contains { $0.kind == .direction } == false)
        // And the rotation still holds, which is the mode's whole point.
        let speakers = engine.conversation.turns.filter { $0.kind == .chat }.compactMap(\.speakerID)
        #expect(speakers.prefix(3).count == 3)
        #expect(Set(speakers.prefix(3)).count == 3)
    }
}
