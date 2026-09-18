// ChatBotsCoreTests — reading an investigation out of a transcript, and out of realistic prose.
//
// `ResearchReading` turns a transcript into a state; the suites here are about that half only, so a
// failure says whether the reading or the decision is wrong. They were the first two suites of
// `ResearchDirectorTests.swift`, split out when that file passed 800 lines.

import ChatBotsCore
import Foundation
import Testing

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

    @Test("Coverage is the room's engagement, not one seat's mention")
    func coverageIsRead() {
        let read = ResearchReading.read(
            seats: seats,
            turns: [
                line(1, from: "eco", "According to the filing, capital cost per unit is the problem."),
                line(2, from: "sta", "The effect is statistically significant, though the sample is small."),
                line(3, from: "sta", "The capital cost is the problem, and the filing shows it."),
            ])

        // Two seats named cost with a basis, so the room has taken the subject up.
        #expect(read.covered[.economics]?.contains("eco") == true)
        #expect(read.covered[.economics]?.contains("sta") == true)
        // The statistician raised method and nobody else did, so it is a mention and the subject
        // stays open rather than counting as answered.
        #expect(read.covered[.methodology] == nil, "one seat's mention is not coverage")
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
                According to the 2024 registrations data, the segment grew 18 percent year on                 year, \
                but the unit economics are unattractive: capital cost per vehicle is                 estimated at \
                4,200 euros against a gross margin of 11 percent. My inference is                 that volume growth \
                does not by itself produce a return at this capital intensity.
                """),
            line(
                20, from: "sta",
                """
                The method behind that 18 percent figure concerns me. It comes from a single                 registry \
                with a small sample in the final quarter, and the confidence interval                 is wide enough \
                to include flat growth. Correlation between registrations and                 demand is being treated \
                as causation here.
                """),
            line(
                30, from: "eco",
                """
                On the capital cost, the figure was measured directly from the audited filing,                 so I \
                would defend that one. Obviously the whole market will collapse if nobody                 can fund \
                the working capital.
                """),
            line(
                40, from: "sta",
                """
                On the cost side, the audited filing puts capital cost per vehicle at 4,200                 euros, so \
                I accept that figure.
                """),
        ]
    }

    @Test("Coverage is the subjects the room took up, not one seat's prose")
    func proseCoverage() {
        let read = ResearchReading.read(seats: seats, turns: transcript)

        #expect(read.contributions["eco"] == 2)
        #expect(read.contributions["sta"] == 2)
        // Both seats named cost with a basis, so the room has engaged with the economics.
        #expect(read.covered[.economics]?.contains("eco") == true)
        #expect(read.covered[.economics]?.contains("sta") == true)
        // The statistician is the only seat that raised method, so it stays open.
        #expect(read.covered[.methodology] == nil, "one seat's criticism is a mention, not coverage")
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
        // It is read as being about method, but one seat's criticism does not cover the subject:
        // the room has to take it up before the moderator stops pointing at it.
        #expect(
            ResearchDirector.subQuestions(
                in: """
                    The method behind that 18 percent figure concerns me. It comes from a single                     \
                    registry with a small sample in the final quarter, and the confidence interval                    \
                     is wide enough to include flat growth. Correlation between registrations and                     \
                    demand is being treated as causation here.
                    """
            ).contains(.methodology),
            "the criticism is about method")
        #expect(read.covered[.methodology] == nil, "but it is not yet the room's coverage")
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
        #expect(direction.seatID != nil)
        #expect(direction.seatID != "mod")
        #expect(direction.subQuestion != nil)
        #expect(!direction.instruction.isEmpty)

        // Once the two live problems are off the table, the gap that remains is the one the
        // legal analyst owns — which is the whole point of matching method to question.
        var quiet = read
        quiet.conflicts = [:]
        quiet.unsupported = []
        quiet.covered[.evidence] = ["eco", "sta"]
        quiet.covered[.magnitude] = ["eco", "sta"]
        quiet.covered[.economics] = ["eco", "sta"]
        quiet.covered[.assumptions] = ["eco", "sta"]
        quiet.covered[.outlook] = ["eco", "sta"]
        quiet.covered[.humanBehaviour] = ["eco", "sta"]
        quiet.covered[.competition] = ["eco", "sta"]
        quiet.covered[.feasibility] = ["eco", "sta"]
        quiet.covered[.methodology] = ["eco", "sta"]
        let next = quiet.direction()
        #expect(next.subQuestion == ResearchSubQuestion.regulation.rawValue)
        #expect(next.seatID == "law", "the legal analyst is who owns this question")
    }
}

// MARK: - Deciding what to do next
