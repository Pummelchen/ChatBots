// ChatBotsCoreTests — a seat reports the checkpoint it is actually running (A200).
//
// `AgentSpec.seat(index:modelID:)` set `modelShortName` to the default checkpoint's name whatever it
// was asked for, and `modelLabel` returns that for an MLX seat — so `--model-a <another checkpoint>`
// told every seat's system message "You are …, running Qwen3.5-4B-4bit on the moderator's Mac" and
// showed the same badge in every front end. A label that is a constant is a label that lies as soon as
// anything else is loaded.

import ChatBotsCore
import Foundation
import Testing

@Suite("A seat's model label follows its checkpoint (A200)")
struct ModelLabelTests {

    @Test("The default checkpoint reads exactly as it did")
    func theDefaultIsUnchanged() {
        // The derivation has to leave this alone: every transcript and test in the project spells it
        // this way.
        let seat = AgentSpec.seat(index: 0)
        #expect(seat.modelShortName == "Qwen3.5-4B-4bit")
        #expect(seat.modelID == AgentSpec.defaultModelID)
    }

    @Test("Another checkpoint gets its own label")
    func anotherCheckpointIsNamed() {
        let seat = AgentSpec.seat(index: 0, modelID: "mlx-community/Qwen3.5-32B-MLX-8bit")
        #expect(seat.modelShortName == "Qwen3.5-32B-8bit")
        #expect(seat.modelShortName != "Qwen3.5-4B-4bit", "which is the defect: it said the default")
        #expect(seat.modelLabel == "Qwen3.5-32B-8bit")
    }

    @Test("A bare name and an org-qualified id give the same label")
    func bothSpellingsAgree() {
        // ModelStore accepts both, so the label must not depend on which one the moderator typed.
        let bare = AgentSpec.seat(index: 0, modelID: "Qwen3.5-32B-MLX-8bit")
        let qualified = AgentSpec.seat(index: 0, modelID: "mlx-community/Qwen3.5-32B-MLX-8bit")
        #expect(bare.modelShortName == qualified.modelShortName)
    }

    @Test("The label reaches the prompt the seats are given")
    func thePromptCarriesIt() {
        let seat = AgentSpec.seat(index: 0, modelID: "mlx-community/Qwen3.5-32B-MLX-8bit")
        let prompt = PromptBuilder.systemMessage(
            for: seat, others: [], topic: "A topic")

        #expect(prompt.contains("Qwen3.5-32B-8bit"), "the seat is told what it is running")
        #expect(!prompt.contains("Qwen3.5-4B-4bit"), "and not the default checkpoint's name")
    }
}
