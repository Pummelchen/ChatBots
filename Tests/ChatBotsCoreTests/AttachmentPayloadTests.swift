// ChatBotsCoreTests — what a snapshot does and does not carry
//
// `EngineService.snapshot()` put every attached image into the snapshot as
// `imageBase64: document.imageData?.base64EncodedString()`. That is the payload of every state push —
// the SSE `snapshot` event and the WebTransport state message — so:
//
//   · every client was sent a base64 copy of every attached image on every turn, re-encoded each time
//, up to 24 files of up to 64 MB each; and
//   · the snapshot could exceed the transport's own message cap, which is derived as the base64 form
//     of *one* maximum-size attachment plus its envelope. Two maximum-size images need twice that, and
//     an over-cap message is not a slow push: the transmitter refuses to frame it, so the state update
//     is dropped and the client keeps the previous state.
//
// Nothing rendered the field. The page's chip is a name and a summary; the Mac app's chip is an SF
// Symbol by kind; the engine's own model request reads `imageData` in-process. So these two tests pin
// what the snapshot must now be: metadata only, and inside the cap with a maximum-size attachment.
//
// Both are written so they compile against the code before the fix as well as after — the size and the
// presence of the bytes are both observable without the field — which is what makes the before/after a
// measurement rather than an argument.

import ChatBotsCore
import Foundation
import Testing

@MainActor
@Suite("An attachment in the snapshot")
struct AttachmentPayloadTests {

    private actor Quiet: LLMEngine {
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

    private func makeService() -> (EngineService, ConversationEngine) {
        let specs = AgentSpec.makeSeats(count: 1)
        let seats = specs.map { ConversationEngine.Seat(spec: $0, engine: Quiet(spec: $0)) }
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        let engine = ConversationEngine(seats: seats, configuration: configuration)
        engine.setTopic("A topic")
        let store = ConversationStore(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "payload-\(UUID().uuidString)"))
        return (EngineService(engine: engine, store: store), engine)
    }

    /// An encoded snapshot, as it goes on the wire.
    private func encoded(_ service: EngineService) throws -> Data {
        try JSONEncoder().encode(service.snapshot())
    }

    /// Distinctive bytes, for the test that searches the encoded snapshot for them. Built cheaply
    /// rather than pseudo-randomly: a byte-at-a-time generator over 64 MB is minutes of debug-time
    /// work, and what is being measured here is the snapshot, not the generator.
    private func distinctiveImageBytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    /// Filler for an attachment whose *size* is the point. The content is irrelevant to the size
    /// tests — nothing decodes it — so it is one byte repeated, which is instant even at 64 MB.
    private func imageBytes(_ count: Int, seed: UInt8 = 0) -> Data {
        Data(repeating: seed &+ 0x5A, count: count)
    }

    @Test("The snapshot carries an attachment's metadata and not its bytes")
    func theSnapshotCarriesNoImageBytes() throws {
        let (service, engine) = makeService()
        let image = distinctiveImageBytes(64 * 1024)
        let document = AttachedDocument(
            name: "scan.png", kind: .image, byteCount: image.count, imageData: image)
        #expect(engine.setAttachments([document]))

        let data = try encoded(service)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("scan.png"), "the chip's name is still there")
        // A size, not a search for the base64 text: Foundation's encoder writes `/` as `\/`, so
        // searching the encoded form for a base64 needle can miss the very bytes it is looking for —
        // which is what a first version of this test did. The image is 64 KiB and its base64 form is
        // 87 KiB, so a snapshot under the image's own size cannot be carrying it.
        #expect(
            data.count < image.count,
            "the snapshot is \(data.count) bytes for a \(image.count)-byte image, so it is carrying it"
        )
    }

    @Test("One maximum-size attachment leaves the snapshot inside the transport's cap")
    func oneMaximumAttachmentFitsInTheMessageCap() throws {
        let (service, engine) = makeService()
        let limit = AttachmentLimits.defaultMaximumFileBytes
        let document = AttachedDocument(
            name: "big-scan.png", kind: .image, byteCount: limit,
            imageData: imageBytes(limit, seed: 7))
        #expect(engine.setAttachments([document]))

        let data = try encoded(service)
        // One image fits the cap even before the fix — the cap *is* one maximum-size attachment plus
        // its envelope — so the claim this pins is the one that matters: the snapshot's size no longer
        // scales with what is attached. It would be at least the image's 85 MiB base64 form otherwise.
        #expect(
            data.count < 1_000_000,
            "the snapshot is \(data.count) bytes for a \(limit)-byte attachment")
        #expect(data.count < ProtocolLimits.maximumMessageBytes)
    }

    @Test("Two maximum-size attachments still leave it inside the cap")
    func twoMaximumAttachmentsFitInTheMessageCap() throws {
        // The case the finding names: 2 × 85.3 MiB against an 85.3 MiB cap, so the state push was
        // refused and the client kept the previous state — not slow, absent.
        let (service, engine) = makeService()
        let limit = AttachmentLimits.defaultMaximumFileBytes
        let documents = [
            AttachedDocument(
                name: "front.png", kind: .image, byteCount: limit,
                imageData: imageBytes(limit, seed: 1)),
            AttachedDocument(
                name: "back.png", kind: .image, byteCount: limit,
                imageData: imageBytes(limit, seed: 2)),
        ]
        #expect(engine.setAttachments(documents))

        let data = try encoded(service)
        #expect(
            data.count < ProtocolLimits.maximumMessageBytes,
            """
            the snapshot is \(data.count) bytes against a \(ProtocolLimits.maximumMessageBytes)-byte \
            cap, so the engine cannot send it at all
            """)
    }

    @Test("The bytes the model is sent are still the engine's own copy")
    func theEngineStillHoldsTheImage() async {
        // Removing the bytes from the snapshot must not remove them from the engine: this is what the
        // cloud client renders into the data URL of the model request.
        let (_, engine) = makeService()
        let image = distinctiveImageBytes(1024)
        let document = AttachedDocument(
            name: "scan.png", kind: .image, byteCount: image.count, imageData: image)
        #expect(engine.setAttachments([document]))

        #expect(engine.attachments.first?.imageData == image)
        #expect(engine.attachments.first?.imageBase64 == image.base64EncodedString())
    }
}
