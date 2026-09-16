// ChatBotsCoreTests — the opening brief describes the moderator the room actually has
//
// `moderatorParagraph` hardcoded `briefing(mode: .entertainment)` while the same brief is used
// for both room modes. Research runs offer the analyst personas, which are not in the
// entertainment library, so `PersonaCatalog.style` silently fell back to `SocialLibrary.featured[0]`
// — "The Alpha" — and the opening brief every analyst reads described the human moderator as a
// reality-show character. The mode now comes from the seats, and a persona that is not in the
// room's library is no persona rather than a substitute.

import ChatBotsCore
import Testing

@Suite("The moderator's brief uses the room's own mode")
struct ResearchModeratorBriefTests {

    private func researchSeats() -> [AgentSpec] {
        var spec = AgentSpec.seat(index: 0)
        spec.mode = .research
        spec.personaID = "economist"
        return [spec]
    }

    private func entertainmentSeats() -> [AgentSpec] {
        var spec = AgentSpec.seat(index: 0)
        spec.mode = .entertainment
        spec.personaID = "alpha"
        return [spec]
    }

    @Test("A research run does not describe the moderator as a reality-show character")
    func researchRunDoesNotUseTheAlpha() {
        let brief = PromptBuilder.introduction(
            specs: researchSeats(), topic: "A question",
            moderator: ModeratorIdentity(name: "Dana", personaID: "alpha"))

        #expect(!brief.contains("The Alpha"), "the entertainment default leaked into a research brief")
        // The name is still introduced, because the human is still the human.
        #expect(brief.contains("Dana"))
    }

    @Test("A research persona is found in the research library")
    func researchPersonaResolves() {
        let brief = PromptBuilder.introduction(
            specs: researchSeats(), topic: "A question",
            moderator: ModeratorIdentity(name: "Dana", personaID: "economist"))

        #expect(brief.contains("Economist"))
        #expect(brief.contains("incentives"), "the analyst's method, not a character sheet")
    }

    @Test("An entertainment run still resolves an entertainment persona")
    func entertainmentPersonaStillResolves() {
        let brief = PromptBuilder.introduction(
            specs: entertainmentSeats(), topic: "A question",
            moderator: ModeratorIdentity(name: "Dana", personaID: "alpha"))

        #expect(brief.contains("The Alpha"))
    }

    @Test("An entertainment persona is not substituted into a research briefing")
    func crossModePersonaIsNotSubstituted() {
        // The defect in one call: the research library is asked for an entertainment identifier,
        // and the honest answer is "no persona", not "The Alpha".
        let identity = ModeratorIdentity(personaID: "alpha")
        #expect(identity.briefing(mode: .research) == nil)

        // With a name there is something to say, and it says nothing about a character.
        let named = ModeratorIdentity(name: "Dana", personaID: "alpha")
        let briefing = named.briefing(mode: .research)
        #expect(briefing?.contains("Dana") == true)
        #expect(briefing?.contains("The Alpha") == false)
        #expect(briefing?.contains("approach the work as") == false)
    }
}
