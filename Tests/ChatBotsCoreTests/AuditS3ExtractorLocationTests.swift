// ChatBotsCoreTests — where the document extractors actually live (A207)
//
// Three comments said the extractors were in the app target and that the core could not read a PDF or
// a Word file. Both halves were false: `PDFTextExtractor`, `TextutilExtractor` and
// `SystemDocumentExtractor` are defined in `Sources/ChatBotsCore/DocumentImport.swift`, which imports
// PDFKit and runs `/usr/bin/textutil`; nothing under `Sources/ChatBotsApp` mentions any of them; and
// `chatbots-cli` installs the extractor itself for the server it starts. The CLI is also what made one
// of the comments self-contradictory, since it does not link the app target at all.
//
// The comments now say where the extractors are. This holds them to it from both sides: the claim
// shapes are gone, and the things that make them false — the definitions, the PDFKit import, the
// `textutil` call, the CLI's install, and the app target's silence — are still true. A guard that only
// checked the wording could be satisfied by deleting `DocumentImport.swift`.

import Foundation
import Testing

@testable import ChatBotsCore

@Suite("The document extractors are where the comments say they are (A207)")
struct ExtractorLocationTests {

    /// A file in this package, for a property only its text can show.
    private func text(of path: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ChatBotsCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
            .appending(path: path)
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Every Swift source under one directory, so "nowhere in the app target" is a statement about
    /// all of it rather than about a file someone remembered.
    private func sources(under path: String) -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: path)
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return walk.compactMap { entry in
            guard let name = entry as? String, name.hasSuffix(".swift") else { return nil }
            let url = root.appending(path: name)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (name, source)
        }
    }

    @Test("No source says the extractors are in the app target")
    func theClaimShapesAreGone() {
        let all = sources(under: "Sources").map(\.1).joined(separator: "\n")
        #expect(sources(under: "Sources").count > 40, "the walk did not reach the sources")
        // Claim-shaped, not bare mentions: the comments that record what these used to say name the
        // app target too, and a guard that could not tell a claim from a correction would forbid
        // recording one.
        for claim in [
            "live in the app target",
            "belong to the app target",
            "the app's extractors, which",
            "cannot read a PDF or a Word file itself",
        ] {
            #expect(!all.contains(claim), "a source still claims: \(claim)")
        }
    }

    @Test("The extractors the comments now name are in this module")
    func theExtractorsAreWhereTheCommentsSay() throws {
        let importModule = try text(of: "Sources/ChatBotsCore/DocumentImport.swift")
        #expect(importModule.contains("import PDFKit"))
        #expect(importModule.contains("public struct PDFTextExtractor"))
        #expect(importModule.contains("public struct TextutilExtractor"))
        #expect(importModule.contains("public enum SystemDocumentExtractor"))
        #expect(importModule.contains("/usr/bin/textutil"))

        // And the comments point there rather than at the app.
        let attachments = try text(of: "Sources/ChatBotsCore/Attachments.swift")
        #expect(attachments.contains("DocumentImport.swift"))
        #expect(attachments.contains("SystemDocumentExtractor"))
        let main = try text(of: "Sources/ChatBotsCLI/main.swift")
        #expect(main.contains("SystemDocumentExtractor"), "the CLI no longer names the extractor")
    }

    @Test("The CLI is what installs it, and the app target has no extractor at all")
    func theCliInstallsItAndTheAppDoesNot() throws {
        let main = try text(of: "Sources/ChatBotsCLI/main.swift")
        let installs =
            main.components(
                separatedBy: "DocumentIngestorProvider.install(SystemDocumentExtractor.ingestor)"
            ).count - 1
        #expect(installs >= 2, "the CLI installs the extractor in \(installs) place(s)")

        let app = sources(under: "Sources/ChatBotsApp")
        #expect(app.count > 5, "the walk did not reach the app target")
        for (name, source) in app {
            for word in ["PDFKit", "textutil", "Extractor", "Ingestor"] {
                #expect(!source.contains(word), "ChatBotsApp/\(name) mentions \(word)")
            }
        }
    }

    @Test("The core still refuses uploads until an extractor is installed (the counterweight)")
    func uploadsAreRefusedWithoutAnExtractor() throws {
        let attachments = try text(of: "Sources/ChatBotsCore/Attachments.swift")
        #expect(attachments.contains("this server was started without document support"))
        #expect(attachments.contains("public enum DocumentIngestorProvider"))
    }
}
