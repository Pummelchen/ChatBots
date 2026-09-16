// ChatBotsCoreTests — who the human moderator is
//
// Two behaviours matter and they pull in opposite directions. The room should be told who is
// asking — "the person commissioning this work" is weaker than knowing how they argue — and a
// moderator who has chosen nothing should cost the prompt nothing at all. A briefing that says
// "the moderator has no character" is tokens spent to say there is nothing to say.

import ChatBotsCore
import Foundation
import Testing

@Suite("The human moderator's identity")
struct ModeratorIdentityTests {

    @Test("An unconfigured moderator says nothing to the room")
    func defaultsAreSilent() {
        let identity = ModeratorIdentity()
        #expect(identity.isDefault)
        #expect(identity.briefing(mode: .entertainment) == nil)
        #expect(identity.briefing(mode: .research) == nil)
        // And the tag the transcript has always used is still the tag.
        #expect(identity.speakerName == "Moderator")
    }

    @Test("A name alone is enough to be introduced")
    func aNameIsEnough() throws {
        let identity = ModeratorIdentity(name: "Dana")
        let briefing = try #require(identity.briefing(mode: .research))
        #expect(briefing.contains("Dana"))
        #expect(briefing.contains("override"))
        #expect(!identity.isDefault)
    }

    @Test("A persona describes how the moderator's interjections read")
    func aPersonaIsDescribed() throws {
        // A research persona, because the mode's library is what resolves the identifier.
        let identity = ModeratorIdentity(name: "Dana", personaID: "skeptic")
        let briefing = try #require(identity.briefing(mode: .research))
        #expect(briefing.contains("Skeptic"))
        // The directive is what makes it worth saying: without it the name is a label.
        #expect(briefing.count > 60)
    }

    @Test("A name that is only whitespace is treated as no name")
    func blankNamesFallBack() {
        let identity = ModeratorIdentity(name: "   ")
        #expect(identity.speakerName == "Moderator")
        #expect(identity.briefing(mode: .research) == nil)
    }

    @Test("A very long name is trimmed rather than pasted into the log")
    func longNamesAreTrimmed() {
        // The speaker tag goes into every prompt and every line of the transcript, so an
        // unbounded name is an unbounded cost per turn.
        let identity = ModeratorIdentity(name: String(repeating: "a", count: 200))
        #expect(identity.speakerName.count == 40)
    }

    @Test("The prompt names the moderator, and only when there is something to say")
    func promptsCarryIt() {
        var spec = AgentSpec.makeSeats(count: 1)[0]
        spec.mode = .research
        spec.personaID = "economist"

        // Checked through the brief, which is part of the log and therefore part of the prompt.
        let specs = [spec]
        let plain = PromptBuilder.introduction(specs: specs, topic: "A question")
        #expect(!plain.contains("Dana"))
        #expect(plain.contains("Messages marked [Moderator]"))

        let named = PromptBuilder.introduction(
            specs: specs, topic: "A question",
            moderator: ModeratorIdentity(name: "Dana", personaID: "skeptic"))
        #expect(named.contains("Messages marked [Dana]"))
        // The persona resolves in the room's own library — the analysts — not the entertainment
        // one, so the name the brief uses is the analyst's.
        #expect(named.contains("Skeptic"))
        #expect(named.contains("disconfirmation"), "the analyst's method is what makes it worth saying")
    }

    @Test("The opening brief introduces the moderator")
    func theBriefCarriesIt() {
        let specs = AgentSpec.makeSeats(count: 2)
        let brief = PromptBuilder.introduction(
            specs: specs, topic: "A question", moderator: ModeratorIdentity(name: "Dana"))
        #expect(brief.contains("Dana"))
        // The brief is what a seat reads first, so it must not claim the moderator is anonymous
        // once they are not.
        let anonymous = PromptBuilder.introduction(specs: specs, topic: "A question")
        #expect(!anonymous.contains("Dana"))
    }

    @Test("Settings keep the moderator across a restart, and tolerate an older payload")
    func settingsRoundTrip() throws {
        var settings = UserSettings.defaults(topic: "A question")
        settings.moderator = ModeratorIdentity(name: "Dana", personaID: "skeptic")
        let data = try JSONEncoder().encode(settings)
        let restored = try UserSettings.decoded(from: data)
        #expect(restored.moderator.name == "Dana")
        #expect(restored.moderator.personaID == "skeptic")

        // A payload written before the field existed must still decode: a failure here would
        // cost the user every setting they have.
        let legacy = Data(
            #"{"version":1,"topic":"t","moderatorDraft":"","showReasoning":true,"seatCount":0,"seats":[]}"#
                .utf8)
        let old = try UserSettings.decoded(from: legacy)
        #expect(old.moderator.isDefault)
    }

    @Test("The room is told who is asking, through the engine's own turn")
    @MainActor
    func theEngineUsesIt() async throws {
        let specs = AgentSpec.makeSeats(count: 2)
        let stubs = specs.map { ModeratorPromptStub(spec: $0) }
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        configuration.maxTurns = 1
        let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
        let engine = ConversationEngine(seats: seats, configuration: configuration)
        engine.setTopic("A question")
        engine.moderator = ModeratorIdentity(name: "Dana")
        engine.start()
        await engine.waitUntilFinished()

        // The name reaches the prompt, and it tags the human's own turn in the log — which is
        // what a transcript is read by.
        var prompts: [String] = []
        for stub in stubs { prompts.append(contentsOf: await stub.prompts) }
        #expect(prompts.contains { $0.contains("Messages marked [Dana]") })

        engine.steer("Look at the downside first.")
        #expect(engine.conversation.turns.contains { $0.speakerName == "Dana" })
        #expect(!engine.conversation.turns.contains { $0.speakerName == "Moderator" })
    }

    @Test("A moderator can be renamed while a conversation is running")
    @MainActor
    func changeableWhileRunning() async {
        // Unlike the topic: who is speaking is not a property of the question, and a moderator
        // halfway through an investigation under the wrong name should be able to fix it.
        let specs = AgentSpec.makeSeats(count: 2)
        let stubs = specs.map { ModeratorPromptStub(spec: $0) }
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
        let engine = ConversationEngine(seats: seats, configuration: configuration)
        engine.setTopic("A question")
        let store = ConversationStore(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "mod-\(UUID().uuidString)"))
        let service = EngineService(engine: engine, store: store)

        engine.start()
        let reply = await service.handle(
            .setModerator(ModeratorIdentity(name: "Dana", personaID: "skeptic")))
        #expect(reply.snapshot?.moderatorName == "Dana")
        #expect(reply.snapshot?.moderatorPersona.contains("Skeptic") == true)
        await engine.waitUntilFinished()
    }
}

/// A seat that answers without a model, keeping the prompts it was given.
private actor ModeratorPromptStub: LLMEngine {
    nonisolated let spec: AgentSpec
    private(set) var prompts: [String] = []
    init(spec: AgentSpec) { self.spec = spec }

    var isLoaded: Bool { true }
    var contextWindow: Int { spec.contextWindow }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}
    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        prompts.append(messages.map(\.content).joined(separator: "\n"))
        let text = "According to the filings, a consideration."
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 10, stopReason: "stop")))
        return text
    }
}
