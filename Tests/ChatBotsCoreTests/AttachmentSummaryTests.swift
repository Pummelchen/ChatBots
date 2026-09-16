// ChatBotsCoreTests — a rebuilt document carries the engine's own figures
//
// The app shows each attachment's `summary` (and, inside the extract popover, its
// `estimatedTokens`). Both are computed from `text`, `byteCount` and `pageCount`, and a client
// is deliberately not sent the extracted text, so a document rebuilt from `APISnapshot`
// reported "0 words" — or "Zero bytes" for an image — on every chip. The engine's
// own description travels in `APIAttachment.summary`/`.tokens`; `AttachedDocument` now carries
// those as `engineSummary`/`engineTokens`.
//
// The app's rebuild site is in the `ChatBots` executable, which this target cannot import, so
// these tests pin the contract it depends on: the engine's figures win when present, local
// extraction still computes its own, and both survive the settings round-trip.

import ChatBotsCore
import Foundation
import Testing

@Suite("Attachment summary from the engine")
struct AttachmentSummaryTests {

    @Test("A rebuilt document reports the engine's summary and token count, not zero")
    func engineFiguresAreUsed() {
        // Exactly how ChatController rebuilds one: no text, no bytes, no pages.
        let document = AttachedDocument(
            name: "thesis.pdf",
            kind: .pdf,
            text: "",
            byteCount: 0,
            pageCount: nil,
            wasTruncated: true,
            engineSummary: "12 pages · 4200 words · shortened",
            engineTokens: 12_345)

        #expect(document.summary == "12 pages · 4200 words · shortened")
        #expect(document.estimatedTokens == 12_345)
        // The bug being fixed: recomputing here would have produced exactly this instead.
        let withoutEngineFigures = AttachedDocument(
            name: "thesis.pdf", kind: .pdf, text: "", wasTruncated: true)
        #expect(withoutEngineFigures.summary == "0 words · shortened")
        #expect(document.summary != withoutEngineFigures.summary)
    }

    @Test("A rebuilt image reports its real size rather than zero bytes")
    func engineFigureIsUsedForAnImage() {
        let document = AttachedDocument(
            name: "diagram.png",
            kind: .image,
            text: "",
            byteCount: 0,
            imageData: Data([0x89, 0x50, 0x4E, 0x47]),
            engineSummary: "1.2 MB",
            engineTokens: 0)

        #expect(document.summary == "1.2 MB")
        #expect(document.summary != ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
    }

    @Test("With no engine description the locally extracted figures are still used")
    func localFiguresRemainTheFallback() {
        // The path an extractor on this side takes: real text, real bytes, no engine override.
        let document = AttachedDocument(
            name: "notes.txt",
            kind: .plainText,
            text: "one two three four",
            byteCount: 18)

        #expect(document.summary == "4 words")
        #expect(document.estimatedTokens == 4)
    }

    @Test("The engine's figures survive the settings round-trip")
    func codablePreservesEngineFigures() throws {
        let original = AttachedDocument(
            name: "report.pdf",
            kind: .pdf,
            engineSummary: "3 pages · 800 words",
            engineTokens: 900)

        let decoded = try JSONDecoder().decode(
            AttachedDocument.self, from: try JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.summary == "3 pages · 800 words")
        #expect(decoded.estimatedTokens == 900)
    }

    @Test("Settings written before the fields existed still decode")
    func olderPayloadStillDecodes() throws {
        // The shape the app persisted before the fix, with the two new keys absent. If this threw,
        // the moderator's whole configuration would be replaced by defaults on upgrade.
        let legacy = Data(
            """
            {
              "id": "\(UUID().uuidString)",
              "name": "old.txt",
              "kind": "plainText",
              "text": "",
              "byteCount": 0,
              "wasTruncated": false,
              "addedAt": 0
            }
            """.utf8)

        let decoded = try JSONDecoder().decode(AttachedDocument.self, from: legacy)
        #expect(decoded.name == "old.txt")
        #expect(decoded.engineSummary == nil)
        #expect(decoded.engineTokens == nil)
    }
}
