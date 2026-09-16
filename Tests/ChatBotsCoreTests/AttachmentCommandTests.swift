// ChatBotsCoreTests — an attachment command reports what it did.
//
// Two answers that did not match the work, and one window that was left open:
//
//   * `removeAttachment` filtered the attachments by id and answered the state whatever came back, so an
//     id that matched nothing was reported as a removal that happened — the same shape `castVote` already
//     refused for a vote;
//   * the 24-file ceiling was counted *before* the `await`, so two uploads that arrived together both read
//     the same count and both passed it, and the room ended up over the ceiling by however many arrived at
//     once;
//   * the staged upload was written with the process umask and no mode of its own, so on a shared Mac the
//     moderator's document sat readable by every user for as long as the conversion took.
//
// The staging test calls the staging step directly, because the directory is gone before `addAttachment`
// returns — that is the only moment the mode can be read.

import Foundation
import Testing

@testable import ChatBotsCore

/// A seat that answers instantly, so these tests are about the attachment commands.
private actor QuietAttachStub: LLMEngine {
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
    ) async throws -> String { "a reply" }
}

/// Holds every conversion open until the test releases it, so uploads that arrive together are inside the
/// conversion at the same time — which is the moment the ceiling used to be read from, by both of them.
private struct HeldExtractor: DocumentExtracting {
    let arrivals: DispatchSemaphore
    let release: DispatchSemaphore

    func extract(data: Data, from url: URL, kind: DocumentKind, limits: AttachmentLimits) throws
        -> AttachedDocument
    {
        arrivals.signal()
        // Bounded, so a test that fails before it releases cannot wedge the suite.
        _ = release.wait(timeout: .now() + 20)
        return AttachedDocument(name: url.lastPathComponent, kind: kind, text: "the staged document")
    }
}

/// Wait for a signal without blocking the main actor.
private func waitFor(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 20) == .success)
        }
    }
}

private func mode(of url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue
}

@MainActor
private func makeAttachmentService(
    ingestor: DocumentIngestor? = nil
) -> (service: EngineService, engine: ConversationEngine) {
    let specs = AgentSpec.makeSeats(count: 1)
    let seats = specs.map { ConversationEngine.Seat(spec: $0, engine: QuietAttachStub(spec: $0)) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    engine.setTopic("An attachment test")
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "attachment-command-\(UUID().uuidString)"))
    guard let ingestor else {
        return (EngineService(engine: engine, store: store), engine)
    }
    return (EngineService(engine: engine, store: store, attachmentIngestor: { ingestor }), engine)
}

@MainActor
@Suite("An attachment command reports what it did")
struct AttachmentCommandTests {

    @Test("Removing an id that matches nothing is refused, not answered with the state")
    func anUnknownIdIsRefused() async {
        let (service, engine) = makeAttachmentService()
        engine.setAttachments([AttachedDocument(name: "source.txt", kind: .plainText, text: "material")])

        let reply = await service.handle(.removeAttachment(id: UUID().uuidString))
        #expect(
            reply.refusal == "there is no attached file with that id",
            "a removal that never happened was reported as one that did: \(reply)")
        #expect(reply.snapshot == nil, "and it must not be answered with the unchanged state")
        #expect(engine.attachments.count == 1)
    }

    @Test("An id that is not a file id at all is refused as such")
    func aMalformedIdIsRefused() async {
        let (service, engine) = makeAttachmentService()
        engine.setAttachments([AttachedDocument(name: "source.txt", kind: .plainText, text: "material")])

        let reply = await service.handle(.removeAttachment(id: "not-a-file-id"))
        #expect(reply.refusal == "that is not a valid file id", "got \(reply)")
        #expect(engine.attachments.count == 1)
    }

    @Test("Removing an attachment that is there still works")
    func aKnownIdIsRemoved() async {
        // The counterweight: refusing what is not there must not become refusing what is.
        let (service, engine) = makeAttachmentService()
        engine.setAttachments([AttachedDocument(name: "source.txt", kind: .plainText, text: "material")])

        let reply = await service.handle(.removeAttachment(id: engine.attachments[0].id.uuidString))
        #expect(reply.snapshot?.attachments.isEmpty == true, "got \(reply)")
        #expect(engine.attachments.isEmpty)
    }

    @Test("Two uploads that arrive together cannot both take the last place")
    func theCeilingHoldsUnderConcurrency() async {
        let arrivals = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // Named first, because a call whose last argument is a single-line literal inside a multi-line
        // array literal is where swiftlint's `trailing_comma` and swift-format's line breaking disagree.
        let held = HeldExtractor(arrivals: arrivals, release: release)
        let ingestor = DocumentIngestor(extractors: [.plainText: held])
        let (service, engine) = makeAttachmentService(ingestor: ingestor)

        // One place left, set directly so no conversion is involved in the fixture.
        engine.setAttachments(
            (0..<(EngineService.maximumAttachments - 1)).map {
                AttachedDocument(name: "source-\($0).txt", kind: .plainText, text: "material")
            })
        #expect(engine.attachments.count == EngineService.maximumAttachments - 1)

        let first = Task { @MainActor in
            await service.handle(.addAttachment(filename: "a.txt", contents: Data("a".utf8)))
        }
        let second = Task { @MainActor in
            await service.handle(.addAttachment(filename: "b.txt", contents: Data("b".utf8)))
        }
        // Both are inside the conversion before either is allowed to finish. That is the state the old
        // guard was read in: both saw 23 files and both passed.
        #expect(await waitFor(arrivals), "the first upload never reached the conversion")
        #expect(await waitFor(arrivals), "the second upload never reached the conversion")
        release.signal()
        release.signal()
        let replies = [await first.value, await second.value]

        #expect(
            engine.attachments.count == EngineService.maximumAttachments,
            "the ceiling was passed: \(engine.attachments.count) files")
        #expect(
            replies.filter { $0.refusal == "too many attached files" }.count == 1,
            "one of the two should have been refused: \(replies)")
        #expect(replies.filter { $0.snapshot != nil }.count == 1)
    }

    @Test("An upload into a room that is already full is refused before it is staged")
    func aFullRoomRefusesEarly() async {
        let (service, engine) = makeAttachmentService()
        engine.setAttachments(
            (0..<EngineService.maximumAttachments).map {
                AttachedDocument(name: "source-\($0).txt", kind: .plainText, text: "material")
            })

        let reply = await service.handle(.addAttachment(filename: "one-more.txt", contents: Data("x".utf8)))
        #expect(reply.refusal == "too many attached files", "got \(reply)")
        #expect(engine.attachments.count == EngineService.maximumAttachments)
    }

    @Test("A staged upload is created private to this user, and its bytes are all there")
    func stagingIsPrivate() throws {
        let data = Data("the moderator's own document".utf8)
        let staged = try EngineService.stageUpload(contents: data, name: "note.txt")
        defer { try? FileManager.default.removeItem(at: staged.directory) }

        #expect(mode(of: staged.directory) == 0o700, "the staging directory is readable by others")
        #expect(mode(of: staged.file) == 0o600, "the staged file is readable by others")
        #expect(try Data(contentsOf: staged.file) == data)
        #expect(staged.file.lastPathComponent == "note.txt")
        #expect(EngineService.isDirectChild(staged.file, of: staged.directory))
    }
}
