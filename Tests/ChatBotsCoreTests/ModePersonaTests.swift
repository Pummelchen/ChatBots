// ChatBotsCoreTests — the two modes and their persona libraries
//
// The brief's central requirement is that the two modes must not share a persona
// philosophy. That is only real if the two libraries behave differently, so these tests
// assert the *differences*: that characters are distinguished by temperament, that analysts
// are distinguished by method, and that the same archetype can be varied by traits.

import ChatBotsCore
import Testing

@Suite("Entertainment cast")
struct EntertainmentCastTests {

    @Test("The entertainment cast is the requested size and covers every group")
    func castSizeAndCoverage() {
        #expect(SocialLibrary.all.count == 36)
        // Ten conflict characters, eight relationship, eight intellectual, five humour,
        // five ambition — the brief's breakdown.
        let byGroup = Dictionary(grouping: SocialLibrary.all, by: \.group)
        #expect(byGroup[.conflict]?.count == 10)
        #expect(byGroup[.relationships]?.count == 8)
        #expect(byGroup[.intellectual]?.count == 8)
        #expect(byGroup[.humor]?.count == 5)
        #expect(byGroup[.ambition]?.count == 5)
    }

    @Test("Identifiers are unique, so a stored seat always resolves to the same character")
    func identifiersAreUnique() {
        let ids = SocialLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        let analystIDs = AnalystLibrary.all.map(\.id)
        #expect(Set(analystIDs).count == analystIDs.count)
    }

    @Test("The analyst library is the requested size and covers every group")
    func analystCoverage() {
        #expect(AnalystLibrary.all.count == 19)
        let byGroup = Dictionary(grouping: AnalystLibrary.all, by: \.group)
        #expect(byGroup[.evidence]?.count == 6)
        #expect(byGroup[.business]?.count == 6)
        #expect(byGroup[.domain]?.count == 4)
        #expect(byGroup[.human]?.count == 3)
    }

    @Test("Every character and analyst produces a usable directive")
    func directivesAreSubstantial() {
        for character in SocialLibrary.all {
            let directive = character.directive
            #expect(directive.contains(character.name))
            #expect(directive.count > 200, "\(character.id) has a thin directive")
            #expect(!directive.contains("nil"))
        }
        for role in AnalystLibrary.all {
            let directive = role.directive
            #expect(directive.contains(role.name))
            #expect(directive.count > 300, "\(role.id) has a thin directive")
            #expect(!directive.contains("nil"))
        }
    }
}

@Suite("Characters differ by temperament")
struct CharacterTemperamentTests {

    /// Look a character up, failing loudly rather than silently falling back, so a typo in a
    /// test cannot pass by comparing the default against itself.
    private func character(_ id: String) -> SocialCharacter {
        guard let match = SocialLibrary.all.first(where: { $0.id == id }) else {
            Issue.record("no character with id \(id)")
            return SocialLibrary.character(id: id)
        }
        return match
    }

    @Test("The aggressive characters are more aggressive than the conciliatory ones")
    func aggressionOrdering() {
        #expect(character("villain").aggression > character("peacemaker").aggression)
        #expect(character("hothead").aggression > character("romantic").aggression)
        #expect(character("villain").aggression > character("social-pragmatist").aggression)
    }

    @Test("The dominant characters are more dominant than the retiring ones")
    func dominanceOrdering() {
        #expect(character("alpha").dominance > character("peacemaker").dominance)
        #expect(character("overachiever").dominance > character("deadpan").dominance)
        #expect(character("alpha").dominance == .veryHigh)
    }

    @Test("The characters built to escalate concede less readily than the ones built to soothe")
    func concessionOrdering() {
        #expect(character("alpha").concessionThreshold > character("peacemaker").concessionThreshold)
        #expect(character("villain").concessionThreshold > character("romantic").concessionThreshold)
        #expect(character("peacemaker").concessionThreshold == .veryLow)
    }

    @Test("Only the characters meant to needle have sharp jabs")
    func insultOrdering() {
        #expect(character("villain").insultIntensity > character("storyteller").insultIntensity)
        #expect(character("troll").insultIntensity > character("social-scientist").insultIntensity)
        #expect(character("peacemaker").insultIntensity == .veryLow)
        // Nobody is set to maximum crudeness: the brief asks for clever over crude.
        #expect(SocialLibrary.all.allSatisfy { $0.insultIntensity <= .high })
    }

    @Test("The snarky characters are snarkier than the earnest ones")
    func sarcasmOrdering() {
        #expect(character("deadpan").sarcasm > character("romantic").sarcasm)
        #expect(character("troll").sarcasm > character("storyteller").sarcasm)
        #expect(character("fake-nice").sarcasm >= .high)
    }

    @Test("The comedian is the funniest character and the hothead is not")
    func humorOrdering() {
        #expect(character("comedian").humor >= character("hothead").humor)
        #expect(character("comedian").humor == .veryHigh)
    }

    @Test("Characters that hold grudges are distinguishable from those that do not")
    func grudgeOrdering() {
        #expect(character("grudge").memoryOfSlights == .veryHigh)
        #expect(character("peacemaker").memoryOfSlights == .veryLow)
        #expect(character("grudge").memoryOfSlights > character("comedian").memoryOfSlights)
    }

    @Test("Traits actually change the directive, so two builds of one archetype differ")
    func traitsDriveTheDirective() {
        // The combinatorial claim from the brief: Alpha plus different modifiers is a
        // different character without a second hand-written prompt.
        let base = character("alpha")
        let intellectual = base.adjusted(ego: .veryHigh, sarcasm: .veryHigh, skepticism: .high)
        let flirtatious = base.adjusted(aggression: .low, humor: .high, empathy: .high)

        #expect(base.directive != intellectual.directive)
        #expect(base.directive != flirtatious.directive)
        #expect(intellectual.directive != flirtatious.directive)
        // The archetype is still recognisable in both.
        #expect(intellectual.name == base.name)
        #expect(flirtatious.id == base.id)
    }

    @Test("A varied archetype reads differently where it matters")
    func adjustmentIsVisibleInTheText() {
        let base = character("alpha")
        let soft = base.adjusted(aggression: .veryLow, concessionThreshold: .low)
        // The generated prose should reflect the lowered aggression and eagerness to yield,
        // rather than merely storing different numbers.
        #expect(!soft.directive.contains("you go on the attack quickly"))
        #expect(soft.directive != base.directive)
    }
}

@Suite("Analysts differ by method, not by temperament")
struct AnalystMethodTests {

    @Test("Every analyst states a method and an evidence standard")
    func analystsAreMethodological() {
        for role in AnalystLibrary.all {
            #expect(!role.method.isEmpty, "\(role.id) has no method")
            #expect(!role.evidenceStandard.isEmpty, "\(role.id) has no evidence standard")
            #expect(!role.failureMode.isEmpty, "\(role.id) does not name its own weakness")
            #expect(!role.preferredData.isEmpty)
            #expect(!role.decisionCriteria.isEmpty)
        }
    }

    @Test("The evidence standards are genuinely different, not restatements")
    func evidenceStandardsDiffer() {
        let standards = AnalystLibrary.all.map(\.evidenceStandard)
        #expect(Set(standards).count == standards.count, "two analysts share a standard verbatim")
    }

    @Test("The methodological analysts are more skeptical than the advocate roles")
    func skepticismOrdering() {
        let byID = Dictionary(uniqueKeysWithValues: AnalystLibrary.all.map { ($0.id, $0) })
        let skeptic = byID["skeptic"]!
        let methodologist = byID["methodologist"]!
        let dataAnalyst = byID["data-analyst"]!

        #expect(skeptic.skepticism > dataAnalyst.skepticism)
        #expect(methodologist.skepticism >= .high)
        #expect(skeptic.skepticism == .veryHigh)
    }

    @Test("The moderator is told not to hold a position, unlike the analysts")
    func moderatorIsNeutral() {
        let moderator = AnalystLibrary.role(id: "research-moderator")
        #expect(moderator.directive.contains("Does not hold a position") || moderator.summary.contains("Does not hold a position"))
        #expect(moderator.domain.contains("synthesis"))
    }

    @Test("Analyst directives require labelled claims, which is what makes a report usable")
    func analystsAreToldToLabelClaims() {
        for role in AnalystLibrary.all {
            #expect(
                role.directive.contains("Label your claims"),
                "\(role.id) is not told to distinguish fact from inference")
        }
    }
}

@Suite("Mode resolution")
struct DiscussionModeTests {

    @Test("Entertainment is endless and research is not")
    func endConditions() {
        #expect(DiscussionMode.entertainment.runsUntilStopped)
        #expect(!DiscussionMode.research.runsUntilStopped)
    }

    @Test("Each mode offers its own library plus the shared styles")
    func catalogContents() {
        let entertainment = PersonaCatalog.styles(for: .entertainment)
        let research = PersonaCatalog.styles(for: .research)

        #expect(entertainment.contains { $0.id == "villain" })
        #expect(!research.contains { $0.id == "villain" }, "a character is not an analyst")
        #expect(research.contains { $0.id == "statistician" })
        #expect(!entertainment.contains { $0.id == "statistician" })

        // The shared styles are available in both, including the "no style" one every mode
        // needs, so an old configuration still resolves.
        for mode in DiscussionMode.allCases {
            let styles = PersonaCatalog.styles(for: mode)
            #expect(styles.contains { $0.id == PersonaLibrary.neutral.id })
            #expect(styles.contains { $0.id == "fact-checker" })
        }
    }

    @Test("An identifier from the other library resolves to that mode's default, not to nothing")
    func crossModeIdentifierFallsBack() {
        // What happens the moment the mode is switched: the stored id no longer belongs.
        let style = PersonaCatalog.style(id: "villain", mode: .research, seatIndex: 1)
        #expect(style.id != "villain")
        #expect(!style.directive.isEmpty, "a seat must never be left with no directive")
        #expect(style.isAnalyst)
    }

    @Test("Defaults are distinct, so a fresh session is not several identical seats")
    func defaultsAreDistinct() {
        for mode in DiscussionMode.allCases {
            let ids = (0..<4).map { mode.defaultPersonaID(forSeat: $0) }
            #expect(Set(ids).count == ids.count, "\(mode) repeats a persona in its first four seats")
        }
    }

    @Test("Research defaults start with the moderator and include a challenger")
    func researchDefaults() {
        #expect(DiscussionMode.research.defaultPersonaID(forSeat: 0) == "research-moderator")
        let firstFour = (0..<4).map { DiscussionMode.research.defaultPersonaID(forSeat: $0) }
        let challengers = Set(AnalystLibrary.challengers.map(\.id))
        #expect(firstFour.contains { challengers.contains($0) }, "no challenger in the default line-up")
    }
}

@Suite("Mode changes the instructions, not just the persona")
struct ModePromptTests {

    private func prompt(mode: DiscussionMode) -> String {
        var spec = AgentSpec.seat(index: 0)
        spec.mode = mode
        spec.personaID = mode.defaultPersonaID(forSeat: 0)
        let conversation = Conversation(
            topic: "Should Company X enter the German EV market?",
            turns: [Turn(sequence: 1, speakerName: "Moderator", kind: .topic, content: "Should Company X enter the German EV market?")])
        return PromptBuilder.prompt(
            for: spec, others: [AgentSpec.seat(index: 1)], conversation: conversation
        )[0].content
    }

    @Test("The entertainment rules ask for conflict and refuse to wrap up")
    func entertainmentRules() {
        let text = prompt(mode: .entertainment)
        #expect(text.contains("This is a show"))
        #expect(text.contains("Disagree hard"))
        #expect(text.contains("do not hunt for common ground"))
        #expect(!text.contains("Label what you produce"))
    }

    @Test("The research rules ask for method, labelling and revision")
    func researchRules() {
        let text = prompt(mode: .research)
        #expect(text.contains("This is an investigation"))
        #expect(text.contains("Work by your method"))
        #expect(text.contains("Label what you produce"))
        #expect(text.contains("revise your own conclusion"))
        #expect(!text.contains("Disagree hard"))
    }

    @Test("The two modes do not share their rules")
    func modesAreDistinct() {
        let entertainment = prompt(mode: .entertainment)
        let research = prompt(mode: .research)
        #expect(entertainment != research)
        // The persona also differs, so the whole instruction set should be different.
        #expect(entertainment.contains("Your character in this discussion"))
        #expect(research.contains("Your role in this investigation"))
    }

    @Test("Entertainment is not told to cite, and research is")
    func citationExpectationDiffers() {
        // The brief is explicit that research needs provenance and entertainment does not.
        #expect(prompt(mode: .research).contains("prefer primary sources"))
        #expect(!prompt(mode: .entertainment).contains("prefer primary sources"))
    }
}

@Suite("Switching the room's mode")
struct ModeSwitchTests {

    @MainActor
    private func engine(mode: DiscussionMode = .entertainment) -> ConversationEngine {
        let specs = AgentSpec.makeSeats(count: 3).map { seat -> AgentSpec in
            var copy = seat
            copy.mode = mode
            copy.personaID = mode.defaultPersonaID(forSeat: 0)
            return copy
        }
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        return ConversationEngine(
            seats: specs.map { .init(spec: $0, engine: StubSeat(spec: $0)) },
            configuration: configuration)
    }

    @Test("Switching to research reseats every persona, because the libraries differ")
    @MainActor
    func switchReseats() {
        let engine = engine()
        // All three seats start on the same entertainment character, which is invalid in
        // research: a seat holding "The Villain" has no meaning there.
        #expect(engine.specs.allSatisfy { PersonaCatalog.style(id: $0.personaID, mode: .entertainment, seatIndex: 0).isAnalyst == false })

        #expect(engine.setMode(.research))
        #expect(engine.specs.allSatisfy { $0.mode == .research })
        for (index, spec) in engine.specs.enumerated() {
            let style = PersonaCatalog.style(id: spec.personaID, mode: .research, seatIndex: index)
            #expect(style.isAnalyst, "seat \(index) kept a character from the other library")
        }
    }

    @Test("A research mode brings a session, and leaving it drops the budget")
    @MainActor
    func modeManagesTheSession() {
        let engine = engine()
        #expect(engine.researchSession == nil, "entertainment has no end condition on purpose")

        #expect(engine.setMode(.research))
        #expect(engine.researchSession != nil, "an investigation needs a budget")

        #expect(engine.setMode(.entertainment))
        #expect(engine.researchSession == nil, "no budget should count against a show")
    }

    @Test("The mode is fixed once the conversation has started")
    @MainActor
    func modeIsLockedWhileRunning() async {
        let engine = engine()
        engine.start(topic: "Why are eggs not round?")
        // The log was written against the personas the conversation began with.
        #expect(!engine.setMode(.research))
        await engine.waitUntilFinished()
    }

    @Test("Personas that suit either mode are kept when the mode changes")
    @MainActor
    func sharedPersonasSurvive() {
        let engine = engine()
        // `neutral` means "no style", which every mode needs, so a seat using it should not be
        // reseated just because the room changed.
        engine.updateSeat({
            var spec = engine.specs[0]
            spec.personaID = PersonaLibrary.neutral.id
            return spec
        }())
        #expect(engine.setMode(.research))
        #expect(engine.specs[0].personaID == PersonaLibrary.neutral.id)
    }
}

/// A seat that never produces anything; these tests are about configuration, not turns.
private actor StubSeat: LLMEngine {
    nonisolated let spec: AgentSpec
    init(spec: AgentSpec) { self.spec = spec }
    var isLoaded: Bool { true }
    var contextWindow: Int { spec.contextWindow }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}
    func generate(
        messages: [PromptMessage], tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String { "" }
}
