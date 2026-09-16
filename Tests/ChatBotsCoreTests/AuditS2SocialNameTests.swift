// ChatBotsCoreTests — the social reader speaks the names the models see (A199).
//
// The social state is keyed by seat id, and the reader matched the *message text* against those ids —
// "Agent 1", "Agent 2" — while every surface the models read uses the participant's display name. So
// "Otto, that's rubbish" resolved no named target at all (the jab landed on whoever spoke last), and
// the briefing told the room "Towards Agent 1: openly hostile" about a person it has never seen under
// that name. Two strings, one key space: the name is what is read, the id is what is stored.

import Foundation
import Testing
@testable import ChatBotsCore

@Suite("The social reader matches the names the models write (A199)")
@MainActor
struct SocialNameTests {

    /// What the engine passes: lowercased display name to seat id.
    private let names = ["otto": "Agent 2", "mira": "Agent 1"]

    @Test("A peer addressed by name resolves to that seat's id")
    func namedPeerResolvesToTheID() {
        let signals = ConflictReader.signals(
            in: "Otto, you are clueless about this",
            from: "Agent 1",
            others: ["Agent 1", "Agent 2"],
            names: names,
            addressing: nil)

        // The defect: matching against ids found nothing, so the target was nil and, with no previous
        // speaker either, the jab fell to the room.
        let jab = signals.first { $0.kind == .jab }
        #expect(jab != nil, "the phrase is a jab")
        #expect(jab?.target == "Agent 2", "and it is aimed at Otto, whose id is Agent 2")
    }

    @Test("A name inside a longer word is not a match")
    func wordBoundariesStillHold() {
        // The boundary rule the reader already had, now applied to the names.
        let signals = ConflictReader.signals(
            in: "the ottoman empire was large",
            from: "Agent 1",
            others: ["Agent 1", "Agent 2"],
            names: names,
            addressing: nil)
        #expect(signals.allSatisfy { $0.target != "Agent 2" }, "ottoman is not Otto")
    }

    @Test("The briefing names the person, not the seat id")
    func briefingUsesTheName() {
        var conflict = ConflictState()
        conflict.apply(
            signals: [TurnSignal(kind: .jab, confidence: 0.9, target: "Agent 2")],
            from: "Agent 1",
            others: ["Agent 1", "Agent 2"],
            sequence: 3,
            summary: "you are being ridiculous")

        let named = conflict.briefing(
            for: "Agent 1", others: ["Agent 1", "Agent 2"],
            names: ["Agent 1": "Mira", "Agent 2": "Otto"])
        #expect(
            named.relationships.contains { relationship in
                relationship.hasPrefix("Towards Otto:")
            }, "the room is told about Otto, was \(named.relationships)")
        #expect(
            !named.relationships.contains { relationship in
                relationship.contains("Agent 2")
            }, "and never about an id it has not seen")
    }

    @Test("Without a name map the id is still shown, so nothing is lost")
    func withoutNamesTheIDIsUsed() {
        var conflict = ConflictState()
        conflict.apply(
            signals: [TurnSignal(kind: .jab, confidence: 0.9, target: "Agent 2")],
            from: "Agent 1",
            others: ["Agent 1", "Agent 2"],
            sequence: 3,
            summary: "you are being ridiculous")
        let plain = conflict.briefing(for: "Agent 1", others: ["Agent 1", "Agent 2"])
        #expect(plain.relationships.contains { $0.hasPrefix("Towards Agent 2:") })
    }

    @Test("The index drops names the reader would not match on anyway")
    func theIndexSkipsVeryShortNames() {
        var short = AgentSpec.seat(index: 0)
        short.displayName = "A"
        var long = AgentSpec.seat(index: 1)
        long.displayName = "Otto"

        let index = ConversationEngine.nameIndex([short, long])
        #expect(index["otto"] == long.id)
        #expect(index["a"] == nil, "a one-letter name would match by accident")
    }
}
