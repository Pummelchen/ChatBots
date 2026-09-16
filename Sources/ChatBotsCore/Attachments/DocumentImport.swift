// ChatBotsCore — reading the moderator's files
//
// In the core rather than a front end, so the SwiftUI app, the HTTP server and the web page
// all read a document the same way. There is one implementation of "what is in this PDF".
//
// It uses the system's own converters: PDFKit for PDFs and `textutil` for the document
// formats. That is deliberate over hand-written parsers — `textutil` is part of macOS and
// has read Word, RTF, ODT and HTML for years, and a hand-rolled `.docx` unzipper would be a
// fraction as capable and a great deal more code to get wrong.

import Darwin
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Reads a plain text file, honouring a byte-order mark and falling back sensibly.
///
/// Markdown is included here: it is text, and converting it would strip the structure that
/// makes it useful to a model, so it is passed through as written.
public struct PlainTextExtractor: DocumentExtracting {
    public func extract(data: Data, from url: URL, kind: DocumentKind, limits: AttachmentLimits) throws
        -> AttachedDocument
    {
        // The bytes were read once, by the ingestor, and bounded there.
        // UTF-8 first, then the encodings a Mac is most likely to meet. Latin-1 is last
        // because it accepts any byte, so it would mask a genuine encoding problem.
        let text =
            String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        return fit(text, kind: kind, in: limits)
    }

    /// Shared shortening, so every extractor applies the same budget and records it.
    ///
    /// `kind` is passed in rather than assumed: this serves both plain text and Markdown,
    /// and returning `.plainText` for a `.md` file would misreport what the moderator added.
    public func fit(_ text: String, kind: DocumentKind, in limits: AttachmentLimits) -> AttachedDocument {
        // Null bytes appear in files that are not really text; they confuse models and
        // serve no purpose here.
        let cleaned = text.replacingOccurrences(of: "\u{0}", with: "")
        if cleaned.count > limits.maximumTextCharacters {
            return AttachedDocument(
                name: "", kind: kind, text: String(cleaned.prefix(limits.maximumTextCharacters)),
                wasTruncated: true)
        }
        return AttachedDocument(name: "", kind: kind, text: cleaned)
    }
}

/// Reads a PDF's text layer.
public struct PDFTextExtractor: DocumentExtracting {
    public func extract(data: Data, from url: URL, kind: DocumentKind, limits: AttachmentLimits) throws
        -> AttachedDocument
    {
        // From the bytes rather than the path: `PDFDocument(url:)` would read the file a second time,
        // which is the read the ingestor has just bounded.
        guard let document = PDFDocument(data: data) else {
            throw DocumentError.unreadable("the PDF could not be opened")
        }

        var budget = PDFTextBudget(maximum: limits.maximumTextCharacters)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let pageText = page.string else { continue }
            // Stop reading once the budget is spent rather than extracting a whole book to
            // then throw most of it away.
            if !budget.append(pageText) { break }
        }

        return AttachedDocument(
            name: "", kind: .pdf, text: budget.text,
            pageCount: document.pageCount,
            wasTruncated: budget.wasTruncated
        )
    }
}

/// Accumulates a PDF's pages under the per-file character ceiling.
///
/// The ceiling is on the text that is actually **stored**, which is the pages joined by a blank
/// line, so the separator counts against the budget too. Joining after the fact let a document
/// at the limit be stored up to `2 × (pages − 1)` characters over the declared ceiling — the
/// exact amount being the separators the budget never accounted for. And `wasTruncated` was
/// `characters >= maximumTextCharacters`, which reported "shortened" for a document whose text
/// ended precisely on the ceiling and lost nothing; it is now set only when a page is cut or
/// dropped.
///
/// Separate from the extractor so the arithmetic can be tested without building a PDF. The
/// extractor still stops reading as soon as `append` returns false, so a whole book is not
/// extracted to be thrown away.
struct PDFTextBudget {
    private static let separator = "\n\n"

    private let maximum: Int
    private var count = 0
    /// The stored text, which never exceeds `maximum`.
    private(set) var text = ""
    /// True only when a page was cut or could not be added at all.
    private(set) var wasTruncated = false

    init(maximum: Int) { self.maximum = maximum }

    /// Add a page, and return false when there is no room for any more.
    ///
    /// An empty page adds nothing — not even a separator — so it neither counts as shortening
    /// nor consumes budget.
    mutating func append(_ pageText: String) -> Bool {
        guard !pageText.isEmpty else { return true }

        let separatorCount = text.isEmpty ? 0 : Self.separator.count
        let remaining = maximum - count - separatorCount
        if remaining <= 0 {
            wasTruncated = true
            return false
        }

        if !text.isEmpty { text += Self.separator }
        if pageText.count > remaining {
            text += String(pageText.prefix(remaining))
            count = maximum
            wasTruncated = true
            return false
        }
        text += pageText
        count += separatorCount + pageText.count
        return true
    }
}

/// Converts Word, RTF, ODT, HTML and WebArchive with the system's own converter.
public struct TextutilExtractor: DocumentExtracting {
    /// The one extractor that still works from the path: `textutil` is a system tool that takes a file,
    /// and staging the bytes to a temporary file to satisfy it would double the reading and writing for
    /// no gain. What bounds it is the same as before — its output is capped and it is killed if it
    /// overstays (`SystemProcess`) — and the input is a regular file the ingestor has already
    /// measured and read.
    public func extract(data: Data, from url: URL, kind: DocumentKind, limits: AttachmentLimits) throws
        -> AttachedDocument
    {
        let result = try SystemProcess.run(
            "/usr/bin/textutil",
            ["-convert", "txt", "-stdout", "-encoding", "UTF-8", url.path],
            timeout: SystemProcess.timeout,
            // The text this produces is what gets attached, so it is bounded by the same figure the
            // attachment is.
            maximumOutputBytes: limits.maximumFileBytes
        )
        guard result.status == 0 else {
            let reason = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DocumentError.unreadable(reason.isEmpty ? "\(kind.label) conversion failed" : reason)
        }
        // `textutil` writes UTF-8 with `-encoding UTF-8`; anything else would be surprising.
        guard let text = String(data: result.output, encoding: .utf8) else {
            throw DocumentError.unreadable("the converted text was not valid UTF-8")
        }
        return PlainTextExtractor().fit(text, kind: kind, in: limits)
    }
}

/// Reads an image's bytes, for seats that can see.
///
/// The bytes that are stored are the bytes that go on the wire, so this is where an image the
/// model cannot be given is either converted or refused. HEIC is the case that matters: it is
/// the default format of an iPhone photo and it is offered in the picker, but the Responses API
/// does not take it, so it used to be stored, pass `isUsable`, pass the vision gate, appear as
/// a chip — and then be dropped by the OpenAI backend with nothing logged or shown, while the
/// MLX backend read it fine. A silent, backend-dependent difference is the worst of the
/// options; converting here means both backends get bytes they can use, and an image that
/// cannot be converted is refused where the moderator can see the reason.
///
/// BMP and TIFF are the mirror case: the app used to *send* them as `image/bmp`
/// and `image/tiff`, which the API documentation does not list, so those
/// attachments were likely rejected with a 400. They are common — macOS writes TIFF and other
/// systems produce BMP — so this conversion path, not a refusal, is what handles them now.
public struct ImageExtractor: DocumentExtracting {
    public func extract(data: Data, from url: URL, kind: DocumentKind, limits: AttachmentLimits) throws
        -> AttachedDocument
    {
        // The bytes were read once, by the ingestor, and bounded there.
        let payload = try Self.wireRepresentation(
            of: data, filename: url.lastPathComponent, limits: limits)
        return AttachedDocument(
            name: "", kind: .image, text: "", byteCount: data.count, imageData: payload
        )
    }

    /// Refuse an image before it is decoded: not a format ImageIO knows, no size it will report, or
    /// more pixels than the cap allows.
    ///
    /// A byte cap cannot bound a decode, because the formats that need converting are compressed: a
    /// 663 KB TIFF can declare a canvas that decodes to 127 MB, and the same trick at the 64 MB byte cap
    /// is tens of gigabytes. ImageIO reports the declared size from the file's own metadata, so this is
    /// where the numbers are read and the answer is no — before `CreateImageAtIndex` allocates
    /// anything.
    ///
    /// Its own function rather than a block inside `wireRepresentation`, which was at swiftlint's
    /// complexity budget with these guards inline.
    static func validateImage(
        _ source: CGImageSource, properties: [CFString: Any]?, name: String,
        limits: AttachmentLimits
    ) throws {
        // A format ImageIO does not recognise at all is the file somebody's picker offered because of
        // its extension; a format it recognises but cannot measure is a damaged header. The two read
        // differently to whoever attached the file, so they are refused with different sentences.
        guard CGImageSourceGetType(source) != nil else {
            throw DocumentError.unreadable(
                "\(name) is not an image format a model can be given, and it could not be "
                    + "converted")
        }
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else {
            throw DocumentError.unreadable(
                "\(name) reports no usable dimensions, so it cannot be converted safely")
        }
        // `multipliedReportingOverflow` rather than `width * height`: a header may declare two enormous
        // numbers, and the product of those traps before any comparison can refuse it.
        let product = width.multipliedReportingOverflow(by: height)
        guard !product.overflow, product.partialValue <= limits.maximumImagePixels else {
            throw DocumentError.imageTooManyPixels(
                name, pixels: product.overflow ? Int.max : product.partialValue,
                limit: limits.maximumImagePixels)
        }
    }

    /// The image bytes as a type a model can be given, converting when the bytes are not one.
    ///
    /// Everything `AttachedDocument.mediaType(of:)` recognises is passed through untouched, so
    /// a PNG stays the PNG the moderator chose. Anything else is decoded with ImageIO — the
    /// same framework that reads HEIC, which is why the app can decode it even though the API
    /// will not take it — and re-encoded as PNG when the image has transparency and JPEG
    /// otherwise, both of which the API accepts. An image ImageIO cannot decode is refused with
    /// its name, which is the honest answer for a file whose extension claims to be a picture.
    static func wireRepresentation(
        of data: Data, filename: String, limits: AttachmentLimits
    ) throws -> Data {
        if AttachedDocument.mediaType(of: data) != nil { return data }

        let name = filename.isEmpty ? "the image" : filename
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DocumentError.unreadable(
                "\(name) is not an image format a model can be given, and it could not be "
                    + "converted")
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        try validateImage(source, properties: properties, name: name, limits: limits)

        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DocumentError.unreadable(
                "\(name) is not an image format a model can be given, and it could not be "
                    + "converted")
        }

        // Orientation is carried in the file, not in the pixels, and a re-encode that ignores
        // it hands the model a sideways picture. That is the normal iPhone case, not an edge
        // one: a portrait photo is stored landscape with an EXIF orientation, and the format
        // being converted here is the one iPhones write. `CreateImageAtIndex` deliberately
        // does not apply the tag, so an image that carries one is decoded through the thumbnail
        // path instead, which does — at the image's own longest side, so nothing is downscaled.
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let image: CGImage
        if orientation == 1 {
            image = decoded
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(decoded.width, decoded.height),
            ]
            image =
                CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? decoded
        }

        let hasAlpha = (properties?[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        let type: UTType = hasAlpha ? .png : .jpeg

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, type.identifier as CFString, 1, nil)
        else {
            throw DocumentError.unreadable(
                "\(name) could not be converted to \(type.preferredFilenameExtension ?? "an image")")
        }
        var encoding: [CFString: Any] = [:]
        if type == .jpeg {
            // The API's own ceiling is on bytes, and a photograph at 0.9 is visually the same
            // as the original for a model to read while being a fraction of a lossless copy.
            encoding[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        CGImageDestinationAddImage(destination, image, encoding as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw DocumentError.unreadable("\(name) could not be converted to a readable image")
        }

        let converted = output as Data
        // The converted bytes travel base64-encoded inside one message, and the protocol cap is
        // derived from `maximumFileBytes` for exactly that reason: a conversion that grew past
        // it would be accepted here and then refused on the wire.
        guard converted.count <= limits.maximumFileBytes else {
            throw DocumentError.tooLarge(name, limit: limits.maximumFileBytes)
        }
        return converted
    }
}

/// The extractors this app ships with.
public enum SystemDocumentExtractor {
    public static var ingestor: DocumentIngestor {
        let text = PlainTextExtractor()
        let pdf = PDFTextExtractor()
        let documents = TextutilExtractor()
        let image = ImageExtractor()
        return DocumentIngestor(extractors: [
            .plainText: text,
            .markdown: text,
            .pdf: pdf,
            .word: documents,
            .richText: documents,
            .html: documents,
            .image: image,
        ])
    }

    /// Add files, keeping the ones that worked and describing the ones that did not.
    ///
    /// One bad file should not discard the good ones, so this reports per file.
    public static func add(
        urls: [URL], limits: AttachmentLimits = .standard
    ) -> (documents: [AttachedDocument], failures: [String]) {
        var documents: [AttachedDocument] = []
        var failures: [String] = []
        for url in urls {
            do {
                documents.append(try ingestor.add(url: url, limits: limits))
            } catch let error as DocumentError {
                failures.append(error.errorDescription ?? "\(url.lastPathComponent) could not be read.")
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (documents, failures)
    }
}
