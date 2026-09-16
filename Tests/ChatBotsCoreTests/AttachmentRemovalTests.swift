// ChatBotsCoreTests — removing an attachment while the room is running.
//
// The web disabled its ✕ once a conversation had started; the engine's `.removeAttachment` has no
// such guard and the Mac app's button is `.disabled(false)`. This pins the engine's rule, which is
// the one the page now follows: a moderator who attached the wrong file can take it back mid-run,
// from either front end.

import ChatBotsCore
import Foundation
import Testing

@MainActor
@Suite("An attachment can be removed while the conversation runs")
struct AttachmentRemovalTests {

    private func makeService() -> (EngineService, ConversationEngine) {
        let specs = AgentSpec.makeSeats(count: 1)
        let seats = specs.map { ConversationEngine.Seat(spec: $0, engine: RemovalStub(spec: $0)) }
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        let engine = ConversationEngine(seats: seats, configuration: configuration)
        engine.setTopic("A topic")
        let store = ConversationStore(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "removal-\(UUID().uuidString)"))
        return (EngineService(engine: engine, store: store), engine)
    }

    private func attached(_ service: EngineService, _ engine: ConversationEngine) async {
        let document = AttachedDocument(
            name: "source.txt", kind: .plainText, text: "the source material")
        engine.setAttachments([document])
    }

    @Test("Removing an attachment once the conversation has started is refused, not silently ignored")
    func removalMidRunIsRefused() async {
        let (service, engine) = makeService()
        await attached(service, engine)
        #expect(engine.attachments.count == 1)

        engine.start()
        await engine.waitUntilFinished()
        #expect(!engine.canAttachFiles, "the conversation has started")

        let id = engine.attachments[0].id.uuidString
        let reply = await service.handle(.removeAttachment(id: id))
        // The defect: `setAttachments` returned false, this discarded it, and the reply was a state
        // identical to the one the caller had — a removal that did not happen reported as one that did,
        // with the app's ✕ always enabled so a click did nothing at all.
        #expect(reply.refusal != nil, "a refused change must be reported as refused")
        #expect(reply.snapshot == nil, "and not answered with an unchanged state")
        #expect(engine.attachments.count == 1, "the attachment is still there, because the engine refused")
    }

    @Test("Clearing them once the conversation has started is refused the same way")
    func clearingMidRunIsRefused() async {
        let (service, engine) = makeService()
        await attached(service, engine)
        engine.start()
        await engine.waitUntilFinished()

        let reply = await service.handle(.clearAttachments)
        #expect(reply.refusal != nil)
        #expect(engine.attachments.count == 1)
    }

    @Test("Before the conversation starts, removing works and says so")
    func removalBeforeTheStartWorks() async {
        let (service, engine) = makeService()
        await attached(service, engine)
        let id = engine.attachments[0].id.uuidString

        let reply = await service.handle(.removeAttachment(id: id))
        #expect(reply.refusal == nil, "the counterweight: this is allowed, and must stay allowed")
        #expect(reply.snapshot != nil)
        #expect(engine.attachments.isEmpty)
    }

    @Test("Adding a second file mid-run is refused too, which is why the flag gates both")
    func addingMidRunIsRefused() async {
        let (service, engine) = makeService()
        await attached(service, engine)
        engine.start()
        await engine.waitUntilFinished()

        // Adding is refused by the same guard, which is what `canAttachFiles` names: source material is
        // fixed once the conversation has started, and removing is a change to it like any other.
        let reply = await service.handle(.addAttachment(filename: "second.txt", contents: Data("x".utf8)))
        #expect(reply.refusal != nil, "a running conversation does not take new source material")
    }
}

/// A seat that produces nothing, so these tests are about the attachment rules.
private actor RemovalStub: LLMEngine {
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
    ) async throws -> String { "" }
}
