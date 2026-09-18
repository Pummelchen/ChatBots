// ChatBotsCoreTests — the social state an entertainment conversation accumulates
//
// Two things matter here and both are easy to get wrong: the state has to move for the right
// reasons, and it must not move for the wrong ones. A conflict engine fed false signals is
// worse than one fed none, so the negative cases are tested as carefully as the positive.

import ChatBotsCore
import Foundation
import Testing

@Suite("Reading a turn")
struct ConflictReaderTests {

    private func kinds(
        _ text: String, from: String = "Agent 1",
        others: [String] = ["Agent 1", "Agent 2"],
        addressing: String? = "Agent 2"
    ) -> [TurnSignal.Kind] {
        ConflictReader.signals(in: text, from: from, others: others, addressing: addressing)
            .map(\.kind)
    }

    @Test("An explicit concession is read")
    func concession() {
        #expect(kinds("You're right, I hadn't considered that.").contains(.concession))
        #expect(kinds("I was wrong about the shell thickness.").contains(.concession))
        #expect(kinds("Fair enough, point taken.").contains(.concession))
    }

    @Test("Agreement is read, and is distinct from conceding")
    func agreement() {
        let agree = kinds("I agree with you about the oviduct.")
        #expect(agree.contains(.agreement))
        #expect(!agree.contains(.concession), "agreeing is not the same as losing an argument")
    }

    @Test("An apology is read as reconciliation")
    func reconciliation() {
        #expect(kinds("I'm sorry, that was uncalled for.").contains(.reconciliation))
    }

    @Test("A contradiction held up is read")
    func contradiction() {
        #expect(
            kinds("You said earlier that shells are thin. That contradicts what you just said.")
                .contains(.contradiction))
        #expect(
            kinds("First you said it was structural, now it is adaptive. Which is it?")
                .contains(.contradiction))
    }

    @Test("A personal attack is a jab; an attack on an argument is a challenge")
    func jabVersusChallenge() {
        // The distinction the brief draws, and the one that decides whether annoyance rises.
        #expect(kinds("You're an idiot.").contains(.jab))
        #expect(kinds("That's nonsense and you haven't shown anything.").contains(.challenge))
        // A challenge at a claim is not a personal attack.
        #expect(!kinds("That's ridiculous — where's your evidence?").contains(.jab))
    }

    @Test("A sourced claim is not read as unsupported")
    func evidenceIsNotUnsupported() {
        let sourced = kinds("According to the 2019 study, egg shape correlates with flight ability.")
        #expect(sourced.contains(.newEvidence))
        #expect(!sourced.contains(.unsupportedClaim))
    }

    @Test("Confident assertion with nothing behind it is read as unsupported")
    func unsupportedClaim() {
        #expect(kinds("Obviously eggs are round. Everyone knows that.").contains(.unsupportedClaim))
    }

    @Test("Hedging prevents a claim being read as overconfident")
    func hedgingIsRespected() {
        let hedged = kinds("Clearly this is true, though I'm not sure and I could be wrong.")
        #expect(
            !hedged.contains(.unsupportedClaim),
            "a seat that admits uncertainty should not be penalised for confidence")
    }

    @Test("An ordinary message produces no signals at all")
    func neutralMessageIsSilent() {
        // The most important negative case: most messages are not events, and a reader that
        // finds something in every one of them would distort the whole conversation.
        #expect(kinds("The shell hardens in the oviduct, so the shape is set before laying.").isEmpty)
        #expect(kinds("I would want to see a comparison across species.").isEmpty)
    }

    @Test("A name is only matched on a word boundary")
    func nameMatching() {
        // "Otto" must not match "ottoman", or every mention of furniture would be a jab at
        // the wrong participant.
        #expect(ConflictReader.namedTarget(in: "otto has a point", others: ["Otto"]) == "Otto")
        #expect(ConflictReader.namedTarget(in: "the ottoman empire", others: ["Otto"]) == nil)
        #expect(ConflictReader.namedTarget(in: "tootle along", others: ["Otto"]) == nil)
    }

    @Test("A very short name is not matched, because it would hit at random")
    func shortNamesAreIgnored() {
        #expect(ConflictReader.namedTarget(in: "a cat sat", others: ["A"]) == nil)
    }

    @Test("A grudge can name what was said")
    func grudgeSummary() {
        let summary = ConflictReader.summary(
            of: "That is a ridiculous claim. And you know it.")
        #expect(summary == "That is a ridiculous claim")
        // A message too short to characterise is not quoted.
        #expect(ConflictReader.summary(of: "No.") == nil)
        #expect(ConflictReader.summary(of: "   ") == nil)
    }
}

@Suite("Conflict state")
struct ConflictStateTests {

    private func state() -> ConflictState { ConflictState() }

    @Test("A jab raises the target's hostility and creates a grudge")
    func jabRaisesAnnoyance() {
        var conflict = state()
        conflict.apply(
            signals: [TurnSignal(kind: .jab, confidence: 0.9, target: "Agent 2")],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 3,
            summary: "you are being ridiculous")

        let towards = conflict.relationship(from: "Agent 1", to: "Agent 2")
        #expect(towards.annoyance > 0.3)
        #expect(towards.grudge != nil, "a jab serious enough should be remembered")
        #expect(towards.grudge?.reason == "you are being ridiculous")
        #expect(towards.grudge?.sinceSequence == 3)

        // And the target's own hostility rises, which is what invites retaliation.
        let back = conflict.relationship(from: "Agent 2", to: "Agent 1")
        #expect(back.competition > 0)
        // Trust is bipolar, so being attacked can take it below zero: that is active
        // distrust rather than merely the absence of goodwill.
        #expect(back.trust < 0)
    }

    @Test("A concession earns respect and drops the grudge")
    func concessionEarnsRespect() {
        var conflict = state()
        conflict.apply(
            signals: [TurnSignal(kind: .jab, confidence: 0.9, target: "Agent 2")],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 1, summary: "x")
        #expect(conflict.relationship(from: "Agent 1", to: "Agent 2").grudge != nil)

        conflict.apply(
            signals: [TurnSignal(kind: .concession, confidence: 0.9, target: "Agent 2")],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 4, summary: "y")
        let after = conflict.relationship(from: "Agent 1", to: "Agent 2")
        #expect(after.respect > 0)
        #expect(after.grudge == nil, "conceding should settle a grudge, not deepen it")
        #expect(after.annoyance < 0.3, "and take the heat out of it")
    }

    @Test("Agreement that is returned forms an alliance, and one gesture does not")
    func agreementFormsAlliance() {
        var conflict = state()
        let both = ["Agent 1", "Agent 2"]

        // One agreement is not an alliance. It warms both sides — the target is pleased to be
        // backed — but an alliance takes mutual goodwill, which is what makes it feel earned
        // rather than instantaneous.
        conflict.apply(
            signals: [TurnSignal(kind: .agreement, confidence: 0.8, target: "Agent 2")],
            from: "Agent 1", others: both, sequence: 1, summary: nil)
        conflict.apply(signals: [], from: "Agent 2", others: both, sequence: 2, summary: nil)
        #expect(
            conflict.relationship(from: "Agent 1", to: "Agent 2").alliance == nil,
            "one seat agreeing does not ally them")
        #expect(
            conflict.relationship(from: "Agent 1", to: "Agent 2").trust > 0,
            "but it should still warm the relationship")

        // Returned, it becomes one.
        conflict.apply(
            signals: [TurnSignal(kind: .agreement, confidence: 0.8, target: "Agent 1")],
            from: "Agent 2", others: both, sequence: 3, summary: nil)
        #expect(conflict.relationship(from: "Agent 1", to: "Agent 2").alliance != nil)
        #expect(
            conflict.relationship(from: "Agent 2", to: "Agent 1").alliance != nil,
            "an alliance is mutual by definition")
    }

    @Test("A jab ends an alliance")
    func jabEndsAllyance() {
        var conflict = state()
        let both = ["Agent 1", "Agent 2"]
        // Build the alliance first: agreeing, then agreeing back.
        conflict.apply(
            signals: [TurnSignal(kind: .agreement, confidence: 0.9, target: "Agent 2")],
            from: "Agent 1", others: both, sequence: 1, summary: nil)
        conflict.apply(
            signals: [TurnSignal(kind: .agreement, confidence: 0.9, target: "Agent 1")],
            from: "Agent 2", others: both, sequence: 2, summary: nil)
        #expect(conflict.relationship(from: "Agent 1", to: "Agent 2").alliance != nil)

        conflict.apply(
            signals: [TurnSignal(kind: .jab, confidence: 0.9, target: "Agent 2")],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 3, summary: "x")
        #expect(
            conflict.relationship(from: "Agent 1", to: "Agent 2").alliance == nil,
            "attacking someone you were allied with should end it")
    }

    @Test("Peacemaking lowers hostility and clears the grudge")
    func reconciliationWorks() {
        var conflict = state()
        conflict.apply(
            signals: [TurnSignal(kind: .jab, confidence: 1.0, target: "Agent 2")],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 1, summary: "x")
        let before = conflict.relationship(from: "Agent 1", to: "Agent 2").annoyance

        conflict.apply(
            signals: [TurnSignal(kind: .reconciliation, confidence: 0.8, target: "Agent 2")],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 2, summary: "sorry")
        let after = conflict.relationship(from: "Agent 1", to: "Agent 2")
        #expect(after.annoyance < before)
        #expect(after.grudge == nil)
    }

    @Test("A weak claim makes the others less willing to take that seat seriously")
    func weakClaimLowersRespect() {
        var conflict = state()
        conflict.apply(
            signals: [TurnSignal(kind: .unsupportedClaim, confidence: 0.6)],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 1, summary: nil)
        // Respect falls in the *others'* view of the speaker, which is the direction that
        // matters: they are the ones deciding whether to bother engaging.
        #expect(conflict.relationship(from: "Agent 2", to: "Agent 1").respect < 0)
    }

    @Test("Three seats are tracked pairwise, so an alliance can exclude someone")
    func threeSeatsArePairwise() {
        var conflict = state()
        let everyone = ["Agent 1", "Agent 2", "Agent 3"]
        conflict.apply(
            signals: [TurnSignal(kind: .agreement, confidence: 0.9, target: "Agent 2")],
            from: "Agent 1", others: everyone, sequence: 1, summary: nil)
        conflict.apply(
            signals: [TurnSignal(kind: .agreement, confidence: 0.9, target: "Agent 1")],
            from: "Agent 2", others: everyone, sequence: 2, summary: nil)

        // The alliance is between 1 and 2; the third seat is unaffected either way, which a
        // single per-seat score could not express.
        #expect(conflict.relationship(from: "Agent 2", to: "Agent 1").alliance != nil)
        #expect(conflict.relationship(from: "Agent 2", to: "Agent 3").alliance == nil)
        #expect(conflict.relationship(from: "Agent 3", to: "Agent 1").posture == "neutral")
    }

    @Test("State decays, so one early exchange does not define the whole conversation")
    func stateDecays() {
        var conflict = state()
        conflict.apply(
            signals: [TurnSignal(kind: .jab, confidence: 1.0, target: "Agent 2")],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 1, summary: "x")
        let fresh = conflict.relationship(from: "Agent 1", to: "Agent 2").annoyance

        // Twenty quiet turns later, without a grudge keeping it alive.
        for sequence in 2...22 {
            conflict.apply(
                signals: [], from: "Agent 2", others: ["Agent 1", "Agent 2"],
                sequence: sequence, summary: nil)
        }
        #expect(conflict.relationship(from: "Agent 1", to: "Agent 2").annoyance < fresh)
    }

    @Test("Nobody is called the leader while the room is level")
    func leadingSeatNeedsAPlurality() {
        var conflict = state()
        // No beats yet: a preferred target of "whoever is winning" must not pick at random.
        #expect(conflict.leadingSeat == nil)

        conflict.apply(
            signals: [TurnSignal(kind: .concession, confidence: 1.0, target: "Agent 2")],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 1, summary: nil)
        #expect(conflict.leadingSeat == "Agent 1")
    }

    @Test("The briefing is terse and only reports what has moved")
    func briefingIsTerse() {
        var conflict = state()
        let neutral = conflict.briefing(for: "Agent 1", others: ["Agent 1", "Agent 2"])
        #expect(neutral.isEmpty, "a fresh conversation has nothing to report")

        conflict.apply(
            signals: [TurnSignal(kind: .jab, confidence: 1.0, target: "Agent 2")],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 5, summary: "you are wrong about the shell")
        let briefing = conflict.briefing(for: "Agent 1", others: ["Agent 1", "Agent 2"])
        #expect(!briefing.isEmpty)
        #expect(briefing.relationships.contains { $0.contains("Agent 2") })
        // The reason is carried, not just a score: a character has to know what it is
        // aggrieved about or it reads as unreasonable.
        #expect(briefing.relationships.contains { $0.contains("you are wrong about the shell") })
    }

    @Test("The briefing carries no numbers")
    func briefingHasNoNumbers() {
        // "annoyance: 0.62" means nothing to a model and produces behaviour nobody asked for.
        var conflict = state()
        conflict.apply(
            signals: [TurnSignal(kind: .jab, confidence: 1.0, target: "Agent 2")],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 1, summary: "x")
        let briefing = conflict.briefing(for: "Agent 1", others: ["Agent 1", "Agent 2"])
        for line in briefing.relationships + briefing.recentBeats {
            #expect(!line.contains("0."), "a decimal leaked into the prompt: \(line)")
        }
    }

    @Test("Recent beats are bounded, because a conversation is endless")
    func beatsAreBounded() {
        var conflict = state()
        for sequence in 1...40 {
            conflict.apply(
                signals: [TurnSignal(kind: .challenge, confidence: 1.0, target: "Agent 2")],
                from: sequence % 2 == 0 ? "Agent 1" : "Agent 2",
                others: ["Agent 1", "Agent 2"], sequence: sequence, summary: nil)
        }
        #expect(conflict.recentBeats.count <= 12, "the prompt must not grow without bound")
    }

    @Test("The same conversation read twice produces the same state")
    func stateIsDeterministic() {
        // No randomness anywhere: a conversation that went a different way on each run would
        // be impossible to reason about when someone reports the characters went strange.
        func build() -> ConflictState {
            var conflict = ConflictState()
            conflict.apply(
                signals: [TurnSignal(kind: .jab, confidence: 0.9, target: "Agent 2")],
                from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 1, summary: "a")
            conflict.apply(
                signals: [TurnSignal(kind: .concession, confidence: 0.8, target: "Agent 1")],
                from: "Agent 2", others: ["Agent 1", "Agent 2"], sequence: 2, summary: "b")
            return conflict
        }
        #expect(build() == build())
    }

    @Test("State survives a save and reload, so a restarted app keeps the room")
    func stateIsCodable() throws {
        var conflict = state()
        conflict.apply(
            signals: [TurnSignal(kind: .jab, confidence: 1.0, target: "Agent 2")],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 3, summary: "x")
        let data = try JSONEncoder().encode(conflict)
        let restored = try JSONDecoder().decode(ConflictState.self, from: data)
        #expect(restored == conflict)
        #expect(restored.relationship(from: "Agent 1", to: "Agent 2").grudge?.reason == "x")
    }
}

@Suite("Social state in the prompt")
struct SocialPromptTests {

    private func prompt(mode: DiscussionMode, conflict: ConflictState) -> String {
        var spec = AgentSpec.seat(index: 0)
        spec.mode = mode
        spec.personaID = mode.defaultPersonaID(forSeat: 0)
        var conversation = Conversation(
            topic: "Egg shape",
            turns: [Turn(sequence: 1, speakerName: "Moderator", kind: .topic, content: "Egg shape")])
        conversation.conflict = conflict
        // The social state is a section of the prompt's one system message, not part of the
        // seat's instructions — a model mid-conversation should meet it as news. The chat
        // template refuses a second system message, so the whole prompt is joined here.
        return PromptBuilder.prompt(
            for: spec, others: [AgentSpec.seat(index: 1)], conversation: conversation
        ).map(\.content).joined(separator: "\n")
    }

    private func conflictWithAJab() -> ConflictState {
        var conflict = ConflictState()
        conflict.apply(
            signals: [TurnSignal(kind: .jab, confidence: 1.0, target: "Agent 2")],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 1,
            summary: "that is a ridiculous claim")
        return conflict
    }

    @Test("An entertainment seat is told how the room stands")
    func entertainmentGetsTheBriefing() {
        let text = prompt(mode: .entertainment, conflict: conflictWithAJab())
        #expect(text.contains("Where things stand"))
        #expect(text.contains("Agent 2"))
        #expect(text.contains("ridiculous claim"), "the grudge should name the remark")
    }

    @Test("A research seat is not, because the modes do not share a philosophy")
    func researchGetsNoBriefing() {
        // Importing grudges into an investigation is precisely what the brief rules out.
        let text = prompt(mode: .research, conflict: conflictWithAJab())
        #expect(!text.contains("Where things stand"))
        #expect(!text.contains("ridiculous claim"))
    }

    @Test("A neutral conversation adds no social section")
    func neutralAddsNothing() {
        let text = prompt(mode: .entertainment, conflict: ConflictState())
        #expect(!text.contains("Where things stand"))
    }
}
