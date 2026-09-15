// ChatBotsCoreTests — choosing a checkpoint (the model catalogue and the seat swap)
//
// Two things are tested here that did not exist before: a list of known-good checkpoints with short
// names, and the ability to point a seat at a different one while the engine is alive. The second is
// the one with teeth — a seat's MLX engine holds a whole checkpoint in memory, so changing the model
// means building a new engine and releasing the old one, and doing that while a turn is generating
// would fail the turn for a reason nobody asked for.

import Foundation
import Synchronization
import Testing

@testable import ChatBotsCore

@Suite("The model catalogue")
struct ModelCatalogTests {

    @Test("Every entry is complete and identifiable")
    func entriesAreComplete() {
        #expect(!ModelCatalog.choices.isEmpty)
        for choice in ModelCatalog.choices {
            #expect(!choice.id.isEmpty, "an entry with no repository id cannot be loaded")
            #expect(choice.id.contains("/"), "\(choice.id) is not a repository id")
            #expect(!choice.name.isEmpty)
            #expect(!choice.summary.isEmpty)
            #expect(!choice.aliases.isEmpty, "\(choice.id) has no short name")
        }
    }

    @Test("The checkpoint the app ships with is in the list")
    func theDefaultIsListed() {
        // A picker that cannot show the model in use would be lying about it, so the shipped default
        // is the first thing the catalogue has to be able to name.
        let choice = ModelCatalog.choice(for: AgentSpec.defaultModelID)
        #expect(choice != nil)
        #expect(choice?.id == AgentSpec.defaultModelID)
    }

    @Test("An alias and an id resolve to the same repository id")
    func aliasesResolve() {
        for choice in ModelCatalog.choices {
            #expect(ModelCatalog.resolve(choice.id) == choice.id)
            for alias in choice.aliases {
                #expect(ModelCatalog.resolve(alias) == choice.id, "alias \(alias)")
                // Aliases are matched without regard to case or surrounding whitespace, because a
                // short name is typed by hand.
                #expect(ModelCatalog.resolve(alias.uppercased()) == choice.id)
                #expect(ModelCatalog.resolve("  \(alias)  ") == choice.id)
            }
        }
    }

    @Test("No alias or id is claimed twice")
    func namesAreUnique() {
        // First match wins in `choice(for:)`, so a duplicate would make one entry unreachable while
        // still looking present.
        var seen: [String: String] = [:]
        for choice in ModelCatalog.choices {
            for name in [choice.id] + choice.aliases {
                let key = name.lowercased()
                #expect(seen[key] == nil, "\(name) is claimed by \(seen[key] ?? "") and \(choice.id)")
                seen[key] = choice.id
            }
        }
    }

    @Test("An identifier that is not in the catalogue is passed through unchanged")
    func unknownIdentifiersPassThrough() {
        // The catalogue is a convenience, not an allow-list: any repository id is a legitimate value
        // and always has been.
        #expect(ModelCatalog.resolve("some-org/some-model") == "some-org/some-model")
        #expect(ModelCatalog.choice(for: "some-org/some-model") == nil)
        #expect(ModelCatalog.resolve("  some-org/some-model  ") == "some-org/some-model")
        #expect(ModelCatalog.resolve("") == "")
    }
}

@MainActor
@Suite("Pointing a seat at another checkpoint")
struct SeatModelTests {

    /// An engine that records which checkpoint it was built for, so a swap is visible without weights.
    private final class StubEngine: LLMEngine, @unchecked Sendable {
        nonisolated let spec: AgentSpec
        private let onUnload: @Sendable (String) -> Void
        /// When true, a turn stays open until it is cancelled, so the test can sit in the state the
        /// engine refuses a swap in.
        private let holdsTurnsOpen: Bool

        init(
            spec: AgentSpec,
            holdsTurnsOpen: Bool = false,
            onUnload: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.spec = spec
            self.holdsTurnsOpen = holdsTurnsOpen
            self.onUnload = onUnload
        }

        var isLoaded: Bool { true }
        var contextWindow: Int { spec.contextWindow }
        var currentSpec: AgentSpec { spec }
        func load() async throws {}
        func unload() async { onUnload(spec.modelID) }
        func generate(
            messages: [PromptMessage],
            tools: [any ToolProvider],
            onToolCall: @escaping @Sendable (String, String) async -> Void,
            onEvent: @escaping @Sendable (TurnEvent) async -> Void
        ) async throws -> String {
            if holdsTurnsOpen { try await Task.sleep(for: .seconds(30)) }
            return ""
        }
    }

    private func makeEngine(
        holdsTurnsOpen: Bool = false,
        onUnload: @escaping @Sendable (String) -> Void = { _ in }
    ) -> (ConversationEngine, [AgentSpec]) {
        let specs = AgentSpec.makeSeats(count: 2)
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        configuration.makeMLXEngine = { spec in
            StubEngine(spec: spec, holdsTurnsOpen: holdsTurnsOpen, onUnload: onUnload)
        }
        // The initial engines get the same recorder as the factory: the seat being swapped is one of
        // these, and a test that only recorded new engines would watch the wrong one.
        let seats = specs.map {
            ConversationEngine.Seat(
                spec: $0,
                engine: StubEngine(
                    spec: $0, holdsTurnsOpen: holdsTurnsOpen, onUnload: onUnload))
        }
        return (ConversationEngine(seats: seats, configuration: configuration), specs)
    }

    @Test("A new checkpoint replaces the seat's engine, and the old one is released")
    func changingTheModelRebuildsTheEngine() async {
        let released = Mutex<[String]>([])
        let (engine, specs) = makeEngine { modelID in
            released.withLock { $0.append(modelID) }
        }
        let original = specs[0].modelID
        let wanted = ModelCatalog.choices[1].id

        #expect(engine.setModel(wanted, for: specs[0].id))

        #expect(engine.specs[0].modelID == wanted)
        #expect(engine.specs[0].modelShortName == ModelNames.shortName(wanted))
        #expect((engine.seatEngine(for: specs[0].id) as? StubEngine)?.spec.modelID == wanted)
        // The other seat is untouched: a checkpoint belongs to one participant.
        #expect(engine.specs[1].modelID == specs[1].modelID)

        // The old engine is unloaded, not merely dropped: it holds the whole checkpoint. The unload
        // runs in a task of its own, so the test yields to it rather than assuming it has run.
        for _ in 0..<100 where released.withLock({ $0.isEmpty }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(
            released.withLock { $0 } == [original],
            "unloaded \(released.withLock { $0 }) rather than [\(original)]")
    }

    @Test("An alias works as well as a repository id")
    func aliasesAreAccepted() {
        let (engine, specs) = makeEngine()
        let huihui = ModelCatalog.choices.first { $0.aliases.contains("huihui9b") }
        #expect(huihui != nil)

        #expect(engine.setModel("huihui9b", for: specs[0].id))
        #expect(engine.specs[0].modelID == huihui?.id)
    }

    @Test("Naming the model a seat already runs changes nothing")
    func theSameModelIsNotASwap() {
        let (engine, specs) = makeEngine()
        #expect(!engine.setModel(specs[0].modelID, for: specs[0].id))
        #expect(!engine.setModel("", for: specs[0].id))
        #expect(!engine.setModel(ModelCatalog.choices[1].id, for: "Agent 99"))
    }

    @Test("A model cannot be swapped while a turn is in flight")
    func aRunningRoomRefusesTheSwap() async {
        // A turn in flight is generating on the engine that would be released underneath it.
        let (engine, specs) = makeEngine(holdsTurnsOpen: true)
        engine.start(topic: "A topic")
        #expect(engine.hasTurnInFlight)
        let wanted = ModelCatalog.choices[1].id

        #expect(!engine.setModel(wanted, for: specs[0].id))
        #expect(engine.specs[0].modelID == specs[0].modelID, "the seat keeps the model it ran")

        engine.stop()
        await engine.waitUntilFinished()
        #expect(!engine.hasTurnInFlight)
        #expect(engine.setModel(wanted, for: specs[0].id), "and can change once the turn is over")
    }

    @Test("The state carries the catalogue, so a front end can offer it")
    func theSnapshotCarriesTheCatalogue() {
        let (engine, _) = makeEngine()
        let store = ConversationStore(
            directory: FileManager.default.temporaryDirectory.appending(path: "seats-\(UUID().uuidString)"))
        let service = EngineService(engine: engine, store: store)

        let offered = service.snapshot().availableModels ?? []
        #expect(offered.map(\.id) == ModelCatalog.choices.map(\.id))
        #expect(offered.allSatisfy { !$0.name.isEmpty && !$0.summary.isEmpty })
        #expect(offered.contains { $0.sizeLabel != nil }, "a size hint is what a user agrees to")
    }

    @Test("The HTTP body carries the checkpoint under its own key")
    func theCommandDecodesTheModel() throws {
        // The route builds a `SeatChange` from this, so the field has to survive the wire format. It is
        // `modelID` rather than `apiModel`, which names a model *on a server* and is already taken.
        let body = Data(#"{"seat":"Agent 1","modelID":"huihui9b"}"#.utf8)
        let command = try JSONDecoder().decode(APICommand.self, from: body)
        #expect(command.modelID == "huihui9b")
        #expect(command.apiModel == nil, "the two are different fields")
    }

    @Test("The protocol refuses a swap in flight with a reason rather than ignoring it")
    func theServiceRefusesWithAReason() async {
        let (engine, specs) = makeEngine(holdsTurnsOpen: true)
        let store = ConversationStore(
            directory: FileManager.default.temporaryDirectory.appending(path: "seats-\(UUID().uuidString)"))
        let service = EngineService(engine: engine, store: store)
        let wanted = ModelCatalog.choices[1].id

        engine.start(topic: "A topic")
        let refused = await service.handle(
            .updateSeat(.init(seatID: specs[0].id, modelID: wanted)))
        guard case .refused(let reason) = refused else {
            Issue.record("expected a refusal, got \(refused)")
            return
        }
        #expect(reason.contains("in flight"))
        #expect(engine.specs[0].modelID == specs[0].modelID)
        engine.stop()
        await engine.waitUntilFinished()

        // An empty model is refused too: it is a value that cannot take effect, not a silent no-op.
        let empty = await service.handle(
            .updateSeat(.init(seatID: specs[0].id, modelID: "   ")))
        guard case .refused(let emptyReason) = empty else {
            Issue.record("expected a refusal, got \(empty)")
            return
        }
        #expect(emptyReason.contains("model"))
    }

    @Test("A stopped room takes the new checkpoint through the protocol")
    func theServiceAppliesIt() async {
        let (engine, specs) = makeEngine()
        let store = ConversationStore(
            directory: FileManager.default.temporaryDirectory.appending(path: "seats-\(UUID().uuidString)"))
        let service = EngineService(engine: engine, store: store)
        let wanted = ModelCatalog.choices[2].id

        let reply = await service.handle(
            .updateSeat(.init(seatID: specs[0].id, modelID: "huihui-9b")))
        guard case .state(let snapshot) = reply else {
            Issue.record("expected a state, got \(reply)")
            return
        }
        let seat = snapshot.seats.first { $0.id == specs[0].id }
        #expect(seat?.modelShortName == ModelNames.shortName(wanted))
        #expect(engine.specs[0].modelID == wanted)
    }
}
