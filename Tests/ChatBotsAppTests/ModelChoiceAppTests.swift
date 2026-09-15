// ChatBotsAppTests — the pane follows the engine when the checkpoint changes
//
// `ChatController.setModel` sends the change and updates the pane only if the engine took it. The
// order matters: showing a checkpoint on a seat that is still running the old one is the defect A173
// records, and the engine refuses a swap while a turn is in flight, so the click and the pane can
// genuinely disagree. With no client the send cannot happen at all, which is the case this pins
// without a socket.

import ChatBotsCore
import Foundation
import Testing

@testable import ChatBots

@MainActor
@Suite("Choosing a checkpoint in the app")
struct ModelChoiceAppTests {

    @Test("A change that could not be sent leaves the seat on the model it has")
    func aRefusedChangeKeepsTheSeat() async {
        let controller = ChatController()
        #expect(controller.panes[0].spec.modelID == AgentSpec.defaultModelID)

        controller.setModel("huihui9b", for: "Agent 1")
        // The send runs in a task, as it does for every other command from the interface.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(controller.panes[0].spec.modelID == AgentSpec.defaultModelID)
        #expect(
            controller.engineConnection != nil,
            "the failure is reported rather than the seat silently changing")
    }

    @Test("An alias is resolved to the repository id before anything is stored")
    func aliasesBecomeIds() {
        // The pane holds repository ids, never aliases: the id is what the engine loads and what is
        // written to settings, so a restart does not depend on the catalogue still spelling an alias
        // the same way.
        let choice = ModelCatalog.choice(for: "huihui4b")
        #expect(choice != nil)
        #expect(ModelCatalog.resolve("huihui4b") == choice?.id)
        #expect(choice?.id != "huihui4b")
    }
}
