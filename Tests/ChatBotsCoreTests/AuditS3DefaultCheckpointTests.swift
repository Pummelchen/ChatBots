// ChatBotsCoreTests — the default checkpoint is named once (A208)
//
// `tools/install.sh` had its own copy of `AgentSpec.defaultModelID` and of the directory name derived
// from it, kept in step by a comment. They agreed, but a mismatch would not have been noticed by
// anything: the app finds a local checkpoint at the tail of the repo id under `models/`
// (`ModelStore.localCheckpoint`), while the installer writes a flat `models/<tail>/`, so two strings
// that disagree mean a 3 GB download the app can never see and no error anywhere. A121 removed exactly
// this duplication for the macOS minimum rather than adding a check that policed it, and this is the
// same fact.
//
// The installer now derives the id from `ChatModels.swift` and the directory name from the id, and the
// two other places that named the default — the CLI's `--api-model` and the OpenAI client's default —
// reference the declaration. This holds the invariant: the id is written once in the sources, the
// users point at it, and the installer copies neither the id nor its tail. The value itself is pinned
// here too, because which checkpoint this project ships is a decision, not an implementation detail.

import Foundation
import Testing

@testable import ChatBotsCore

@Suite("The default checkpoint is named once (A208)")
struct DefaultCheckpointTests {

    /// Every Swift source in `Sources/`, so a new copy anywhere is seen.
    private func sources() -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources")
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return walk.compactMap { entry in
            guard let name = entry as? String, name.hasSuffix(".swift") else { return nil }
            let url = root.appending(path: name)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (name, source)
        }
    }

    private func text(of path: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: path)
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("The checkpoint id is written once in the sources, where it is declared")
    func theIDIsDeclaredOnce() {
        let literal = "\"mlx-community/Qwen3.5-4B-MLX-4bit\""
        let found = sources()
        #expect(found.count > 40, "the walk reached only \(found.count) files")
        let holders = found.filter { $0.1.contains(literal) }
        #expect(
            holders.count == 1 && holders[0].0.hasSuffix("ChatModels.swift"),
            "the literal is in \(holders.map(\.0)) — it belongs only on the declaration")
        let declaration = found.first { $0.0.hasSuffix("ChatModels.swift") }?.1 ?? ""
        #expect(
            declaration.contains("static let defaultModelID = \(literal)"),
            "the one copy is not the declaration")
    }

    @Test("Everything that needs it references the declaration")
    func theUsersReferenceIt() throws {
        let references = sources().reduce(0) { total, file in
            total + file.1.components(separatedBy: "AgentSpec.defaultModelID").count - 1
        }
        #expect(references >= 3, "only \(references) reference(s) to AgentSpec.defaultModelID")
        for path in [
            "Sources/ChatBotsCLI/main.swift",
            "Sources/ChatBotsCore/OpenAIResponsesClient.swift",
        ] {
            let source = try text(of: path)
            #expect(source.contains("AgentSpec.defaultModelID"), "\(path) names the id itself")
        }
    }

    @Test("The installer derives the id and its directory instead of copying either")
    func theInstallerDerivesIt() throws {
        let installer = try text(of: "tools/install.sh")
        #expect(
            !installer.contains("mlx-community/Qwen3.5-4B-MLX-4bit"),
            "install.sh has its own copy of the checkpoint id again")
        #expect(
            installer.contains("static let defaultModelID = \"\\([^\"]*\\)\""),
            "install.sh no longer reads the declaration out of ChatModels.swift")
        #expect(
            installer.contains("MODEL_DIR_NAME=\"${MODEL_ID##*/}\""),
            "the directory name is written down instead of derived from the id")
        #expect(
            installer.contains("Could not read the default checkpoint"),
            "nothing refuses when the declaration cannot be read")
    }

    @Test("The shipped checkpoint is a repo id, so its tail is the directory the app looks in")
    func theValueIsARepoID() {
        let tail = AgentSpec.defaultModelID.split(separator: "/").last.map(String.init)
        #expect(AgentSpec.defaultModelID == "mlx-community/Qwen3.5-4B-MLX-4bit")
        #expect(tail == "Qwen3.5-4B-MLX-4bit", "the derived directory would be \(tail ?? "nothing")")
        #expect(AgentSpec.defaultModelID.contains("/"), "a bare name would make the tail rule a no-op")
    }
}
