// ChatBotsCoreTests — A74: the director's conflict choice is deterministic
//
// `conflicts.first(where: { !settled.contains($0.key) })` iterated a `Dictionary`, whose order
// depends on the per-process hash seed, while the same function documents the contract
// "Deterministic rather than random: the same investigation state should direct the same way, so
// a run can be read afterwards and understood." The same saved transcript could therefore direct
// a different sub-question and a different analyst on each launch.
//
// The cross-process hash seed cannot be reproduced inside one test process, so what is held here
// is the rule that replaces it: the walk follows the sub-questions' declaration order.

import ChatBotsCore
import Testing

@Suite("The director's conflict choice is ordered (A74)")
@MainActor
struct AuditResearchDeterminismTests {

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
            analyst("law", role: "legal-analyst"),
        ]
    }

    @Test("Two live conflicts resolve to the earlier sub-question, not a dictionary pick")
    func conflictChoiceFollowsTheDeclarationOrder() {
        let director = ResearchDirector(
            seats: seats,
            covered: [.economics: ["eco", "sta"], .regulation: ["eco", "law"]],
            conflicts: [.regulation: ["eco", "law"], .economics: ["eco", "sta"]],
            analystIDs: ["eco", "sta", "law"])

        // `.economics` precedes `.regulation` in `ResearchSubQuestion.allCases`, so it is the
        // one the same state must always choose.
        #expect(director.direction().subQuestion == ResearchSubQuestion.economics.rawValue)
    }

    @Test("The same state directs the same way however the conflicts were collected")
    func theChoiceDoesNotDependOnCollectionOrder() {
        func direction(insertingFirst first: ResearchSubQuestion) -> String? {
            var conflicts: [ResearchSubQuestion: [String]] = [:]
            conflicts[first] = ["eco", "law"]
            conflicts[first == .economics ? .regulation : .economics] = ["eco", "sta"]
            let director = ResearchDirector(
                seats: seats,
                covered: [.economics: ["eco", "sta"], .regulation: ["eco", "law"]],
                conflicts: conflicts,
                analystIDs: ["eco", "sta", "law"])
            return director.direction().subQuestion
        }

        let one = direction(insertingFirst: .regulation)
        let other = direction(insertingFirst: .economics)
        #expect(one == other, "the state directed differently depending on how it was built")
        #expect(one == ResearchSubQuestion.economics.rawValue)
    }

    @Test("A settled conflict is passed over for the next one in order")
    func settledConflictsAreSkippedInOrder() {
        let director = ResearchDirector(
            seats: seats,
            covered: [.economics: ["eco", "sta"]],
            conflicts: [.regulation: ["eco", "law"], .economics: ["eco", "sta"]],
            settled: [.economics],
            analystIDs: ["eco", "sta", "law"])

        let direction = director.direction()
        #expect(direction.subQuestion == ResearchSubQuestion.regulation.rawValue)
        #expect(direction.seatID == "law", "the legal analyst owns the regulation question")
    }
}
