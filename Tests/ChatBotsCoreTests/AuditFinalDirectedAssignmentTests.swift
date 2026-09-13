// ChatBotsCoreTests — A105: the directed assignment is a marker, not a phrase
//
// A95 made a subject covered from a single seat when that seat answers the moderator's own
// assignment — but the reading recognised the assignment by matching the exact prefix
// "Nothing so far has addressed <label>" in the instruction. Reword the copy, or localise it,
// and the rule silently reverts to requiring two seats with nothing reporting the change.
//
// The director now records which rule produced a direction, the engine writes the
// unaddressed-subject assignment onto the `Turn` as `unaddressedSubject`, and the reading uses
// that marker. The wording match survives only as a one-way migration for a transcript stored
// before the field existed.

@testable import ChatBotsCore
import Foundation
import Testing

@MainActor
private func analyst(_ id: String, role: String) -> AgentSpec {
    var spec = AgentSpec.makeSeats(count: 1)[0]
    spec.id = id
    spec.personaID = role
    spec.displayName = id
    spec.mode = .research
    return spec
}

@MainActor
private var seats: [AgentSpec] {
    [
        analyst("mod", role: AnalystLibrary.moderatorID),
        analyst("eco", role: "economist"),
        analyst("sta", role: "statistician"),
    ]
}

private let allCovered: [ResearchSubQuestion: Set<String>] = Dictionary(
    uniqueKeysWithValues: ResearchSubQuestion.allCases.map { ($0, Set(["eco", "sta"])) })

@Suite("A directed assignment is carried structurally (A105)")
@MainActor
struct AuditFinalDirectedAssignmentTests {

    /// A director whose only outstanding subject is economics.
    private func directorWithEconomicsOpen() -> ResearchDirector {
        var covered = allCovered
        covered.removeValue(forKey: .economics)
        return ResearchDirector(
            seats: seats, covered: covered, analystIDs: Set(["eco", "sta"]))
    }

    private let answerOnEconomics = Turn(
        sequence: 2, speakerID: "eco", speakerName: "eco", kind: .chat,
        content: "According to the filing, the capital cost is the problem.")

    @Test("The unaddressed-subject rule is the one marked, and only when it fires")
    func kindsAreMarked() {
        let economicsOpen = directorWithEconomicsOpen().direction()
        #expect(economicsOpen.kind == .unaddressedSubject)
        #expect(economicsOpen.subQuestion == ResearchSubQuestion.economics.rawValue)

        var conflict = ResearchDirector(
            seats: seats, covered: allCovered,
            conflicts: [.economics: ["eco", "sta"]], analystIDs: Set(["eco", "sta"]))
        #expect(conflict.direction().kind == .conflict)

        conflict.conflicts = [:]
        conflict.unsupported = [(seatID: "eco", claim: "the market doubles")]
        #expect(conflict.direction().kind == .unsupportedClaim)

        // No seats and nothing outstanding: the rotation stands.
        let rotation = ResearchDirector(seats: [], covered: allCovered).direction()
        #expect(rotation.kind == .rotation)
        #expect(!rotation.isDirected)
    }

    @Test("A reworded assignment still counts from one seat")
    func rewordedAssignmentStillCounts() {
        var direction = directorWithEconomicsOpen().direction()
        #expect(direction.kind == .unaddressedSubject)
        // The copy edit A105 is about: the instruction no longer contains the old prefix.
        direction.instruction = "Take up \(ResearchSubQuestion.economics.label) next, and say what you rely on."

        let assignment = ConversationEngine.directionTurn(sequence: 1, direction: direction)
        #expect(assignment.kind == .direction)
        #expect(assignment.content == direction.instruction)
        #expect(assignment.speakerID == nil)
        #expect(
            assignment.unaddressedSubject == ResearchSubQuestion.economics.rawValue,
            "the subject must be on the turn, not only in its wording")

        let read = ResearchReading.read(seats: seats, turns: [assignment, answerOnEconomics])
        #expect(
            read.covered[.economics]?.contains("eco") == true,
            "a reworded assignment must still make one seat's answer count")
    }

    @Test("An assignment that is not the unaddressed one carries no marker")
    func onlyTheUnaddressedRuleIsMarked() {
        let conflict = ResearchDirection(
            seatID: "eco", instruction: "Settle the economics between you.",
            reason: "eco and sta conflict", subQuestion: ResearchSubQuestion.economics.rawValue,
            kind: .conflict)
        let turn = ConversationEngine.directionTurn(sequence: 1, direction: conflict)
        #expect(turn.unaddressedSubject == nil)
        #expect(turn.content == conflict.instruction)
    }

    @Test("A conflict direction does not become single-seat coverage")
    func conflictIsNotASingleSeatAssignment() {
        // The same words a directed answer would use, but the direction named a conflict, so
        // one seat naming the subject is still only a mention.
        let conflict = ResearchDirection(
            seatID: "eco", instruction: "Take up the economics — cost against return, and say what you rely on.",
            reason: "eco and sta conflict", subQuestion: ResearchSubQuestion.economics.rawValue,
            kind: .conflict)
        let turn = ConversationEngine.directionTurn(sequence: 1, direction: conflict)
        let read = ResearchReading.read(seats: seats, turns: [turn, answerOnEconomics])
        #expect(read.covered[.economics] == nil, "one seat's mention is not the room engaging")
    }

    @Test("A stored transcript without the marker still reads through the old wording")
    func legacyWordingStillReads() {
        // Exactly what an older build stored: no marker, the historical instruction.
        let label = ResearchSubQuestion.economics.label
        let legacy = Turn(
            sequence: 1, speakerName: "Research Moderator", kind: .direction,
            content: "Nothing so far has addressed \(label). Address it, and say what you are relying on.")
        #expect(legacy.unaddressedSubject == nil)

        let read = ResearchReading.read(seats: seats, turns: [legacy, answerOnEconomics])
        #expect(
            read.covered[.economics]?.contains("eco") == true,
            "a conversation saved before the field existed must read as it did")

        #expect(
            ResearchDirector.legacyUnaddressedSubject(in: legacy.content) == .economics)
        #expect(
            ResearchDirector.legacyUnaddressedSubject(in: "Take up the economics next.") == nil,
            "the fallback must not fire on wording it never wrote")
    }
}

@Suite("The assignment marker survives storage (A105)")
@MainActor
struct AuditFinalDirectedAssignmentStoreTests {

    private func conversation() -> Conversation {
        Conversation(
            topic: "Is the market real?",
            turns: [
                Turn(
                    sequence: 1, speakerName: "Research Moderator", kind: .direction,
                    content: "Take up the economics next.",
                    unaddressedSubject: ResearchSubQuestion.economics.rawValue),
                Turn(
                    sequence: 2, speakerID: "eco", speakerName: "eco", kind: .chat,
                    content: "According to the filing, it is."),
            ])
    }

    @Test("A saved conversation keeps the marker")
    func roundTripThroughTheStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "audit-final-a105-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationStore(directory: directory)

        let record = StoredConversation(
            id: UUID(), conversation: conversation(),
            seats: [AgentSpec.makeSeats(count: 1)[0]], startedAt: .now)
        #expect(store.save(record))
        let loaded = try #require(store.load().first)
        #expect(
            loaded.turns.first?.unaddressedSubject == ResearchSubQuestion.economics.rawValue,
            "the marker must survive the file, or a reload silently loses the rule")
        #expect(loaded.conversation().turns.first?.unaddressedSubject == "economics")

        // A record written before the field decodes with it absent rather than failing.
        let olderJSON = """
            {"id":"\(UUID().uuidString)","sequence":1,"speakerName":"Research Moderator",
             "kind":"direction","content":"Nothing so far has addressed \(ResearchSubQuestion.economics.label).",
             "timestamp":"2026-01-01T00:00:00Z"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let older = try decoder.decode(
            StoredConversation.StoredTurn.self, from: Data(olderJSON.utf8))
        #expect(older.unaddressedSubject == nil)
        #expect(older.kind == "direction")
    }
}
