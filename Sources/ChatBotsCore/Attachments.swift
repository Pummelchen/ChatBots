// ChatBotsCore — documents and images the moderator adds before a conversation starts
//
// Two quite different things arrive through the same door:
//
//   * **Documents** (PDF, txt, md, docx, rtf, html…) are converted to plain text. This is
//     not merely convenient, it is the cheaper path by a wide margin: a page of text costs
//     a few hundred tokens, while the same page as an image costs thousands and needs a
//     vision model to read it. Extracting first means any seat can use it, including seats
//     that cannot see.
//   * **Images** can only be used by seats that support vision, so they are offered only
//     when *every* participating seat does. A conversation where one participant cannot see
//     the picture is worse than being told upfront that images are unavailable.
//
// The extractors themselves live in the app target, which can use PDFKit and `textutil`;
// this file holds the shapes and the rules, so they can be tested.

import Foundation

/// A file format the moderator can add.
public enum DocumentKind: String, CaseIterable, Sendable, Codable {
    case plainText
    case markdown
    case pdf
    case word
    case richText
    case html
    case image

    /// Extensions offered in the open panel, per kind.
    public var extensions: [String] {
        switch self {
        case .plainText: ["txt", "text", "log", "csv", "tsv", "json", "xml", "yaml", "yml"]
        case .markdown: ["md", "markdown", "mdown"]
        case .pdf: ["pdf"]
        case .word: ["docx", "doc", "odt", "rtf", "rtfd", "wordml"]
        case .richText: ["rtf", "rtfd"]
        case .html: ["html", "htm", "webarchive"]
        case .image: ["png", "jpg", "jpeg", "bmp", "gif", "tiff", "tif", "heic", "webp"]
        }
    }

    public var isImage: Bool { self == .image }

    /// What to call it in the interface.
    public var label: String {
        switch self {
        case .plainText: "Text"
        case .markdown: "Markdown"
        case .pdf: "PDF"
        case .word: "Word"
        case .richText: "Rich text"
        case .html: "HTML"
        case .image: "Image"
        }
    }

    /// The symbol shown on the attachment chip.
    public var symbol: String {
        switch self {
        case .plainText: "doc.text"
        case .markdown: "text.document"
        case .pdf: "doc.richtext"
        case .word: "doc.text.fill"
        case .richText: "doc.rtf"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        }
    }

    public static func forExtension(_ ext: String) -> DocumentKind? {
        let lowered = ext.lowercased()
        return allCases.first { $0.extensions.contains(lowered) }
    }

    /// Infer from a filename, for files arriving from the open panel or a drop.
    public static func forFilename(_ name: String) -> DocumentKind? {
        forExtension((name as NSString).pathExtension)
    }

    /// Every plain-text extension, for the open panel's allowed types.
    public static var documentExtensions: [String] {
        allCases.filter { !$0.isImage }.flatMap(\.extensions)
    }

    public static var imageExtensions: [String] {
        DocumentKind.image.extensions
    }
}

/// A document the moderator added, with its text extracted once.
///
/// The text is kept rather than the path: extraction is the expensive step, the file may be
/// edited or deleted afterwards, and the extract is what actually goes into the prompt.
public struct AttachedDocument: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public var name: String
    public var kind: DocumentKind
    /// The extracted plain text. Empty for an image, which is sent as an image.
    public var text: String
    /// Bytes of the original file, for display.
    public var byteCount: Int
    /// Pages or sheets, when the format has them.
    public var pageCount: Int?
    /// True when the text was shortened to fit the context budget.
    public var wasTruncated: Bool
    /// For an image: the encoded bytes, ready to send.
    public var imageData: Data?
    public var addedAt: Date

    /// The engine's own description of what it read, when this document was rebuilt from the
    /// engine rather than extracted here.
    ///
    /// `summary` and `estimatedTokens` are computed from `text`, `byteCount` and `pageCount`,
    /// and a client is deliberately not sent the extracted text — it is the engine's, it can be
    /// huge, and sending it back would be a second copy that could disagree. So a rebuilt
    /// document carries the engine's figures instead of recomputing them from fields it does
    /// not have, which is what made every chip read "0 words" / "Zero bytes" (audit A46).
    /// Extraction on this side leaves these nil and the computed values are used.
    public var engineSummary: String?
    /// The engine's own token estimate, for the same reason as `engineSummary`.
    public var engineTokens: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: DocumentKind,
        text: String = "",
        byteCount: Int = 0,
        pageCount: Int? = nil,
        wasTruncated: Bool = false,
        imageData: Data? = nil,
        addedAt: Date = Date.now,
        engineSummary: String? = nil,
        engineTokens: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.text = text
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.wasTruncated = wasTruncated
        self.imageData = imageData
        self.addedAt = addedAt
        self.engineSummary = engineSummary
        self.engineTokens = engineTokens
    }

    /// Approximate tokens, at the four-characters-per-token rule used elsewhere.
    ///
    /// The engine's figure when it was measured there, because a rebuilt document has no
    /// `text` to count here. See `engineTokens`.
    public var estimatedTokens: Int { engineTokens ?? max(0, text.count / 4) }

    /// A short description for the chip: "12 pages · 4.2k words".
    ///
    /// The engine's own description when this document was rebuilt from it, for the reason in
    /// `engineSummary`: without the text, byte count and pages there is nothing here to
    /// describe.
    public var summary: String {
        if let engineSummary { return engineSummary }
        var parts: [String] = []
        if let pageCount, pageCount > 1 { parts.append("\(pageCount) pages") }
        if kind.isImage {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
        } else {
            let words = text.split { $0.isWhitespace || $0.isNewline }.count
            parts.append("\(words) words")
            if wasTruncated { parts.append("shortened") }
        }
        return parts.joined(separator: " · ")
    }

    /// Text that cannot be understood by a model is not worth sending.
    public var isUsable: Bool {
        kind.isImage ? (imageData?.isEmpty == false) : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension AttachedDocument {
    /// The image media types the Responses API documents, and the only ones this app sends.
    ///
    /// A52's lane checked the API documentation: png, jpeg, webp and gif. **BMP and TIFF are not
    /// in it** (audit A101), and the intake path used to send them anyway. They are common
    /// enough to keep offering — macOS itself writes TIFF, and screenshots from other systems
    /// are BMP — so they are *converted* at intake, exactly as HEIC is, and never put on the
    /// wire under a type the API may reject.
    ///
    /// This is the one list the sniffer and the sender share, so "what this app describes to a
    /// model" and "what the API accepts" cannot drift apart. The picker's list in
    /// `DocumentKind.image.extensions` is deliberately **wider** and cannot be the same list:
    /// it is "what ImageIO can read and convert", not "what the API takes", and the whole point
    /// of intake is that those differ.
    public static let acceptedImageMediaTypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/webp",
        "image/gif",
    ]

    /// The media type for image bytes, from the bytes rather than the filename.
    ///
    /// The extension can lie — a `.png` that is really a JPEG is common — and servers
    /// validate the declared type, so the magic bytes are what is believed. `nil` means the
    /// bytes are not a type the API accepts: the intake path converts what it can (HEIC, BMP,
    /// TIFF) into one of `acceptedImageMediaTypes` and refuses the rest, so `nil` never reaches
    /// a request silently.
    public static func mediaType(of data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46],
            bytes[8..<12] == [0x57, 0x45, 0x42, 0x50]
        {
            return "image/webp"
        }
        // BMP (42 4D) and TIFF (49 49 2A 00 / 4D 4D 00 2A) are deliberately **not** returned:
        // they are readable by ImageIO, so intake converts them to PNG or JPEG, but they are
        // not types the Responses API documents and must not be declared on the wire.
        return nil
    }

    /// The media type for an attached image.
    public var imageMediaType: String? {
        guard kind.isImage, let data = imageData else { return nil }
        return Self.mediaType(of: data)
    }

    /// The image as base64, for an API that takes a data URL.
    public var imageBase64: String? { imageData?.base64EncodedString() }
}

/// Why a file could not be added.
public enum DocumentError: LocalizedError, Equatable {
    case unsupportedType(String)
    case unreadable(String)
    case emptyText(String)
    case needsOCR(String)
    case tooLarge(String, limit: Int)
    /// A path that is not a regular file — a directory, a FIFO, a device (A149).
    case notARegularFile(String)
    /// An image whose own metadata declares more pixels than this app will decode (A148).
    case imageTooManyPixels(String, pixels: Int, limit: Int)
    case imageNotAllowed

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let name):
            "\(name) is not a format this app can read."
        case .unreadable(let reason):
            "Could not read the file: \(reason)"
        case .emptyText(let name):
            "\(name) contains no readable text."
        case .needsOCR(let name):
            "\(name) has no text layer — it looks like a scan, so its text cannot be extracted."
        case .tooLarge(let name, let limit):
            "\(name) is larger than \(limit / 1_000_000) MB."
        case .notARegularFile(let name):
            "\(name) is not a regular file, so it cannot be read as a document."
        case .imageTooManyPixels(let name, let pixels, let limit):
            "\(name) is about \(pixels / 1_000_000) megapixels; images are limited to "
                + "\(limit / 1_000_000) MP. Resize it first."
        case .imageNotAllowed:
            "Images need every participating seat to support vision."
        }
    }
}

/// How much of a document is kept.
public struct AttachmentLimits: Sendable {
    /// Per-file ceiling on the extracted text, in characters.
    ///
    /// A guard against one enormous file consuming the whole context window before a
    /// conversation starts. At roughly four characters per token this is about 30k tokens
    /// — sizeable but well inside the window, leaving room for the discussion itself.
    public var maximumTextCharacters: Int = 120_000
    /// Refuse files larger than this outright, since reading them is the slow part.
    public var maximumFileBytes: Int = AttachmentLimits.defaultMaximumFileBytes

    /// The largest image, in pixels, that will be decoded while being converted.
    ///
    /// A byte cap cannot bound a decode, because the formats that need converting are compressed: PNG
    /// and TIFF are, and a 663 KB file can declare a 6 500 × 6 500 canvas that decodes to 127 MB —
    /// measured, with the numbers in `AUDIT/baseline/swift64/a148-image-decode-bomb.log`. At the 64 MB
    /// byte cap that is tens of gigabytes, which is why the dimensions are read from the file's own
    /// metadata and refused before anything is decoded.
    ///
    /// 40 MP is more than twice a 20 MP camera, and a vision model downscales to a small fraction of
    /// it anyway. Images that need no conversion are not decoded here at all — they are passed through
    /// as they arrived, and the byte cap is what bounds them.
    public var maximumImagePixels: Int = AttachmentLimits.defaultMaximumImagePixels

    /// The shipped per-file ceiling, and the figure the wire limits are derived from.
    ///
    /// A named constant rather than a literal repeated in the initialiser, because
    /// `ProtocolLimits` has to cover the base64 form of this many bytes and
    /// `HTTPParser.maximumBodyBytes` has to cover the same request: three literals that must
    /// agree did not agree, and the documented limit was unreachable over both transports.
    public static let defaultMaximumFileBytes = 64 * 1024 * 1024

    /// The shipped ceiling on how many pixels an image may declare before it is decoded.
    public static let defaultMaximumImagePixels = 40 * 1_000_000

    public init(
        maximumTextCharacters: Int = 120_000,
        maximumFileBytes: Int = AttachmentLimits.defaultMaximumFileBytes,
        maximumImagePixels: Int = AttachmentLimits.defaultMaximumImagePixels
    ) {
        self.maximumTextCharacters = maximumTextCharacters
        self.maximumFileBytes = maximumFileBytes
        self.maximumImagePixels = maximumImagePixels
    }

    public static let standard = AttachmentLimits()
}

/// Reads one document and returns its text or image bytes.
///
/// A protocol so the app can supply the real extractors while tests supply fakes, and so a
/// future format is one more implementation rather than a change here.
///
/// **The bytes, not a path (A149).** The ingestor reads the file once, refuses anything that is not a
/// regular file, and refuses anything over the byte cap *as it is reading* — so what an extractor is
/// given is what has already been bounded. Handing over the path instead is what made the cap
/// unenforceable: the size came from a separate `stat`, so an unreadable one meant a cap of zero, a
/// file that grew between the two calls was read in full, and a FIFO — which has no size and never
/// ends — hung the conversion forever.
///
/// `url` still travels alongside, for the one extractor that hands a path to a system tool.
public protocol DocumentExtracting: Sendable {
    func extract(data: Data, from url: URL, kind: DocumentKind, limits: AttachmentLimits) throws
        -> AttachedDocument
}

/// Holds the extractor a front end installed.
///
/// The core cannot read a PDF or a Word file itself — that needs PDFKit and `textutil`, which
/// belong to the app target — so the front end installs an ingestor here at launch and the
/// API uses it. Until one is installed, uploads are refused with a clear message rather than
/// crashing.
public enum DocumentIngestorProvider {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var installed: DocumentIngestor?

    public static func install(_ ingestor: DocumentIngestor) {
        lock.lock()
        defer { lock.unlock() }
        installed = ingestor
    }

    public static var ingestor: DocumentIngestor {
        get throws {
            lock.lock()
            defer { lock.unlock() }
            guard let installed else {
                throw DocumentError.unreadable(
                    "this server was started without document support")
            }
            return installed
        }
    }
}

/// Chooses an extractor per kind, and holds the shared rules — size limits and the
/// blank-result check — so no individual extractor has to remember them.
///
/// `@unchecked Sendable` because there is no mutable state to confine, so there is no lock,
/// actor or queue to name: both stored properties are `let` and nothing in the type writes
/// them. `extractors` is a dictionary of `DocumentExtracting`, which is `Sendable`, and the
/// shared `FileManager` is only ever read through `attributesOfItem(atPath:)`. What keeps it
/// true is that the type declares no `var` and exposes no setter, so `let` immutability is the
/// whole of the confinement — there is no second access site a comment could disagree with.
public final class DocumentIngestor: @unchecked Sendable {
    private let extractors: [DocumentKind: any DocumentExtracting]
    private let fileManager: FileManager

    public init(
        extractors: [DocumentKind: any DocumentExtracting],
        fileManager: FileManager = .default
    ) {
        self.extractors = extractors
        self.fileManager = fileManager
    }

    /// Add a file. Throws `DocumentError` with something the moderator can act on.
    public func add(url: URL, limits: AttachmentLimits = .standard) throws -> AttachedDocument {
        let name = url.lastPathComponent
        guard let kind = DocumentKind.forFilename(name) else {
            throw DocumentError.unsupportedType(name)
        }
        guard let extractor = extractors[kind] ?? extractors.first(where: { $0.key.extensions.contains(kind.extensions.first ?? "") })?.value
        else {
            throw DocumentError.unsupportedType(name)
        }

        // The stat is required, and it has to say "regular file" (A149). A failed stat used to mean a
        // size of zero, which meant a cap of zero; a FIFO or a device has no size and never reaches an
        // end, so a conversion from one either hung or ran unbounded.
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            throw DocumentError.unreadable("\(name)'s size could not be read")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DocumentError.notARegularFile(name)
        }
        if let size = (attributes[.size] as? NSNumber)?.intValue, size > limits.maximumFileBytes {
            throw DocumentError.tooLarge(name, limit: limits.maximumFileBytes)
        }

        // One read, bounded by the cap. The stat above is a courtesy — it refuses an obviously large
        // file without opening it — but *this* is the check that binds: a file that grew after the stat,
        // or one whose size the stat did not report, cannot be read past the limit, and the extractor
        // receives only bytes that were counted.
        let data = try Self.readBounded(url: url, name: name, limit: limits.maximumFileBytes)

        var document = try extractor.extract(data: data, from: url, kind: kind, limits: limits)
        document.name = name
        document.byteCount = data.count

        guard document.isUsable else {
            // An image with no bytes is a read failure; a document with no text is either
            // empty or a scan, and saying which is the difference between "pick another
            // file" and "this needs OCR".
            if kind == .pdf {
                throw DocumentError.needsOCR(name)
            }
            throw DocumentError.emptyText(name)
        }
        return document
    }

    /// A file's bytes, stopping one byte past the limit rather than reading whatever is there.
    ///
    /// `Data(contentsOf:)` is the wrong tool here: it reads to the end of whatever it was given, which
    /// for a special file is either forever or unbounded. This reads in chunks and refuses as soon as
    /// the limit is passed, so the ceiling is a property of the read rather than of a previous `stat`
    /// that could be raced (A149). The file is a regular file by the time this runs — the caller has
    /// checked — so the read terminates.
    static func readBounded(url: URL, name: String, limit: Int) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw DocumentError.unreadable("\(name) could not be opened")
        }
        defer { try? handle.close() }

        var data = Data()
        // A chunk size rather than one call: `read(upToCount:)` returns what is available, so a file
        // larger than the limit arrives in pieces and the check below happens on each of them.
        while data.count <= limit {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= limit else {
            throw DocumentError.tooLarge(name, limit: limit)
        }
        return data
    }
}

// MARK: - Whether a seat can see

/// Whether a seat's model can accept images.
///
/// This gates the image part of the interface: images are offered only when *every*
/// participating seat supports vision, because a discussion where one participant cannot
/// see the picture is worse than being told upfront that images are unavailable. Text
/// documents have no such restriction — extraction is exactly what makes them universally
/// usable.
public enum VisionSupport: String, Sendable, Codable {
    /// The model is known to accept images.
    case supported
    /// The model is known not to, or is a local checkpoint with no vision tower.
    case unsupported
    /// Nothing is known and nothing could be found out, so the interface does not offer it.
    case unknown

    public var allowsImages: Bool { self == .supported }
}

extension AgentSpec {
    /// Model families known to accept images, matched case-insensitively against the model
    /// id. A server does not advertise this through `/v1/models`, so it has to be known — and
    /// when it is not, the answer is `unknown` rather than a hopeful `supported`.
    private static let visionModelMarkers = [
        "gpt-4o", "gpt-4.1", "gpt-4-turbo", "gpt-5", "o3", "o4",
        "claude-3", "claude-4", "claude-opus", "claude-sonnet", "claude-haiku",
        "gemini", "llava", "qwen-vl", "qwen2-vl", "qwen2.5-vl", "qwen3-vl", "qwen3.5-vl",
        "pixtral", "internvl", "minicpm-v", "moondream", "paligemma", "idefics",
        "smolvlm", "gemma-3", "gemma3", "mistral-small-3", "glm-4v", "glm-4.5v",
        // DeepSeek's flash tier sees images. Verified against the live API: asked to name
        // the shape and colour in a test image it answered "Green triangle.", and its own
        // reasoning read "The image shows a green triangle."
        //
        // Deliberately only the flash tier. The pro tier was asked the same question and
        // replied "Cannot see image.", so listing the family would have been wrong in the
        // other direction — it would offer images on a seat that cannot read them.
        "deepseek-flash",
    ]

    /// What this seat's model can accept.
    ///
    /// For a local checkpoint the answer comes from the checkpoint itself, which is
    /// authoritative. For an API seat it comes from a configured override first — since a
    /// server that is *not* serving the model on this disk is the only case where nothing
    /// authoritative exists — then from the checkpoint if it happens to be here, then from
    /// the model id's family.
    public var visionSupport: VisionSupport {
        if backend == .mlx {
            // The local loader only knows text models, so a checkpoint with no vision tower
            // cannot be given an image however it is asked.
            guard ModelStore.declaresVision(for: modelID) == true else { return .unsupported }
            return .supported
        }
        if let override = visionOverride { return override }

        // The endpoint's model comes first, and the order matters.
        //
        // An API seat names the model it is asking the server for, and that name is the only
        // evidence about what will answer. Asking about the local checkpoint instead was the
        // original bug in a different guise: this build's default checkpoint is the same
        // Qwen3.5 whose weights here include a vision tower, so `declaresVision` returned
        // true for a seat pointed at a text-only server model, and images were offered on the
        // strength of weights that seat would never load.
        if !openAI.model.isEmpty {
            let name = openAI.model.lowercased()
            return Self.visionModelMarkers.contains { name.contains($0) } ? .supported : .unknown
        }

        // No endpoint model named, so the checkpoint is the only thing left to go on.
        if let declared = ModelStore.declaresVision(for: modelID) {
            return declared ? .supported : .unsupported
        }
        let name = modelID.lowercased()
        return Self.visionModelMarkers.contains { name.contains($0) } ? .supported : .unknown
    }
}

extension ModelStore {
    /// Whether a checkpoint on disk declares a vision tower.
    ///
    /// Returns nil when the checkpoint is not here, which is different from "no": for an API
    /// seat pointing at a model this app has never seen, the honest answer is that nothing is
    /// known, and the interface should not offer images on a guess.
    public static func declaresVision(for modelID: String, in root: URL? = nil) -> Bool? {
        guard let directory = localCheckpoint(for: modelID, in: root) else { return nil }
        let config = directory.appending(path: "config.json")
        guard let data = try? Data(contentsOf: config),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // The multimodal wrapper puts the vision tower beside the text config; a
        // text-only checkpoint has neither, so its absence is a definite "no".
        if let vision = parsed["vision_config"] as? [String: Any], !vision.isEmpty { return true }
        if parsed["image_token_id"] != nil || parsed["vision_start_token_id"] != nil { return true }
        if let text = parsed["text_config"] as? [String: Any] {
            if let vision = text["vision_config"] as? [String: Any], !vision.isEmpty { return true }
            if text["image_token_id"] != nil { return true }
        }
        return false
    }
}
