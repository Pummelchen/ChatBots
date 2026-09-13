// ChatBotsCoreTests — sending images to a model
//
// The API side is asserted by shape, because whether a *particular* server can see is not
// something this app can decide: DeepSeek accepts `input_image` and then says it cannot view
// the image, which is exactly why the capability is detected rather than assumed. The local
// checkpoint genuinely sees — verified by hand against a drawn shape — and that path is
// covered by the media-type and byte-conversion tests here.

import ChatBotsCore
import Foundation
import Testing

@Suite("Image attachments")
struct ImageUploadTests {

    /// A real 1×1 PNG, so the bytes are a genuine image rather than arbitrary data.
    private let pngBytes = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!

    private func image(_ name: String = "cat.png", bytes: Data? = nil) -> AttachedDocument {
        AttachedDocument(
            name: name, kind: .image, byteCount: (bytes ?? pngBytes).count,
            imageData: bytes ?? pngBytes)
    }

    @Test("The media type comes from the bytes, not the filename")
    func mediaTypeFromMagicBytes() {
        #expect(image().imageMediaType == "image/png")
        // A JPEG named .png is common, and servers validate the declared type.
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        #expect(image("actually-jpeg.png", bytes: jpeg).imageMediaType == "image/jpeg")
        let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
        #expect(image("x.png", bytes: gif).imageMediaType == "image/gif")
        let bmp = Data([0x42, 0x4D, 0x00, 0x00])
        #expect(image("x.png", bytes: bmp).imageMediaType == "image/bmp")
        let webp = Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])
        #expect(image("x.png", bytes: webp).imageMediaType == "image/webp")
        // Something unrecognisable must not be sent under a made-up type.
        #expect(image("x.png", bytes: Data([0x00, 0x01, 0x02, 0x03])).imageMediaType == nil)
    }

    @Test("A document has no image media type")
    func documentsAreNotImages() {
        let document = AttachedDocument(name: "notes.txt", kind: .plainText, text: "hello")
        #expect(document.imageMediaType == nil)
        #expect(document.imageBase64 == nil)
    }

    @Test("An image with no bytes reports nothing rather than an empty image")
    func emptyImage() {
        let empty = AttachedDocument(name: "broken.png", kind: .image, imageData: Data())
        #expect(empty.imageMediaType == nil)
        #expect(!empty.isUsable)
    }

    @Test("The data URL carries the real media type and base64 payload")
    func dataURL() {
        let attachment = OpenAIResponsesClient.ImageAttachment(
            mediaType: "image/png", base64: "AAAA")
        #expect(attachment.dataURL == "data:image/png;base64,AAAA")
    }
}

@Suite("Images in the API request")
struct ImageRequestShapeTests {

    private let client = OpenAIResponsesClient(
        endpoint: OpenAIEndpoint(baseURL: "https://example.test/v1", model: "a-vision-model"))

    private func request(images: [OpenAIResponsesClient.ImageAttachment]) -> OpenAIResponsesClient.Request {
        OpenAIResponsesClient.Request(
            instructions: "You are Agent 1.",
            input: "What is in the image?",
            maxOutputTokens: 200,
            includeReasoning: false,
            images: images)
    }

    @Test("With no image the input stays a plain string")
    func textOnlyInputIsAString() throws {
        let body = client.body(for: request(images: []))
        // Unchanged for every model that cannot see: a string, as before.
        #expect(body["input"] as? String == "What is in the image?")
    }

    @Test("With an image the input becomes content blocks carrying the image")
    func imageInputBecomesBlocks() throws {
        let body = client.body(for: request(images: [
            .init(mediaType: "image/png", base64: "QUJD")
        ]))
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 1, "one user message")

        let message = input[0]
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.count == 2, "the text part and the image part")

        #expect(content[0]["type"] as? String == "input_text")
        #expect(content[0]["text"] as? String == "What is in the image?")
        #expect(content[1]["type"] as? String == "input_image")
        #expect(content[1]["image_url"] as? String == "data:image/png;base64,QUJD")
    }

    @Test("Several images all travel with the one message")
    func multipleImages() throws {
        let body = client.body(for: request(images: [
            .init(mediaType: "image/png", base64: "QQ"),
            .init(mediaType: "image/jpeg", base64: "Qg"),
        ]))
        let input = try #require(body["input"] as? [[String: Any]])
        let content = try #require(input[0]["content"] as? [[String: Any]])
        #expect(content.count == 3)
        #expect(content.filter { $0["type"] as? String == "input_image" }.count == 2)
    }
}

@Suite("Vision capability decides whether images are sent")
struct VisionGatingTests {

    @Test("A text-only API model is not sent images, even if files were added")
    func textOnlyModelGetsNoImages() {
        var spec = AgentSpec.seat(index: 0)
        spec.backend = .openAIResponses
        spec.modelID = "some-local-server/a-text-model"
        spec.visionOverride = .unsupported
        // The engine checks this before building the request, so an image added to the
        // conversation cannot reach a model that would reject it or hallucinate around it.
        #expect(!spec.visionSupport.allowsImages)
    }

    @Test(
        "The shipped local checkpoint declares vision, so images are offered",
        .enabled(if: ModelStore.declaresVision(for: AgentSpec.defaultModelID) != nil))
    func localCheckpointSees() {
        // Gated on the checkpoint being on disk: this asserts what a download buys, and a
        // fresh clone has not paid for it yet. The rule it exercises is covered hermetically
        // in AttachmentTests.
        let declared = ModelStore.declaresVision(for: AgentSpec.defaultModelID)
        #expect(declared == true)
        var spec = AgentSpec.seat(index: 0)
        spec.backend = .mlx
        #expect(spec.visionSupport.allowsImages)
    }
}
