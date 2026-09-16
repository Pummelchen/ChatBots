// ChatBotsCoreTests — a PDF's stored text respects the declared ceiling, and "shortened" means
// shortened
//
// Two faults in the same arithmetic. `wasTruncated = characters >= maximumTextCharacters` was
// true for a document whose text ended exactly on the ceiling and had lost nothing. And pages
// were joined with a blank line *after* the budget was applied, so the stored text exceeded
// `AttachmentLimits.maximumTextCharacters` by two characters per page boundary — by up to
// `2 × (pages − 1)`.
//
// The arithmetic now lives in `PDFTextBudget`, so it is tested directly, and a real two-page PDF
// written through Core Graphics checks the invariant end to end.

import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import ChatBotsCore

/// A real PDF containing one line of `text` per page, written through Core Graphics.
private func writePDF(to url: URL, pages: [String]) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw DocumentError.unreadable("could not create a PDF context")
    }
    let attributes: [NSAttributedString.Key: Any] = [
        .font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    ]
    for text in pages {
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
}

private func temporaryPDF(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "chatbots-pdf-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: name)
}

@Suite("A PDF's text ceiling means what it says")
struct ClientsDocumentTests {

    // MARK: - The arithmetic

    /// The off-by-one: text that ends exactly on the ceiling lost nothing, so it has not been
    /// shortened.
    @Test("Ending exactly on the ceiling is not truncation")
    func exactFillIsNotTruncation() {
        var budget = PDFTextBudget(maximum: 10)
        let accepted = budget.append("ABCDEFGHIJ")
        #expect(accepted)
        #expect(!budget.wasTruncated)
        #expect(budget.text == "ABCDEFGHIJ")
        #expect(budget.text.count == 10)
    }

    @Test("Text past the ceiling is cut to the ceiling and reports truncation")
    func overrunIsTruncated() {
        var budget = PDFTextBudget(maximum: 10)
        let accepted = budget.append("ABCDEFGHIJK")
        #expect(!accepted)
        #expect(budget.wasTruncated)
        #expect(budget.text == "ABCDEFGHIJ")
        #expect(budget.text.count == 10)
    }

    /// The separator is part of the stored text, so it has to be part of the budget. Three
    /// pages of two characters each fill a ten-character ceiling exactly once the two blank
    /// lines are counted — the case the old join overflowed.
    @Test("The blank line between pages counts against the ceiling")
    func separatorsAreCounted() {
        var budget = PDFTextBudget(maximum: 10)
        let first = budget.append("AB")
        let second = budget.append("CD")
        let third = budget.append("EF")
        #expect(first)
        #expect(second)
        #expect(third)
        #expect(budget.text == "AB\n\nCD\n\nEF")
        #expect(budget.text.count == 10)
        #expect(!budget.wasTruncated, "the text ends exactly on the ceiling")

        // No room for even the separator now, so the next page is dropped and reported.
        let fourth = budget.append("GH")
        #expect(!fourth)
        #expect(budget.wasTruncated)
        #expect(budget.text == "AB\n\nCD\n\nEF")
    }

    @Test("A page that would overflow the join is cut to fit")
    func overflowingPageIsCut() {
        var budget = PDFTextBudget(maximum: 10)
        let first = budget.append("AB")
        let second = budget.append("CDEFGHIJ")
        #expect(first)
        #expect(!second)
        #expect(budget.text == "AB\n\nCDEFGH")
        #expect(budget.text.count == 10)
        #expect(budget.wasTruncated)
    }

    /// The defect in miniature: two pages whose own lengths sum to the ceiling used to be
    /// joined into `ceiling + 2` stored characters.
    @Test("Two pages at the ceiling are stored at the ceiling")
    func twoPagesDoNotOverflow() {
        var budget = PDFTextBudget(maximum: 10)
        let first = budget.append("ABCDEF")
        let second = budget.append("GHIJKL")
        #expect(first)
        #expect(!second)
        #expect(budget.text.count == 10)
        #expect(budget.wasTruncated)
    }

    @Test("The stored text never exceeds the ceiling over a run of pages")
    func neverExceedsTheCeiling() {
        var budget = PDFTextBudget(maximum: 7)
        var appended = 0
        for page in ["abc", "defg", "hijkl", "mnopqr"] {
            if budget.append(page) { appended += 1 }
            #expect(
                budget.text.count <= 7,
                "stored \(budget.text.count) characters for a ceiling of 7")
        }
        #expect(appended > 0)
        #expect(budget.wasTruncated)
    }

    @Test("An empty page adds nothing and is not truncation")
    func emptyPagesAreIgnored() {
        var budget = PDFTextBudget(maximum: 10)
        let empty = budget.append("")
        let full = budget.append("ABCDEFGHIJ")
        #expect(empty)
        #expect(full)
        #expect(!budget.wasTruncated)
        #expect(budget.text == "ABCDEFGHIJ")
    }

    @Test("A zero ceiling stores nothing rather than crashing")
    func zeroCeiling() {
        var budget = PDFTextBudget(maximum: 0)
        let accepted = budget.append("A")
        #expect(!accepted)
        #expect(budget.wasTruncated)
        #expect(budget.text.isEmpty)
    }

    // MARK: - End to end, on a real PDF

    /// The invariant the entry is about, on a genuine two-page PDF: the stored text is within
    /// the declared ceiling. The limit is derived from the pages PDFKit actually returns, so
    /// the test does not depend on how many characters a trailing newline adds.
    @Test("A truncated two-page PDF is stored within its ceiling")
    func realPDFRespectsTheCeiling() throws {
        let url = try temporaryPDF("two-pages.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writePDF(to: url, pages: ["AAAA", "BBBB"])

        let pdf = try #require(PDFDocument(url: url))
        let pageTexts = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }
        #expect(pageTexts.count == 2, "the fixture must really have two text pages")
        let total = pageTexts.reduce(0) { $0 + $1.count }
        #expect(total > 2)

        var limits = AttachmentLimits.standard
        // One character short of the pages' own text, so the join has to shorten something.
        limits.maximumTextCharacters = total - 1

        let document = try SystemDocumentExtractor.ingestor.add(url: url, limits: limits)

        #expect(document.pageCount == 2)
        #expect(document.wasTruncated, "the second page had to be cut")
        #expect(
            document.text.count <= limits.maximumTextCharacters,
            "stored \(document.text.count) characters for a ceiling of \(limits.maximumTextCharacters)")
    }

    /// The other direction: a ceiling large enough for every page and the blank line between
    /// them must not be reported as shortened.
    @Test("A PDF that fits is not reported as shortened")
    func realPDFThatFits() throws {
        let url = try temporaryPDF("fits.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writePDF(to: url, pages: ["AAAA", "BBBB"])

        let pdf = try #require(PDFDocument(url: url))
        let total = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }
            .reduce(0) { $0 + $1.count }

        var limits = AttachmentLimits.standard
        // Room for both pages and the separator, exactly.
        limits.maximumTextCharacters = total + 2

        let document = try SystemDocumentExtractor.ingestor.add(url: url, limits: limits)

        #expect(!document.wasTruncated, "nothing was dropped, so nothing was shortened")
        #expect(document.text.count <= limits.maximumTextCharacters)
    }
}
