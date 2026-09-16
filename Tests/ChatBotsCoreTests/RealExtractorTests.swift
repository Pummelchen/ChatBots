// ChatBotsCoreTests — the extractors against real files
//
// The PDF and Office paths talk to PDFKit and `textutil`, so fakes prove nothing about
// them. These build genuine files — a real PDF written through Core Graphics, a real .docx
// produced by the system converter — and assert what comes back out.

import AppKit
import ChatBotsCore
import CoreGraphics
import CoreText
import Foundation
import Testing

private let scratch = FileManager.default.temporaryDirectory
    .appending(path: "chatbots-extract-\(UUID().uuidString)")

private func scratchFile(_ name: String) throws -> URL {
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    return scratch.appending(path: name)
}

/// A real single-page PDF containing `text`, written through Core Graphics.
private func writePDF(to url: URL, text: String) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw DocumentError.unreadable("could not create a PDF context")
    }
    context.beginPDFPage(nil)
    // The text layer is what extraction reads, and Core Graphics writes one.
    let attributes: [NSAttributedString.Key: Any] = [
        .font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes))
    context.textPosition = CGPoint(x: 40, y: 700)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
}

@Suite("Real extractors")
struct RealExtractorTests {

    @Test("A plain text file is read, including non-ASCII")
    func plainText() throws {
        let url = try scratchFile("notes.txt")
        try "Grüße! café 日本語 🥚".write(to: url, atomically: true, encoding: .utf8)

        let document = try SystemDocumentExtractor.ingestor.add(url: url)
        #expect(document.text.contains("Grüße"))
        #expect(document.text.contains("日本語"))
        #expect(document.text.contains("🥚"))
        #expect(document.kind == .plainText)
    }

    @Test("Markdown is passed through as written, not converted")
    func markdownIsNotConverted() throws {
        let url = try scratchFile("readme.md")
        let markdown = "# Heading\n\n- item\n\n```swift\nlet x = 1\n```\n"
        try markdown.write(to: url, atomically: true, encoding: .utf8)

        let document = try SystemDocumentExtractor.ingestor.add(url: url)
        // Structure is valuable to a model, so it is deliberately not stripped.
        #expect(document.text.contains("# Heading"))
        #expect(document.text.contains("```swift"))
        #expect(document.kind == .markdown)
    }

    @Test("A real PDF's text layer is extracted")
    func pdfText() throws {
        let url = try scratchFile("paper.pdf")
        try writePDF(to: url, text: "Eggs are ovoid because of the shell.")

        let document = try SystemDocumentExtractor.ingestor.add(url: url)
        #expect(document.kind == .pdf)
        #expect(document.pageCount == 1)
        #expect(
            document.text.contains("Eggs are ovoid"),
            "PDFKit should read the text layer, got: \(document.text)")
    }

    @Test("A PDF with no text layer is reported as needing OCR")
    func scannedPDFNeedsOCR() throws {
        let url = try scratchFile("blank.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        // A page with no text at all stands in for a scan.
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()

        do {
            _ = try SystemDocumentExtractor.ingestor.add(url: url)
            Issue.record("expected the blank PDF to be refused")
        } catch let error as DocumentError {
            #expect(error == .needsOCR("blank.pdf"))
        }
    }

    @Test("A real .docx is converted to plain text")
    func docxConversion() throws {
        // Built with the system converter, which is also what reads it back.
        let source = try scratchFile("source.txt")
        try "Word document body with ünïcode.".write(to: source, atomically: true, encoding: .utf8)
        let docx = try scratchFile("report.docx")
        let result = try SystemProcess.run(
            "/usr/bin/textutil", ["-convert", "docx", "-output", docx.path, source.path])
        try #require(result.status == 0, "could not build a test .docx")
        try #require(FileManager.default.fileExists(atPath: docx.path))

        let document = try SystemDocumentExtractor.ingestor.add(url: docx)
        #expect(document.kind == .word)
        #expect(document.text.contains("Word document body"))
        #expect(document.text.contains("ünïcode"))
    }

    @Test("A real .rtf is converted to plain text")
    func rtfConversion() throws {
        let source = try scratchFile("source2.txt")
        try "Rich text body.".write(to: source, atomically: true, encoding: .utf8)
        let rtf = try scratchFile("doc.rtf")
        let result = try SystemProcess.run(
            "/usr/bin/textutil", ["-convert", "rtf", "-output", rtf.path, source.path])
        try #require(result.status == 0)

        let document = try SystemDocumentExtractor.ingestor.add(url: rtf)
        // Rich text, not Word: the kind decides the chip's label and symbol, and `.word` used to claim
        // `rtf` first. Through the real extractor, on a real file, so this is the user-visible
        // half of that finding rather than a rule about a list.
        #expect(document.kind == .richText)
        #expect(document.kind.label == "Rich text")
        #expect(document.text.contains("Rich text body."))
    }

    @Test("An image is read as bytes and produces no text")
    func image() throws {
        let url = try scratchFile("chart.png")
        // A real 1x1 PNG, so the bytes are a genuine image.
        let png = Data(
            base64Encoded: """
                iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
                """)!
        try png.write(to: url)

        let document = try SystemDocumentExtractor.ingestor.add(url: url)
        #expect(document.kind == .image)
        #expect(document.imageData?.count == png.count)
        #expect(document.text.isEmpty)
        #expect(document.isUsable)
    }

    @Test("Several files are added, and one bad file does not discard the good ones")
    func batchAddKeepsGoodFiles() throws {
        let good = try scratchFile("good.txt")
        try "Kept.".write(to: good, atomically: true, encoding: .utf8)
        let bad = try scratchFile("bad.xyz")
        try "nope".write(to: bad, atomically: true, encoding: .utf8)
        let empty = try scratchFile("empty.txt")
        try "   ".write(to: empty, atomically: true, encoding: .utf8)

        let result = SystemDocumentExtractor.add(urls: [good, bad, empty])
        #expect(result.documents.count == 1)
        #expect(result.documents.first?.text.contains("Kept.") == true)
        #expect(result.failures.count == 2, "both refusals should be reported")
        #expect(result.failures.contains { $0.contains("bad.xyz") })
        #expect(result.failures.contains { $0.contains("empty.txt") })
    }

    @Test("The size limit is enforced for real files")
    func enforcesSizeLimit() throws {
        let url = try scratchFile("big.txt")
        try Data(repeating: 0x41, count: 20_000).write(to: url)
        var limits = AttachmentLimits.standard
        limits.maximumFileBytes = 1_000

        do {
            _ = try SystemDocumentExtractor.ingestor.add(url: url, limits: limits)
            Issue.record("expected the size limit to refuse this file")
        } catch let error as DocumentError {
            if case .tooLarge = error {} else { Issue.record("wrong error: \(error)") }
        }
    }

    @Test("A large text file is shortened to fit, and says so")
    func truncatesRealFile() throws {
        let url = try scratchFile("long.txt")
        try String(repeating: "egg ", count: 20_000).write(to: url, atomically: true, encoding: .utf8)
        var limits = AttachmentLimits.standard
        limits.maximumTextCharacters = 5_000

        let document = try SystemDocumentExtractor.ingestor.add(url: url, limits: limits)
        #expect(document.text.count == 5_000)
        #expect(document.wasTruncated)
    }
}
