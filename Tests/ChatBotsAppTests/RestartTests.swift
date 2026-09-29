// ChatBotsAppTests — restarting clears the run that was there, not only the engine's copy of it
//
// `startOrRestart` clears the engine and then starts again. It used to leave the interface alone, so
// a paused pacer, a half-revealed reply and the previous run's rate samples survived into the new
// session — which is what made Restart read as "the session did not change". `reset` had always
// dropped them, so one command was doing half of what the other did.

import Foundation
import Testing

@testable import ChatBots

@MainActor
@Suite("Restarting a session")
struct RestartTests {

    @Test("Restarting drops what the previous run left on screen")
    func restartClearsThePreviousRun() {
        let controller = ChatController()
        controller.panes[0].beginTurn()
        controller.panes[0].liveText = "half a sentence"
        controller.panes[0].liveBlocks = ["a paragraph already revealed"]
        controller.rateSamples["Agent 1"] = (characters: 120, since: Date())

        controller.startOrRestart()

        #expect(
            controller.panes[0].liveText.isEmpty, "the streamed tail does not survive a restart")
        #expect(controller.panes[0].liveBlocks.isEmpty)
        #expect(!controller.panes[0].isGenerating, "the new session is not shown as still typing")
        #expect(controller.rateSamples.isEmpty, "the previous run's rates are not the new run's")
    }

    @Test("Clearing the conversation drops the same state, so the two cannot drift apart again")
    func clearingDropsTheSameState() {
        let controller = ChatController()
        controller.panes[0].beginTurn()
        controller.panes[0].liveText = "half a sentence"

        controller.reset()

        #expect(controller.panes[0].liveText.isEmpty)
        #expect(!controller.panes[0].isGenerating)
    }
}
