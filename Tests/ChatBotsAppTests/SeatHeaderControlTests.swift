// ChatBotsAppTests — what the seat header offers on each backend, and what the thread draws
//
// Two app-side defects that a compiler cannot see. A seat switched to the API kept a menu of local
// checkpoints, and choosing one changed nothing the seat was running — a control that looks like a
// model picker on a seat that is not choosing a local model is a trap rather than a feature. And the
// thread layout filtered the setup brief out of its rows while the view written to draw that brief,
// `SetupBlock`, was never wired in, so the topic and the house rules were invisible in the one layout
// with no per-pane header to carry them.

import ChatBotsCore
import Foundation
import Testing

@testable import ChatBots

@MainActor
@Suite("The seat header's model control and the thread's brief")
struct SeatHeaderControlTests {

    @Test("A local seat offers the checkpoint menu")
    func localSeatsOfferTheMenu() {
        var spec = AgentSpec.seat(index: 0)
        spec.backend = .mlx
        #expect(ModelControl.offersCheckpointMenu(for: spec))
    }

    @Test("An API seat offers no checkpoint menu, because choosing one would change nothing")
    func apiSeatsOfferNoMenu() {
        var spec = AgentSpec.seat(index: 0)
        spec.backend = .openAIResponses
        #expect(
            !ModelControl.offersCheckpointMenu(for: spec),
            "the menu is local checkpoints; an API seat's model is chosen in the endpoint sheet")
    }

    @Test("The thread draws the setup brief from the rule that excludes it from the rows")
    func theThreadDrawsTheBrief() throws {
        // The view itself cannot be instantiated here, so what is pinned is the wiring that was
        // missing: the brief is asked for, drawn, and asked for from the same rule the rows use. An
        // edit that drops the block fails here rather than quietly hiding the topic again.
        let source = try source("Sources/ChatBotsApp/Views/UnifiedConversation.swift")

        #expect(source.contains("SetupBlock(text: brief)"), "the thread no longer draws the brief")
        #expect(
            source.contains("ThreadGrouping.setupBrief(in: controller.turns)"),
            "the brief did not come from the shared rule")
        #expect(
            source.contains("ThreadGrouping.messageTurns(from: controller.turns)"),
            "the rows no longer come from the shared rule")
    }

    /// A source file in this package, for the property that only its text can show.
    private func source(_ path: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ChatBotsAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
            .appending(path: path)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
