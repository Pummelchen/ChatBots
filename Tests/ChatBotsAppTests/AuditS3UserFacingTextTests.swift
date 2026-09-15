// ChatBotsAppTests — what the app tells a user about where the models run (A178).
//
// Two strings said the models run "in-process". That was true when the app held the engine, and it
// stopped being true when the engine became a process the app starts and talks to over WebTransport —
// so a user reading the Help window or the backend tooltip was told something the app no longer does.
// The sweep for the same claim found two more in the backend's own label and its documentation.
//
// A label is an ordinary value and is asserted directly. A SwiftUI alert and a `.help` string are
// literals inside views, so the two of those are checked as source, the way `TavilyKeyTests` checks a
// file — the alternative is claiming a string is right because nobody re-reads it.

import ChatBotsCore
import Foundation
import Testing

@testable import ChatBots

@Suite("Where the app says the models run (A178)")
struct UserFacingModelTextTests {

    @Test("The local backend is called local, not in-process")
    func theBackendLabelIsHonest() {
        #expect(AgentSpec.Backend.mlx.label == "MLX (local)")
        #expect(AgentSpec.Backend.mlx.shortLabel == "MLX")
        #expect(!AgentSpec.Backend.mlx.label.contains("in-process"))
        // The API side is unchanged: the label names the protocol, which is what it is.
        #expect(AgentSpec.Backend.openAIResponses.label == "OpenAI Responses API")
    }

    @Test("No user-facing string claims the models run in the app")
    func noStringClaimsInProcess() throws {
        // The exact sentences that were there, rather than the word "in-process": a *comment* about
        // the old design is true history — `ChatController` has one, and these files may want one —
        // and a check on the word alone would fail that.
        let stale = [
            "Both models run in-process on the GPU via MLX",
            "Running Qwen in-process on the GPU with MLX",
            "MLX (in-process)",
            "runs the weights in-process on the GPU",
        ]
        let files = [
            "Sources/ChatBotsApp/ChatBotsApp.swift": "the Help window",
            "Sources/ChatBotsApp/Views/AgentHeader.swift": "the backend tooltip",
            "Sources/ChatBotsCore/ChatModels.swift": "the backend's own documentation",
        ]
        for (path, what) in files {
            let text = try source(path)
            for phrase in stale {
                #expect(
                    !text.contains(phrase),
                    "\(what) (\(path)) says \(phrase.debugDescription) again")
            }
        }
    }

    @Test("The Help window and the tooltip say where the model actually runs")
    func theTwoStringsSayWhereItRuns() throws {
        let help = try source("Sources/ChatBotsApp/ChatBotsApp.swift")
        #expect(help.contains("runs in the engine process the app starts"))
        #expect(help.contains("or against the endpoint you configured for that seat"))

        let tooltip = try source("Sources/ChatBotsApp/Views/AgentHeader.swift")
        #expect(tooltip.contains("in the engine process"))
        // The seat can be pointed at any checkpoint now, so the tooltip names the one it has rather
        // than a model the app shipped with once.
        #expect(tooltip.contains("\\(spec.modelShortName)"))
    }

    /// A source file in this package, for a property only its text can show.
    private func source(_ path: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ChatBotsAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
            .appending(path: path)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
