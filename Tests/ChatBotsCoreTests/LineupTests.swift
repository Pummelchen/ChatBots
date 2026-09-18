// ChatBotsCoreTests — line-ups and scenarios
//
// The presets are hand-written lists of identifiers from two large libraries, which is exactly
// the kind of thing that goes wrong quietly: a typo produces a seat whose persona silently
// resolves to the mode's default, and the room is not the room the preset promised. So the
// first test here checks every identifier in every preset against the library it names, and the
// rest check the behaviour a front end depends on.

import ChatBotsCore
import Foundation
import Testing

/// An engine that answers without a model.
private actor IdleStub: LLMEngine {
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
private func lineupService(seats: Int = 4) -> (EngineService, ConversationEngine) {
    let specs = AgentSpec.makeSeats(count: seats)
    let stubs = specs.map { IdleStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    let paired = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    let engine = ConversationEngine(seats: paired, configuration: configuration)
    // A topic, because `start` refuses a blank one and a conversation that never starts is never
    // running — which would make the "locked while running" tests pass for the wrong reason.
    engine.setTopic("A question")
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "lineup-\(UUID().uuidString)"))
    return (EngineService(engine: engine, store: store), engine)
}

@Suite("Line-ups")
@MainActor
struct LineupTests {

    @Test("Every preset names personas that exist in its own mode")
    func presetsResolve() {
        // The failure this catches is silent: an unknown identifier resolves to the mode's
        // default persona rather than erroring, so a typo would ship as a room of four people
        // wearing the same default character and nobody would notice from the code.
        var unknown: [String] = []
        var repeated: [String] = []
        var blank: [String] = []
        for mode in DiscussionMode.allCases {
            let available = Set(PersonaCatalog.styles(for: mode).map(\.id))
            for roster in RosterLibrary.rosters(for: mode) {
                for id in roster.personaIDs where !available.contains(id) {
                    unknown.append("\(roster.id) → \(id) (\(mode.rawValue))")
                }
                if Set(roster.personaIDs).count != roster.personaIDs.count {
                    repeated.append(roster.id)
                }
                // Every field is shown to a user, so an empty one is a blank in the picker.
                if roster.personaIDs.isEmpty || roster.name.isEmpty || roster.summary.isEmpty {
                    blank.append(roster.id)
                }
            }
        }
        #expect(unknown.isEmpty)
        #expect(repeated.isEmpty)
        #expect(blank.isEmpty)
    }

    @Test("No preset is longer than the seats the engine supports")
    func presetsFitTheRoom() {
        var oversized: [String] = []
        for mode in DiscussionMode.allCases {
            for roster in RosterLibrary.rosters(for: mode)
            where roster.count > AgentSpec.supportedSeatCount {
                oversized.append(roster.id)
            }
        }
        #expect(oversized.isEmpty)
    }

    @Test("A draw is reproducible from its seed")
    func drawsAreReproducible() {
        // The property the whole feature rests on: a line-up nobody can reproduce is a line-up
        // nobody can share, and a kept conversation cannot be continued with the same room.
        for mode in DiscussionMode.allCases {
            let first = RosterLibrary.draw(mode: mode, seats: 4, seed: 4_181)
            let again = RosterLibrary.draw(mode: mode, seats: 4, seed: 4_181)
            #expect(first.personaIDs == again.personaIDs)
            #expect(first.seed == 4_181)
        }
    }

    @Test("Different seeds give different rooms")
    func seedsDiffer() {
        // Not a statistical claim: two specific seeds, chosen so that a generator that ignored
        // its seed entirely — the easy way to get reproducibility wrong — fails here.
        let firstDraw = RosterLibrary.draw(mode: .entertainment, seats: 4, seed: 1)
        let secondDraw = RosterLibrary.draw(mode: .entertainment, seats: 4, seed: 2)
        #expect(firstDraw.personaIDs != secondDraw.personaIDs)
    }

    @Test("A draw seats nobody twice, and never more than the room holds")
    func drawsDoNotRepeat() {
        let draw = RosterLibrary.draw(mode: .research, seats: 4, seed: 99)
        #expect(Set(draw.personaIDs).count == draw.personaIDs.count)

        // Asking for more seats than the library has returns the library rather than looping:
        // seating the Villain twice would be worse than seating three people.
        let oversized = RosterLibrary.draw(mode: .research, seats: 500, seed: 7)
        #expect(Set(oversized.personaIDs).count == oversized.personaIDs.count)
        #expect(oversized.personaIDs.count <= PersonaCatalog.styles(for: .research).count)
    }

    @Test("A draw never picks a communication style as a participant")
    func drawsArePeopleNotStyles() {
        // "Meticulous" is a way of talking, not somebody with something to want. A room drawn
        // from the style library would be four voices with nothing between them.
        let draw = RosterLibrary.draw(mode: .entertainment, seats: 200, seed: 3)
        let characters = Set(SocialLibrary.all.map(\.id))
        #expect(draw.personaIDs.allSatisfy { characters.contains($0) })

        let researchDraw = RosterLibrary.draw(mode: .research, seats: 200, seed: 3)
        let analysts = Set(AnalystLibrary.all.filter { $0.id != AnalystLibrary.moderatorID }.map(\.id))
        #expect(researchDraw.personaIDs.allSatisfy { analysts.contains($0) })
    }

    @Test("Applying a line-up sets the seats and says what it did")
    func applyingALineup() async throws {
        let (service, engine) = lineupService()
        // `try #require` rather than `try?`: swallowing the failure into an empty list made the
        // seat comparison below pass vacuously on a missing line-up.
        let roster = try #require(RosterLibrary.roster(id: "methods-panel", mode: .research))

        // The engine is in entertainment by default, so switch it first — a line-up is offered
        // per mode and only resolves in its own.
        _ = engine.setMode(.research)
        let reply = await service.handle(.applyRoster(id: "methods-panel", seed: 1))

        #expect(reply.snapshot != nil)
        let expected = roster.personaIDs
        #expect(Array(engine.specs.prefix(expected.count)).map(\.personaID) == expected)
        #expect(engine.notices.contains { $0.contains("Line-up") })
    }

    @Test("A random line-up reports the seed it used")
    func randomLineupReportsItsSeed() async {
        let (service, engine) = lineupService()
        let reply = await service.handle(.applyRoster(id: RosterLibrary.randomID, seed: 777))
        #expect(reply.snapshot != nil)
        // The seed is the only way the draw can be repeated, so it has to reach the user.
        #expect(engine.notices.contains { $0.contains("seed 777") })

        // And the same seed through the service produces the same room.
        let first = engine.specs.map(\.personaID)
        let second = await service.handle(.applyRoster(id: RosterLibrary.randomID, seed: 777))
        #expect(second.snapshot != nil)
        #expect(engine.specs.map(\.personaID) == first)
    }

    @Test("A line-up cannot be changed once the conversation has started")
    func lineupsAreLockedWhileRunning() async {
        let (service, engine) = lineupService()
        engine.start()
        let reply = await service.handle(.applyRoster(id: RosterLibrary.randomID, seed: 5))
        #expect(reply.refusal?.contains("once the conversation has started") == true)
        await engine.waitUntilFinished()
    }

    @Test("An unknown line-up is refused rather than quietly doing nothing")
    func unknownLineupIsRefused() async {
        let (service, _) = lineupService()
        let reply = await service.handle(.applyRoster(id: "no-such-roster", seed: 1))
        #expect(reply.refusal?.contains("no line-up called") == true)
    }

    @Test("The libraries are listed per mode, not merged")
    func librariesAreListedPerMode() async {
        let (service, _) = lineupService()
        let entertainment = await service.handle(.listRosters(.entertainment)).rosters ?? []
        let research = await service.handle(.listRosters(.research)).rosters ?? []
        #expect(!entertainment.isEmpty && !research.isEmpty)
        #expect(entertainment.allSatisfy { $0.mode == .entertainment })
        #expect(research.allSatisfy { $0.mode == .research })
        #expect(Set(entertainment.map(\.id)).isDisjoint(with: Set(research.map(\.id))))
    }
}

@Suite("Scenarios")
@MainActor
struct ScenarioTests {

    @Test("Every scenario is complete, and points at a line-up that exists")
    func scenariosResolve() {
        var incomplete: [String] = []
        // The pairing is the point of a scenario, so a dangling reference would leave a question
        // with the wrong room and no way to tell.
        var dangling: [String] = []
        for scenario in ScenarioLibrary.all {
            if scenario.topic.isEmpty || scenario.note.isEmpty {
                incomplete.append(scenario.id)
            }
            if let rosterID = scenario.rosterID,
                RosterLibrary.roster(id: rosterID, mode: scenario.mode) == nil
            {
                dangling.append("\(scenario.id) → \(rosterID)")
            }
        }
        #expect(incomplete.isEmpty)
        #expect(dangling.isEmpty)
        #expect(Set(ScenarioLibrary.all.map(\.id)).count == ScenarioLibrary.all.count)
    }

    @Test("A scenario draw is reproducible and comes from the right mode")
    func scenarioDraw() {
        let first = ScenarioLibrary.draw(mode: .research, seed: 12)
        let again = ScenarioLibrary.draw(mode: .research, seed: 12)
        #expect(first?.scenario.id == again?.scenario.id)
        #expect(first?.scenario.mode == .research)
    }

    @Test("Applying a scenario sets the question, the mode and the panel together")
    func applyingAScenario() async throws {
        let (service, engine) = lineupService()
        // `try #require` rather than `try?`: the scenario is what the assertions below compare
        // against, so failing to find it must fail the test rather than skip every check.
        let scenario = try #require(ScenarioLibrary.scenario(id: "four-day-week"))

        let reply = await service.handle(.applyScenario(id: "four-day-week"))
        #expect(reply.snapshot != nil)
        #expect(engine.topic == scenario.topic)
        #expect(engine.specs.first?.mode == .research)
        if let rosterID = scenario.rosterID,
            let roster = RosterLibrary.roster(id: rosterID, mode: .research)
        {
            #expect(Array(engine.specs.prefix(roster.count)).map(\.personaID) == roster.personaIDs)
        }
        // The budget travels with the scenario, or a "deep" question runs on a quick budget.
        if let depth = scenario.depth {
            #expect(engine.researchStatus()?.depth == depth.label)
        }
    }

    @Test("Applying a scenario clears a topic that was already there")
    func scenarioReplacesTheTopic() async {
        // A scenario is a ready-made session, so half of it must not survive: a leftover topic
        // would leave the room investigating the previous question with the new panel.
        let (service, engine) = lineupService()
        _ = engine.setTopic("Something else entirely")
        _ = await service.handle(.applyScenario(id: "hotdog"))
        #expect(engine.topic == ScenarioLibrary.scenario(id: "hotdog")?.topic)
    }

    @Test("A scenario cannot be applied to a conversation already running")
    func scenariosAreLockedWhileRunning() async {
        let (service, engine) = lineupService()
        engine.start()
        let reply = await service.handle(.applyScenario(id: "hotdog"))
        #expect(reply.refusal?.contains("once the conversation has started") == true)
        await engine.waitUntilFinished()
    }

    @Test("An unknown scenario is refused")
    func unknownScenarioIsRefused() async {
        let (service, _) = lineupService()
        let reply = await service.handle(.applyScenario(id: "not-a-scenario"))
        #expect(reply.refusal?.contains("no scenario called") == true)
    }

    @Test("Scenarios are listed per mode")
    func scenariosAreListedPerMode() async {
        let (service, _) = lineupService()
        let entertainment = await service.handle(.listScenarios(.entertainment)).scenarios ?? []
        let research = await service.handle(.listScenarios(.research)).scenarios ?? []
        #expect(entertainment.allSatisfy { $0.mode == .entertainment })
        #expect(research.allSatisfy { $0.mode == .research })
        #expect(!entertainment.isEmpty && !research.isEmpty)
    }
}
