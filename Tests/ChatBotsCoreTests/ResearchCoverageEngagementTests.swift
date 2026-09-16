// ChatBotsCoreTests — coverage is engagement, not a sentence containing the subject
//
// An earlier fix raised the bar usefully: coverage needed a contribution that gave a basis, and a marker
// had to begin a word. It did not change what coverage IS. One sourced sentence naming all ten
// subjects still satisfied every subject at once, latched `.answered`, and stopped a session
// early. Text matching cannot tell "the room worked through the cost question" from "someone
// wrote a sentence containing the word cost", so the rule is now about engagement: a subject is
// covered when more than one seat names it with a basis, or when a seat answers the moderator's
// own assignment on it.

import ChatBotsCore
import Testing

@Suite("Coverage requires the room's engagement")
@MainActor
struct ResearchCoverageEngagementTests {

    private func analyst(_ id: String, role: String) -> AgentSpec {
        var spec = AgentSpec.makeSeats(count: 1)[0]
        spec.id = id
        spec.personaID = role
        spec.displayName = id
        spec.mode = .research
        return spec
    }

    private var seats: [AgentSpec] {
        [
            analyst("mod", role: AnalystLibrary.moderatorID),
            analyst("eco", role: "economist"),
            analyst("sta", role: "statistician"),
        ]
    }

    private func line(_ sequence: Int, from seatID: String, _ text: String) -> Turn {
        Turn(sequence: sequence, speakerID: seatID, speakerName: seatID, kind: .chat, content: text)
    }

    /// Every subject in one sentence, with a basis attached — the audit's exact case.
    private let sourcedSoup = """
        According to the filings, the cost is 12 percent of a million units. Our competitors \
        are feasible, customers face regulation, and the forecast rests on one assumption and a \
        small sample.
        """

    @Test("One seat naming all ten subjects with a basis covers none of them")
    func oneSeatIsNotCoverage() {
        let read = ResearchReading.read(
            seats: seats, turns: [line(1, from: "eco", sourcedSoup)])

        #expect(read.covered.isEmpty, "a single sourced sentence covered \(read.covered.keys)")
        #expect(read.hasOpenWork, "one seat's sentence must leave the question open")
        #expect(read.unanswered != nil)
    }

    @Test("The director still points the room at the subjects a single seat raised")
    func theGapIsStillDirected() {
        let read = ResearchReading.read(
            seats: seats, turns: [line(1, from: "eco", sourcedSoup)])
        let direction = read.direction()

        #expect(direction.seatID != nil, "the moderator must keep working rather than rotate")
        #expect(direction.subQuestion != nil)
        #expect(direction.seatID != "mod")
    }

    @Test("A second seat taking the subject up is coverage")
    func twoSeatsAreCoverage() {
        let read = ResearchReading.read(
            seats: seats,
            turns: [
                line(1, from: "eco", "According to the filing, the capital cost is the problem."),
                line(2, from: "sta", "The filing shows the capital cost at 4,200 euros."),
            ])

        #expect(read.covered[.economics]?.contains("eco") == true)
        #expect(read.covered[.economics]?.contains("sta") == true)
    }

    @Test("Answering the moderator's own assignment is coverage from one seat")
    func aDirectedAnswerIsCoverage() {
        let label = ResearchSubQuestion.economics.label
        let read = ResearchReading.read(
            seats: seats,
            turns: [
                Turn(
                    sequence: 1, speakerName: "Research Moderator", kind: .direction,
                    content: "Nothing so far has addressed \(label). Address it, and say what you are relying on."),
                line(2, from: "eco", "According to the filing, the capital cost is the problem."),
            ])

        #expect(
            read.covered[.economics]?.contains("eco") == true,
            "a seat answering the assignment on a subject covers it")
    }

    @Test("A room that has taken every subject up has nothing outstanding")
    func theRoomCanStillFinish() {
        let read = ResearchReading.read(
            seats: seats,
            turns: [
                line(1, from: "eco", sourcedSoup),
                line(2, from: "sta", sourcedSoup),
            ])

        #expect(read.covered.count == ResearchSubQuestion.allCases.count)
        #expect(!read.hasOpenWork, "every subject was raised by both seats")
    }
}
