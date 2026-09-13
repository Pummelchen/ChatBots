// ChatBotsCoreTests — A97: a basis marker must be a whole word
//
// `hasBasis` tested for markers with a bare `contains`, so "statistic" matched "statistically"
// and "source" matched "resource". A67 made that looseness load-bearing: coverage now depends on
// `hasBasis`, so every claim that a subject has been answered rested on a matcher that could
// qualify a turn on a word that merely contained a marker. The bar A67 raised was therefore not
// as high as it read.

import ChatBotsCore
import Testing

@Suite("A basis marker is a whole word (A97)")
@MainActor
struct AuditResearchBasisTests {

    @Test("A word that merely contains a marker is not a basis")
    func fragmentsAreNotABasis() {
        #expect(!ResearchDirector.hasBasis("The effect is statistically significant."))
        #expect(!ResearchDirector.hasBasis("The database is large."))
        #expect(!ResearchDirector.hasBasis("The resource is scarce."))
        #expect(!ResearchDirector.hasBasis("The script was configured yesterday."))
        #expect(!ResearchDirector.hasBasis("This is a researched opinion."))
    }

    @Test("A real marker still counts, including its inflections")
    func realMarkersCount() {
        #expect(ResearchDirector.hasBasis("According to the filing, cost is 12 percent."))
        #expect(ResearchDirector.hasBasis("The estimate was revised."))
        #expect(ResearchDirector.hasBasis("Costs were estimated at 4,200 euros."))
        #expect(ResearchDirector.hasBasis("The figures were measured directly."))
        #expect(ResearchDirector.hasBasis("This assumes the plan is funded."))
        #expect(ResearchDirector.hasBasis("Those assumptions are load-bearing."))
        #expect(ResearchDirector.hasBasis("Two sources disagree."))
    }

    @Test("The tightened rule moves coverage: two bare statistics claims are not coverage")
    func theCoverageBarMoves() {
        // Both seats name methodology through "significant", and neither gives a basis. Under the
        // old matcher "statistically" qualified as a basis and the subject became covered; now it
        // does not, so the subject stays open (A95's rule needs a real basis from both seats).
        var seats = AgentSpec.makeSeats(count: 2).map { seat -> AgentSpec in
            var copy = seat
            copy.mode = .research
            return copy
        }
        seats[0].personaID = "statistician"
        seats[1].personaID = "methodologist"
        let turns = [
            Turn(
                sequence: 1, speakerID: seats[0].id, speakerName: seats[0].id, kind: .chat,
                content: "The effect is statistically significant."),
            Turn(
                sequence: 2, speakerID: seats[1].id, speakerName: seats[1].id, kind: .chat,
                content: "The effect is statistically significant."),
        ]

        let read = ResearchReading.read(seats: seats, turns: turns)
        #expect(read.covered[.methodology] == nil, "a word containing a marker is not a basis")
    }
}
