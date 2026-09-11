// ChatBotsCoreTests — the persona library and how it reaches a prompt

import ChatBotsCore
import Testing

@Suite("PersonaLibrary")
struct PersonaLibraryTests {

    @Test("The library offers at least 25 selectable styles")
    func libraryIsLargeEnough() {
        // `neutral` is the absence of a style, so it does not count towards the set of
        // personas a moderator can actually choose between.
        let styled = PersonaLibrary.all.filter { $0.id != PersonaLibrary.neutral.id }
        #expect(styled.count >= 25, "found \(styled.count)")
    }

    @Test("Ids and names are unique, and every style is usable")
    func libraryIsWellFormed() {
        let ids = PersonaLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate persona id")

        let names = PersonaLibrary.all.map(\.name)
        #expect(Set(names).count == names.count, "duplicate persona name")

        for persona in PersonaLibrary.all {
            #expect(!persona.name.isEmpty)
            #expect(!persona.summary.isEmpty, "\(persona.id) has no summary for its menu row")
            if persona.id != PersonaLibrary.neutral.id {
                #expect(
                    !persona.directive.isEmpty,
                    "\(persona.id) is selectable but says nothing to the model")
                // Directives are applied to the system message; an over-long one competes
                // with the topic for a 4B model's attention.
                #expect(persona.directive.count < 700, "\(persona.id) directive is too long")
            }
        }
    }

    @Test("Every category has at least one style, so no menu section is empty")
    func categoriesArePopulated() {
        for category in Persona.Category.allCases {
            #expect(
                !PersonaLibrary.personas(in: category).isEmpty,
                "\(category.rawValue) has no personas")
        }
    }

    @Test("An unknown id resolves to neutral rather than failing")
    func unknownIdIsNeutral() {
        #expect(PersonaLibrary.persona(id: "does-not-exist").id == PersonaLibrary.neutral.id)
        #expect(PersonaLibrary.persona(id: "").id == PersonaLibrary.neutral.id)
        // A stored id from an older build must never be able to break a conversation.
        var spec = AgentSpec.seatA()
        spec.personaID = "retired-persona"
        #expect(spec.persona.id == PersonaLibrary.neutral.id)
    }

    @Test("Neutral imposes no directive")
    func neutralIsSilent() {
        #expect(PersonaLibrary.neutral.directive.isEmpty)
    }
}

@Suite("Persona in the prompt")
struct PersonaPromptTests {

    private func conversation() -> Conversation {
        Conversation(
            topic: "Why are eggs not round?",
            turns: [
                Turn(sequence: 1, speakerName: "Moderator", kind: .topic, content: "Why?"),
                Turn(sequence: 2, speakerName: "Agent 2", kind: .chat, content: "Because."),
            ]
        )
    }

    @Test("A seat's persona is stated in its own system message")
    func personaReachesTheSystemMessage() {
        var spec = AgentSpec.seatA()
        spec.personaID = "skeptic"
        let persona = PersonaLibrary.persona(id: "skeptic")

        let prompt = PromptBuilder.prompt(
            for: spec, others: [AgentSpec.seatB()], conversation: conversation())

        #expect(prompt.first?.role == .system)
        let system = prompt[0].content
        #expect(system.contains(persona.name))
        #expect(system.contains(persona.directive))
    }

    @Test("The other seat's persona never leaks into a prompt")
    func otherPersonaDoesNotLeak() {
        var specA = AgentSpec.seatA()
        specA.personaID = "skeptic"
        var specB = AgentSpec.seatB()
        specB.personaID = "storyteller"

        let promptForA = PromptBuilder.prompt(
            for: specA, others: [specB], conversation: conversation())

        #expect(promptForA[0].content.contains(PersonaLibrary.persona(id: "skeptic").directive))
        #expect(
            !promptForA[0].content.contains(PersonaLibrary.persona(id: "storyteller").directive),
            "seat B's style must not be applied to seat A")
    }

    @Test("The neutral persona adds nothing to the system message")
    func neutralAddsNothing() {
        var spec = AgentSpec.seatA()
        spec.personaID = PersonaLibrary.neutral.id

        let neutralPrompt = PromptBuilder.prompt(
            for: spec, others: [AgentSpec.seatB()], conversation: conversation())

        spec.personaID = "provocateur"
        let styledPrompt = PromptBuilder.prompt(
            for: spec, others: [AgentSpec.seatB()], conversation: conversation())

        #expect(neutralPrompt[0].content.count < styledPrompt[0].content.count)
        // The heading is mode-aware now — "character" for a show, "role" for an
        // investigation — so this asserts the directive arrived without pinning the wording.
        #expect(!neutralPrompt[0].content.contains("in this discussion —"))
        #expect(styledPrompt[0].content.contains("in this discussion —"))
    }

    @Test("A persona changes only the seat's instructions, never the shared log")
    func sharedLogIsUntouchedByPersona() {
        var spec = AgentSpec.seatA()
        spec.personaID = "historian"

        let prompt = PromptBuilder.prompt(
            for: spec, others: [AgentSpec.seatB()], conversation: conversation())

        // The log is the second (user) message; it must read the same for every seat.
        let log = prompt[1].content
        #expect(log.contains("[Moderator — topic]\nWhy?"))
        #expect(log.contains("[Agent 2]\nBecause."))
        #expect(!log.contains(PersonaLibrary.persona(id: "historian").directive))
    }

    @Test("The two default seats ship with contrasting styles")
    func defaultsContrast() {
        let a = AgentSpec.seatA()
        let b = AgentSpec.seatB()
        #expect(a.personaID != b.personaID)
        #expect(a.persona.id == AgentSpec.defaultPersonaA)
        #expect(b.persona.id == AgentSpec.defaultPersonaB)
        #expect(!a.persona.directive.isEmpty)
        #expect(!b.persona.directive.isEmpty)
    }
}
