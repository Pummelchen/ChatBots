// ChatBotsCoreTests — documents and images the moderator adds

import ChatBotsCore
import Foundation
import Testing

/// A seat that produces one short reply, enough to drive the engine.
private actor RecordingStub: LLMEngine {
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
        let text = "reply"
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 1, stopReason: "stop")))
        return text
    }
}

/// Stands in for a real extractor.
private struct FakeExtractor: DocumentExtracting {
    var text: String
    var pageCount: Int?
    var imageData: Data?
    var throwsError: DocumentError?

    func extract(url: URL, kind: DocumentKind, limits: AttachmentLimits) throws -> AttachedDocument {
        if let throwsError { throw throwsError }
        let truncated = text.count > limits.maximumTextCharacters
        return AttachedDocument(
            name: url.lastPathComponent, kind: kind,
            text: truncated ? String(text.prefix(limits.maximumTextCharacters)) : text,
            pageCount: pageCount, wasTruncated: truncated, imageData: imageData)
    }
}

private func file(named name: String, bytes: Int = 100) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "chatbots-attach-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return url
}

private func ingestor(
    text: String? = "Some document text.",
    pageCount: Int? = nil,
    imageData: Data? = nil,
    throwsError: DocumentError? = nil
) -> DocumentIngestor {
    let extractor = FakeExtractor(
        text: text ?? "", pageCount: pageCount, imageData: imageData, throwsError: throwsError)
    return DocumentIngestor(extractors: [
        .plainText: extractor, .markdown: extractor, .pdf: extractor,
        .word: extractor, .richText: extractor, .html: extractor, .image: extractor,
    ])
}

@Suite("File kinds")
struct DocumentKindTests {

    @Test("Extensions map to the right kind")
    func extensionMapping() {
        #expect(DocumentKind.forFilename("notes.txt") == .plainText)
        #expect(DocumentKind.forFilename("README.md") == .markdown)
        #expect(DocumentKind.forFilename("paper.PDF") == .pdf, "case must not matter")
        #expect(DocumentKind.forFilename("report.docx") == .word)
        #expect(DocumentKind.forFilename("page.html") == .html)
        #expect(DocumentKind.forFilename("photo.PNG") == .image)
        #expect(DocumentKind.forFilename("scan.jpeg") == .image)
        #expect(DocumentKind.forFilename("mystery.xyz") == nil)
        #expect(DocumentKind.forFilename("noextension") == nil)
    }

    @Test("Images are distinguished from documents")
    func imageKinds() {
        #expect(DocumentKind.image.isImage)
        for kind in DocumentKind.allCases where kind != .image {
            #expect(!kind.isImage, "\(kind) should not be treated as an image")
        }
        // The open panel offers every non-image extension for documents.
        #expect(DocumentKind.documentExtensions.contains("pdf"))
        #expect(DocumentKind.documentExtensions.contains("docx"))
        #expect(DocumentKind.documentExtensions.contains("md"))
        #expect(!DocumentKind.documentExtensions.contains("png"))
        #expect(DocumentKind.imageExtensions.contains("png"))
        #expect(DocumentKind.imageExtensions.contains("jpg"))
    }

    @Test("Each kind has a label and a symbol")
    func labelsAndSymbols() {
        for kind in DocumentKind.allCases {
            #expect(!kind.label.isEmpty)
            #expect(!kind.symbol.isEmpty)
            #expect(!kind.extensions.isEmpty)
        }
    }
}

@Suite("Adding documents")
struct DocumentIngestTests {

    @Test("A document is added with its text, name and size")
    func addsDocument() throws {
        let url = try file(named: "notes.txt", bytes: 250)
        let document = try ingestor(text: "Eggs are ovoid.").add(url: url)

        #expect(document.name == "notes.txt")
        #expect(document.kind == .plainText)
        #expect(document.text == "Eggs are ovoid.")
        #expect(document.byteCount == 250, "the real file size should be recorded")
        #expect(document.isUsable)
    }

    @Test("An unsupported extension is refused with a clear reason")
    func refusesUnsupported() throws {
        let url = try file(named: "thing.xyz")
        #expect(throws: DocumentError.self) { try ingestor().add(url: url) }
        do {
            _ = try ingestor().add(url: url)
        } catch let error as DocumentError {
            #expect(error.errorDescription?.contains("thing.xyz") == true)
        }
    }

    @Test("A file over the size limit is refused before it is read")
    func refusesOversized() throws {
        let url = try file(named: "huge.txt", bytes: 5_000)
        var limits = AttachmentLimits.standard
        limits.maximumFileBytes = 1_000
        #expect(throws: DocumentError.self) { try ingestor().add(url: url, limits: limits) }
    }

    @Test("An empty document is refused rather than attached as nothing")
    func refusesEmpty() throws {
        let url = try file(named: "empty.txt")
        #expect(throws: DocumentError.self) { try ingestor(text: "   \n  ").add(url: url) }
    }

    @Test("A PDF with no text layer is reported as needing OCR, not as empty")
    func reportsScannedPDF() throws {
        // The distinction matters: "pick another file" and "this is a scan" call for
        // different actions from the moderator.
        let url = try file(named: "scan.pdf")
        do {
            _ = try ingestor(text: "").add(url: url)
            Issue.record("expected a failure")
        } catch let error as DocumentError {
            #expect(error == .needsOCR("scan.pdf"))
            #expect(error.errorDescription?.contains("scan") == true)
        }
    }

    @Test("A long document is shortened and says so")
    func truncatesLongDocument() throws {
        let url = try file(named: "book.txt")
        var limits = AttachmentLimits.standard
        limits.maximumTextCharacters = 100
        let document = try ingestor(text: String(repeating: "word ", count: 500))
            .add(url: url, limits: limits)

        #expect(document.text.count == 100)
        #expect(document.wasTruncated)
        #expect(document.summary.contains("shortened"), "the moderator should be told")
    }

    @Test("An image is added with its bytes and no text")
    func addsImage() throws {
        let url = try file(named: "chart.png", bytes: 2_048)
        let document = try ingestor(text: nil, imageData: Data(repeating: 0x89, count: 2_048))
            .add(url: url)

        #expect(document.kind == .image)
        #expect(document.isUsable)
        #expect(document.imageData?.count == 2_048)
        #expect(document.text.isEmpty)
        #expect(document.summary.contains("KB") || document.summary.contains("bytes"))
    }

    @Test("An image with no data is refused")
    func refusesEmptyImage() throws {
        let url = try file(named: "broken.png")
        #expect(throws: DocumentError.self) { try ingestor(imageData: nil).add(url: url) }
    }
}

@Suite("Source material in the prompt")
struct AttachmentPromptTests {

    private func document(_ name: String, _ text: String) -> AttachedDocument {
        AttachedDocument(name: name, kind: .plainText, text: text)
    }

    @Test("Attached text is given to the models, delimited and named")
    func textReachesThePrompt() throws {
        let material = try #require(
            PromptBuilder.attachmentContext([
                document("study.md", "Ovoid shells resist point loads."),
                document("data.csv", "species,shape\nowl,spherical"),
            ]))
        #expect(material.contains("study.md"))
        #expect(material.contains("Ovoid shells resist point loads."))
        #expect(material.contains("--- BEGIN study.md ---"))
        #expect(material.contains("--- END data.csv ---"))
        // The models must know it is reference material and not a participant.
        #expect(material.contains("nobody said it"))
    }

    @Test("No attachments means no extra message")
    func noAttachmentsNoMessage() {
        #expect(PromptBuilder.attachmentContext([]) == nil)
        // An image carries no text, so it must not produce an empty section.
        let image = AttachedDocument(
            name: "chart.png", kind: .image, imageData: Data([0x1]))
        #expect(PromptBuilder.attachmentContext([image]) == nil)
        // Nor should a document whose text is blank.
        #expect(PromptBuilder.attachmentContext([document("empty.txt", "  ")]) == nil)
    }

    @Test("The prompt includes the source material in the one system message")
    func promptCarriesMaterial() {
        var spec = AgentSpec.seat(index: 0)
        spec.personaID = PersonaLibrary.neutral.id
        let conversation = Conversation(
            topic: "Egg shape",
            turns: [Turn(sequence: 1, speakerName: "Moderator", kind: .topic, content: "Egg shape")],
            attachments: [document("study.md", "Ovoid shells resist point loads.")])

        let prompt = PromptBuilder.prompt(
            for: spec, others: [AgentSpec.seat(index: 1)], conversation: conversation)
        // One system message, because the Qwen template refuses a second one; the material is
        // a section of it rather than a message of its own. See `PromptShapeTests`.
        let systemMessages = prompt.filter { $0.role == .system }
        #expect(systemMessages.count == 1, "the brief and the source material share one message")
        #expect(systemMessages.first?.content.contains("Ovoid shells resist point loads.") == true)
    }

    @Test("Attachments count towards the context estimate")
    func attachmentsCountTowardContext() {
        let long = AttachedDocument(
            name: "book.txt", kind: .plainText, text: String(repeating: "x", count: 40_000))
        #expect(PromptBuilder.attachmentCharacters([long]) == 40_000)
        // An image costs nothing here: it is not text, and its cost is the model's
        // business rather than a prompt-length matter.
        let image = AttachedDocument(name: "a.png", kind: .image, imageData: Data(repeating: 1, count: 900))
        #expect(PromptBuilder.attachmentCharacters([image]) == 0)
    }

    @Test("Attachments survive the context estimate being computed")
    @MainActor
    func engineCountsAttachments() {
        let specs = AgentSpec.makeSeats(count: 1)
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        let engine = ConversationEngine(
            seats: [.init(spec: specs[0], engine: RecordingStub(spec: specs[0]))],
            configuration: configuration)
        let before = engine.contextUsage.tokens
        // Material is added before the conversation starts, as the interface requires.
        #expect(
            engine.setAttachments([
                AttachedDocument(
                    name: "book.txt", kind: .plainText,
                    text: String(repeating: "x", count: 40_000))
            ]))
        engine.start(topic: "Eggs")
        #expect(engine.contextUsage.tokens > before + 9_000)
        #expect(engine.attachments.count == 1)
    }

    @Test("A conversation that has started refuses new material")
    @MainActor
    func refusesOnceRunning() async {
        let specs = AgentSpec.makeSeats(count: 1)
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        configuration.maxTurns = 1
        let engine = ConversationEngine(
            seats: [.init(spec: specs[0], engine: RecordingStub(spec: specs[0]))],
            configuration: configuration)
        engine.start(topic: "Eggs")
        await engine.waitUntilFinished()

        #expect(engine.setAttachments([document("late.txt", "too late")]) == false)
        #expect(engine.attachments.isEmpty)
    }
}

@Suite("Vision support")
struct VisionSupportTests {

    @Test("A local checkpoint is asked what it declares")
    func localCheckpoint() {
        // The 4B model on disk ships a vision tower, so its weights can accept images.
        let declared = ModelStore.declaresVision(for: AgentSpec.defaultModelID)
        #expect(declared == true, "this checkpoint declares a vision_config")

        // A model that is not on disk is unknown, not "no" — that distinction is what stops
        // the interface offering images on a guess.
        #expect(ModelStore.declaresVision(for: "some/model-not-downloaded") == nil)
    }

    @Test("A local seat without vision weights is unsupported")
    func localSeatUnsupported() {
        var spec = AgentSpec.seat(index: 0)
        spec.backend = .mlx
        spec.modelID = "some/definitely-not-here"
        // The local loader only knows text models, so this cannot be given an image.
        #expect(spec.visionSupport == .unsupported)
        #expect(!spec.visionSupport.allowsImages)
    }

    @Test("Recognised API model families are supported")
    func apiFamilies() {
        for id in ["gpt-4o-mini", "claude-sonnet-4", "gemini-2.5-pro", "llava-1.6", "qwen3-vl-8b"] {
            var spec = AgentSpec.seat(index: 0)
            spec.backend = .openAIResponses
            // Named where an API seat actually names its model. This test used to set the
            // checkpoint id instead, which stopped meaning anything once the endpoint's model
            // became what decides — the checkpoint id is not evidence about a server's model.
            spec.openAI = OpenAIEndpoint(baseURL: "https://example.test/v1", model: id)
            #expect(spec.visionSupport == .supported, "\(id) should be recognised")
        }
    }

    @Test("An unrecognised API model is unknown, so images are not offered")
    func unknownAPIModel() {
        var spec = AgentSpec.seat(index: 0)
        spec.backend = .openAIResponses
        spec.modelID = "some-local-server/my-finetune"
        #expect(spec.visionSupport == .unknown)
        #expect(!spec.visionSupport.allowsImages, "unknown must not mean yes")
    }

    @Test("An override settles it for a model that cannot be recognised")
    func overrideWins() {
        var spec = AgentSpec.seat(index: 0)
        spec.backend = .openAIResponses
        spec.modelID = "some-local-server/my-vlm"
        spec.visionOverride = .supported
        #expect(spec.visionSupport == .supported)

        spec.visionOverride = .unsupported
        #expect(spec.visionSupport == .unsupported)
    }
}
