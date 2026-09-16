// ChatBotsCoreTests — the one dispatch both transports share
//
// These test the engine's request handling with no socket, no framing and no HTTP. That is
// the point of extracting it: a dispatch bug used to look like a transport bug, and could
// only be reproduced by starting a server.

import ChatBotsCore
import Foundation
import Testing

/// An engine that does nothing, so these tests are about dispatch rather than generation.
private actor QuietStub: LLMEngine {
    nonisolated let spec: AgentSpec
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
        "a reply"
    }
}

@MainActor
private func makeService(personas: [String] = []) -> (EngineService, ConversationEngine) {
    let specs = (0..<2).map { index -> AgentSpec in
        var spec = AgentSpec.seat(index: index)
        // A known name and persona, so the tests can assert on what a command changed.
        spec.displayName = "Seat \(index + 1)"
        if index < personas.count { spec.personaID = personas[index] }
        return spec
    }
    let stubs = specs.map { QuietStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    // A store per engine, in a directory of its own, so tests cannot see each other's
    // conversations.
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "service-\(UUID().uuidString)"))
    // A topic, because a conversation cannot start without one — and these tests are about
    // what a locked conversation does, so they have to reach a running state first. The
    // first version of this fixture left it blank, so `start` was refused, the conversation
    // never ran, and the "refused because it is locked" assertions passed for the wrong
    // reason: the localisation check happened to match the "please enter a topic" message.
    engine.setTopic("A test topic")
    return (EngineService(engine: engine, store: store), engine)
}

@MainActor
@Suite("Engine service")
struct EngineServiceTests {

    // MARK: Reads

    @Test("fetchState returns the current state")
    func fetchState() async {
        let (service, _) = makeService()
        let reply = await service.handle(.fetchState)
        guard let snapshot = reply.snapshot else {
            Issue.record("expected a state reply")
            return
        }
        #expect(snapshot.seats.count == 2)
        #expect(snapshot.seats.map(\.name) == ["Seat 1", "Seat 2"])
    }

    @Test("A snapshot carries the personas the picker needs")
    func snapshotCarriesPersonas() async {
        // The picker is populated from the snapshot, so a mode with no personas would give an
        // empty list rather than an error.
        let (service, _) = makeService()
        let snapshot = await service.handle(.fetchState).snapshot
        #expect((snapshot?.availablePersonas.count ?? 0) > 10)
        #expect(snapshot?.availablePersonas.contains { $0.isAnalyst } == false)
    }

    @Test("fetchReport refuses politely before a session has run")
    func reportBeforeAnySession() async {
        let (service, _) = makeService()
        let reply = await service.handle(.fetchReport)
        guard case .refused(let reason) = reply else {
            Issue.record("expected a refusal, not \(reply)")
            return
        }
        #expect(reason.contains("no report"))
    }

    // MARK: Topic

    @Test("A topic can be set before the conversation starts")
    func setTopic() async {
        let (service, _) = makeService()
        let reply = await service.handle(.setTopic("Is a hot dog a sandwich?"))
        #expect(reply.snapshot?.topic == "Is a hot dog a sandwich?")
    }

    @Test("A topic is refused once the conversation has started, as a refusal not an error")
    func topicLocked() async {
        let (service, _) = makeService()
        _ = await service.handle(.start)
        let reply = await service.handle(.setTopic("changed"))
        guard case .refused(let reason) = reply else {
            Issue.record("expected a refusal, not \(reply)")
            return
        }
        // The message is read by a user, so it has to explain itself.
        #expect(reason.contains("cannot be changed"))
        #expect(reply.snapshot == nil)
    }

    @Test("An empty topic is refused rather than blanking the question")
    func emptyTopic() async {
        // An empty steer was refused but an empty topic was not, which would let the question
        // be blanked after it had been set. Now both are refused.
        let (service, engine) = makeService()
        _ = await service.handle(.setTopic("Something real"))
        let reply = await service.handle(.setTopic("   "))
        guard case .refused(let reason) = reply else {
            Issue.record("expected a refusal, not \(reply)")
            return
        }
        #expect(reason.contains("topic is required"))
        #expect(engine.topic == "Something real", "the question should be untouched")
    }

    // MARK: Seats

    @Test("A seat change alters only the fields it names")
    func partialSeatChange() async {
        // The reason a seat change is a partial value: renaming a seat must not reset the
        // persona it was given.
        let (service, engine) = makeService(personas: ["skeptic", "scientist"])
        let before = engine.specs[0].personaID

        let reply = await service.handle(.updateSeat(.init(seatID: "Agent 1", name: "Mira")))
        guard let snapshot = reply.snapshot else {
            Issue.record("expected a state reply")
            return
        }
        #expect(snapshot.seats[0].name == "Mira")
        #expect(engine.specs[0].personaID == before, "the persona should be untouched")
    }

    @Test("Every field of a seat change is applied")
    func fullSeatChange() async {
        let (service, engine) = makeService()
        _ = await service.handle(
            .updateSeat(
                .init(
                    seatID: "Agent 2", name: "Otto", personaID: "troll",
                    thinking: .high, backend: .openAIResponses,
                    baseURL: "https://api.deepseek.com/v1", apiModel: "deepseek-v4-flash")))

        let spec = engine.specs[1]
        #expect(spec.displayName == "Otto")
        #expect(spec.personaID == "troll")
        #expect(spec.thinking == .high)
        #expect(spec.backend == .openAIResponses)
        #expect(spec.openAI.baseURL == "https://api.deepseek.com/v1")
        #expect(spec.openAI.model == "deepseek-v4-flash")
    }

    @Test("An unknown seat is refused rather than silently ignored")
    func unknownSeat() async {
        let (service, _) = makeService()
        let reply = await service.handle(.updateSeat(.init(seatID: "Agent 9", name: "Nobody")))
        guard case .refused(let reason) = reply else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("Agent 9"))
    }

    @Test("A blank name is refused rather than leaving a seat unnamed")
    func blankName() async {
        let (service, engine) = makeService()
        _ = await service.handle(.updateSeat(.init(seatID: "Agent 1", name: "   ")))
        #expect(engine.specs[0].displayName == "Seat 1")
    }

    // MARK: Mode and budget

    @Test("The mode switches and reseats the personas")
    func modeSwitch() async {
        let (service, engine) = makeService()
        let reply = await service.handle(.setMode(.research))
        #expect(reply.snapshot?.mode == "research")
        // The libraries are not interchangeable, so the seats must have been reseated.
        #expect(engine.specs.allSatisfy { $0.mode == .research })
    }

    @Test("The mode is refused once the conversation has started")
    func modeLocked() async {
        let (service, _) = makeService()
        _ = await service.handle(.start)
        let reply = await service.handle(.setMode(.research))
        guard case .refused(let reason) = reply else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("cannot be changed"))
    }

    @Test("The research budget is set from the service")
    func researchBudget() async {
        let (service, _) = makeService()
        _ = await service.handle(.setMode(.research))
        _ = await service.handle(.setResearchBudget(.deep))
        // The budget surfaces through the snapshot, which is what a front end reads.
        let status = await service.handle(.fetchState).snapshot?.research
        #expect(status?.depth.lowercased().contains("deep") == true)
    }

    // MARK: Steering, settings, attachments

    @Test("Steering with empty text is refused")
    func emptySteer() async {
        let (service, _) = makeService()
        let reply = await service.handle(.steer("   \n  "))
        guard case .refused(let reason) = reply else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("message is required"))
    }

    @Test("Steering with text is accepted and reaches the engine")
    func steer() async {
        let (service, engine) = makeService()
        let reply = await service.handle(.steer("Stay on the shell question."))
        #expect(reply.snapshot != nil)
        // An idle engine takes the message straight into the log, because that is the log the
        // seats are about to be given; it is *not* also queued, which is what delivered it to
        // the prompt twice. The queue is for a message typed while a turn is being generated,
        // and the mid-turn test covers that.
        #expect(engine.conversation.turns.contains { $0.content.contains("shell question") })
        #expect(!engine.queuedSteering.contains { $0.content.contains("shell question") })
    }

    @Test("The reasoning preference is held by the service")
    func showReasoning() async {
        let (service, _) = makeService()
        _ = await service.handle(.setShowReasoning(false))
        #expect(service.showReasoning == false)
        _ = await service.handle(.setShowReasoning(true))
        #expect(service.showReasoning)
    }

    @Test("Attachments can be cleared")
    func clearAttachments() async {
        let (service, engine) = makeService()
        _ = await service.handle(.clearAttachments)
        #expect(engine.attachments.isEmpty)
    }

    @Test("An attachment with a name that is not a document is refused, not crashed on")
    func badAttachment() async {
        // The upload path writes a file and reads it back, so a hostile or silly filename is
        // worth testing rather than assuming.
        let (service, _) = makeService()
        let reply = await service.handle(
            .addAttachment(filename: "not-a-document.xyzzy", contents: Data("hello".utf8)))
        guard case .refused = reply else {
            Issue.record("expected a refusal, not \(reply)")
            return
        }
    }

    @Test("A removable attachment can be removed by id, and an unknown id is harmless")
    func removeAttachment() async {
        let (service, engine) = makeService()
        _ = await service.handle(.removeAttachment(id: "not-a-real-id"))
        #expect(engine.attachments.isEmpty)
    }

    // MARK: Transport controls

    @Test("Start, pause, resume and stop are all accepted and change the status")
    func transport() async {
        let (service, engine) = makeService()
        _ = await service.handle(.start)
        #expect(engine.status != .idle)
        _ = await service.handle(.pause)
        #expect(engine.isPaused)
        _ = await service.handle(.resume)
        #expect(!engine.isPaused)
        _ = await service.handle(.stop)
        #expect(!engine.isRunning)
    }

    @Test("Reset returns the engine to a fresh conversation")
    func reset() async {
        let (service, engine) = makeService()
        _ = await service.handle(.setTopic("First topic"))
        _ = await service.handle(.reset)
        #expect(engine.displayTurns.count <= 1)
    }
}

// MARK: - Fields the user supplies are bounded

@MainActor
@Suite("User-supplied text is bounded")
struct EngineServiceFieldLimitTests {

    /// A body of text far past the limit, which is what an accidental paste produces.
    private var overlong: String {
        String(repeating: "a question about eggs ", count: 200)
    }

    @Test("A topic past the limit is refused, and the room keeps the topic it had")
    func topicIsBounded() async {
        let (service, engine) = makeService()
        let before = engine.topic

        let reply = await service.handle(.setTopic(overlong))
        guard let reason = reply.refusal else {
            Issue.record("expected a refusal, got \(reply)")
            return
        }
        #expect(reason.contains("2000"))
        #expect(engine.topic == before, "a refused topic must not have been applied")
    }

    @Test("A topic within the limit is still accepted")
    func topicWithinTheLimitWorks() async {
        let (service, engine) = makeService()
        let reply = await service.handle(.setTopic("Why are eggs not round?"))
        #expect(reply.snapshot != nil)
        #expect(engine.topic == "Why are eggs not round?")
    }

    @Test("A steering message past the limit is refused")
    func steeringIsBounded() async {
        let (service, _) = makeService()
        let reply = await service.handle(.steer(overlong))
        guard let reason = reply.refusal else {
            Issue.record("expected a refusal, got \(reply)")
            return
        }
        #expect(reason.contains("2000"))
    }

    @Test("A steering message within the limit is still accepted")
    func steeringWithinTheLimitWorks() async {
        let (service, _) = makeService()
        let reply = await service.handle(.steer("Could you say more about that?"))
        #expect(reply.snapshot != nil, "a normal message is not affected by the cap")
    }

    @Test("A moderator name past the limit is shortened rather than refused")
    func moderatorNameIsBounded() async {
        let (service, engine) = makeService()
        var identity = engine.moderator
        identity.name = overlong

        let reply = await service.handle(.setModerator(identity))
        #expect(reply.snapshot != nil, "renaming is not the place to refuse")
        #expect(engine.moderator.name.count == EngineService.maximumFieldCharacters)
        // The snapshot's copy is the *display* name, which `PromptBuilder` caps much harder (60) — what
        // matters here is that nothing unbounded reaches it.
        let shown = reply.snapshot?.moderatorName.count ?? 0
        #expect(shown > 0 && shown <= EngineService.maximumFieldCharacters)
    }
}
