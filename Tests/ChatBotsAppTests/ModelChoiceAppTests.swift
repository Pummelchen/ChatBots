// ChatBotsAppTests — the pane follows the engine when the checkpoint changes
//
// `ChatController.setModel` sends the change and updates the pane only if the engine took it. The
// order matters: showing a checkpoint on a seat that is still running the old one is the defect this
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

    @Test("A launch hands over each stored checkpoint, and only the seats that are not on it")
    func onlyStoredDifferencesAreHandedOver() {
        // The engine starts on its own defaults, so a stored checkpoint has to be sent or the seat
        // runs the default while the pane draws the user's choice. Seat 1 differs and is handed
        // over; seat 2 already runs the stored one and must not be sent, because asking for a
        // change makes the engine release weights it is holding and load them again.
        let checkpoint = "TheWirelessPhoenix/Huihui-Qwen3.5-9B-abliterated-oQ4e"
        let stored = [
            AgentSpec.seat(index: 0, modelID: checkpoint),
            AgentSpec.seat(index: 1, modelID: AgentSpec.defaultModelID),
        ]

        let changes = ChatController.storedSeatChanges(
            stored: stored,
            engineModels: ["Agent 1": AgentSpec.defaultModelID, "Agent 2": AgentSpec.defaultModelID],
            engineBackends: ["Agent 1": "mlx", "Agent 2": "mlx"])

        // Written as one line because the two style gates disagree about where a trailing comma goes
        // in a multi-line array holding one call: SwiftLint wants it, swift-format does not.
        #expect(changes == [.model(seatID: "Agent 1", modelID: checkpoint)])
    }

    @Test("A seat the user switched to an API is handed over rather than returned to the default")
    func storedAPISeatsAreHandedOver() {
        // The defect this pins: the backend was never sent, so an engine started on `mlx` silently
        // took a seat the user had put on an API back to the local engine — "Use API" appeared to
        // switch itself off on the next launch.
        var spec = AgentSpec.seat(
            index: 0, modelID: "TheWirelessPhoenix/Huihui-Qwen3.5-9B-abliterated-oQ4e")
        spec.backend = .openAIResponses

        let changes = ChatController.storedSeatChanges(
            stored: [spec],
            engineModels: ["Agent 1": AgentSpec.defaultModelID],
            engineBackends: ["Agent 1": "mlx"])

        // The backend only: an API seat is never handed a local checkpoint.
        #expect(changes == [.backend(seatID: "Agent 1", backend: .openAIResponses)])
    }

    @Test("A stored alias is handed over as the repository id the engine loads")
    func storedAliasesAreResolved() {
        let stored = [AgentSpec.seat(index: 0, modelID: "huihui9b")]

        let changes = ChatController.storedSeatChanges(
            stored: stored,
            engineModels: ["Agent 1": AgentSpec.defaultModelID],
            engineBackends: ["Agent 1": "mlx"])

        #expect(changes == [.model(seatID: "Agent 1", modelID: ModelCatalog.resolve("huihui9b"))])
    }

    @Test("Nothing is handed over when the engine already matches what is stored")
    func agreementSendsNothing() {
        let stored = [AgentSpec.seat(index: 0, modelID: "huihui9b")]

        let changes = ChatController.storedSeatChanges(
            stored: stored,
            engineModels: ["Agent 1": ModelCatalog.resolve("huihui9b")],
            engineBackends: ["Agent 1": "mlx"])

        #expect(changes.isEmpty)
    }
}
