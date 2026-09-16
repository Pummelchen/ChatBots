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
// The extractors live beside this file, in `DocumentImport.swift`: that is where PDFKit and
// `/usr/bin/textutil` are used (`PDFTextExtractor`, `TextutilExtractor`, `SystemDocumentExtractor`).
// This file holds the shapes, the limits and the rules, which is the part that can be tested without
// a file on disk. (This used to say the extractors were defined in the app target, and there is no
// extractor there at all.)

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
    ///
    /// No extension appears twice, and every kind's list contains at least one extension that maps
    /// back to it. Both are asserted in `AttachmentTests`; the reason is that `.word` listed
    /// `rtf` and `rtfd` ahead of `.richText`, and `forExtension` takes the first match — so rich text
    /// was unreachable, an RTF file was labelled "Word", and the case, its label and its symbol were
    /// dead.
    public var extensions: [String] {
        switch self {
        case .plainText: ["txt", "text", "log", "csv", "tsv", "json", "xml", "yaml", "yml"]
        case .markdown: ["md", "markdown", "mdown"]
        case .pdf: ["pdf"]
        case .word: ["docx", "doc", "odt", "wordml"]
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
    /// not have, which is what made every chip read "0 words" / "Zero bytes".
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
    /// The API documentation lists png, jpeg, webp and gif. **BMP and TIFF are not
    /// in it**, and the intake path used to send them anyway. They are common
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
    /// A path that is not a regular file — a directory, a FIFO, a device.
    case notARegularFile(String)
    /// An image whose own metadata declares more pixels than this app will decode.
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
    /// measured. At the 64 MB
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

/// Holds the extractor a front end installed.
///
/// Extraction is installed rather than assumed: this module defines the shapes and the rules, and a
/// process that wants to accept documents has to say which extractor it uses before an upload gets
/// past the door. The extractor itself is in `DocumentImport.swift` — `SystemDocumentExtractor`,
/// which uses PDFKit and `/usr/bin/textutil` — and `chatbots-cli` is what installs it, for the server
/// it starts. (This used to say the core could not read a PDF or a Word file and that the extractors
/// were defined in the app target; both were false.) Until one is installed, uploads are refused with
/// a clear message rather than crashing.
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
