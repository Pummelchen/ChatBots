// ChatBotsApp — reading the moderator's files
//
// The app target, because this is where the system's own converters are available: PDFKit
// for PDFs and `textutil` for the document formats. Using the system's converters is
// deliberate over hand-written parsers — `textutil` is part of macOS and has read Word,
// RTF, ODT and HTML for years, and a hand-rolled `.docx` unzipper would be a fraction as
// capable and a great deal more code to get wrong.

import ChatBotsCore
import Foundation
import PDFKit

/// Reads a plain text file, honouring a byte-order mark and falling back sensibly.
///
/// Markdown is included here: it is text, and converting it would strip the structure that
/// makes it useful to a model, so it is passed through as written.
struct PlainTextExtractor: DocumentExtracting {
    func extract(url: URL, kind: DocumentKind, limits: AttachmentLimits) throws -> AttachedDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DocumentError.unreadable(error.localizedDescription)
        }

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
    func fit(_ text: String, kind: DocumentKind, in limits: AttachmentLimits) -> AttachedDocument {
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
struct PDFTextExtractor: DocumentExtracting {
    func extract(url: URL, kind: DocumentKind, limits: AttachmentLimits) throws -> AttachedDocument {
        guard let document = PDFDocument(url: url) else {
            throw DocumentError.unreadable("the PDF could not be opened")
        }

        var pages: [String] = []
        var characters = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let pageText = page.string else { continue }
            // Stop reading once the budget is spent rather than extracting a whole
            // book to then throw most of it away.
            if characters + pageText.count > limits.maximumTextCharacters {
                pages.append(String(pageText.prefix(max(0, limits.maximumTextCharacters - characters))))
                characters = limits.maximumTextCharacters
                break
            }
            pages.append(pageText)
            characters += pageText.count
        }

        let text = pages.joined(separator: "\n\n")
        return AttachedDocument(
            name: "", kind: .pdf, text: text,
            pageCount: document.pageCount,
            wasTruncated: characters >= limits.maximumTextCharacters
        )
    }
}

/// Converts Word, RTF, ODT, HTML and WebArchive with the system's own converter.
struct TextutilExtractor: DocumentExtracting {
    func extract(url: URL, kind: DocumentKind, limits: AttachmentLimits) throws -> AttachedDocument {
        let result = try SystemProcess.run(
            "/usr/bin/textutil",
            ["-convert", "txt", "-stdout", "-encoding", "UTF-8", url.path]
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
struct ImageExtractor: DocumentExtracting {
    func extract(url: URL, kind: DocumentKind, limits: AttachmentLimits) throws -> AttachedDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DocumentError.unreadable(error.localizedDescription)
        }
        let lowered = url.pathExtension.lowercased()
        return AttachedDocument(
            name: "", kind: .image, text: "", byteCount: data.count, imageData: data
        ).withKindHint(lowered)
    }
}

private extension AttachedDocument {
    /// Images keep their kind; the hint exists only so a future format (HEIC, for instance)
    /// could be converted to a universally readable one at this point.
    func withKindHint(_ extension: String) -> AttachedDocument { self }
}

/// Runs a system tool and collects its output.
enum SystemProcess {
    struct Result {
        var status: Int32
        var output: Data
        var error: String
    }

    /// How long a conversion may take before it is killed. Generous, because a large Word
    /// document on a busy Mac is not a hang — but bounded, because a broken file should not
    /// freeze the interface.
    static let timeout: TimeInterval = 30

    static func run(_ executable: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // A tool that needs input must not inherit ours and wait on it.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw DocumentError.unreadable(error.localizedDescription)
        }

        // Read before waiting: a tool that fills the pipe buffer would otherwise block
        // forever, and the wait below would never return.
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            throw DocumentError.unreadable("the conversion took longer than \(Int(timeout)) seconds")
        }
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            output: outputData,
            error: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}

/// The extractors this app ships with.
enum SystemDocumentExtractor {
    static var ingestor: DocumentIngestor {
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
    static func add(
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
