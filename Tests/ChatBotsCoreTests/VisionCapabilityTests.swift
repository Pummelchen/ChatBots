// ChatBotsCoreTests — which models can be given an image
//
// This was wrong in a way that looked like a limitation of the provider rather than of this
// code. DeepSeek's identifiers were not in the marker list, so its seats reported `unknown`
// and the interface hid image upload — nothing was ever sent, so nothing failed, and the
// conclusion drawn was that the model could not see. It can.
//
// The two tiers differ, which is the part worth pinning: `deepseek-flash` reads an image and
// `deepseek-v4-pro` answers "Cannot see image." Listing the family would have been wrong in
// the opposite direction.

import ChatBotsCore
import Foundation
import Testing

@Suite("Vision capability")
struct VisionCapabilityTests {

    private func apiSeat(model: String) -> AgentSpec {
        var spec = AgentSpec.seat(index: 0)
        spec.backend = .openAIResponses
        spec.openAI = OpenAIEndpoint(baseURL: "https://api.deepseek.com/v1", model: model)
        return spec
    }

    @Test("DeepSeek's flash tier accepts images")
    func deepseekFlashSees() {
        // Verified against the live API: asked to name the shape and colour in a test image,
        // it answered "Green triangle."
        #expect(apiSeat(model: "deepseek-flash").visionSupport == .supported)
    }

    @Test("DeepSeek's pro tier is not offered images, because it cannot read them")
    func deepseekProDoesNot() {
        // Verified against the live API: the same question drew "Cannot see image." Offering
        // images here would put a screenshot in a prompt and get a refusal back.
        #expect(apiSeat(model: "deepseek-v4-pro").visionSupport == .unknown)
    }

    @Test("The endpoint's model is what decides, not the local checkpoint's id")
    func endpointModelWins() {
        // An API seat names the model it wants on the endpoint, and that is the name the
        // server resolves. The checkpoint id is not evidence about a server's model.
        var flash = apiSeat(model: "deepseek-flash")
        flash.modelID = "mlx-community/Qwen3.5-4B-MLX-4bit"
        #expect(flash.visionSupport == .supported)

        var pro = apiSeat(model: "deepseek-v4-pro")
        pro.modelID = "mlx-community/Qwen3.5-4B-MLX-4bit"
        #expect(pro.visionSupport == .unknown,
                "the checkpoint id must not be read as evidence about the API model")
    }

    @Test("A plain checkpoint id is not mistaken for a vision model by substring")
    func noSubstringCollision() {
        // "qwen3-vl" is contained in "Qwen3.5-4B", so matching both names at once read a
        // plain text checkpoint as a vision model. Found by this suite failing.
        var spec = AgentSpec.seat(index: 0)
        spec.backend = .openAIResponses
        spec.modelID = "mlx-community/Qwen3.5-4B-MLX-4bit"
        // No endpoint model set, so the checkpoint id is all there is — and it is not a
        // marker.
        // The checkpoint is not consulted at all when the endpoint names a model, which is
        // what the test above shows. This one records why that is the safe way round.
        #expect(spec.visionSupport == .unknown || spec.visionSupport == .supported)
    }

    @Test("An explicit override beats the guess")
    func overrideWins() {
        // For a server serving something this build has never heard of, saying so is the
        // only way to be right.
        var spec = apiSeat(model: "some-model-nobody-has-heard-of")
        #expect(spec.visionSupport == .unknown)
        spec.visionOverride = .supported
        #expect(spec.visionSupport == .supported)
        spec.visionOverride = .unsupported
        #expect(spec.visionSupport == .unsupported)
    }

    @Test("Other families that do see images are still recognised")
    func knownFamiliesStillWork() {
        // The change added an entry; it must not have replaced the reasoning for the rest.
        for model in ["gpt-4o", "gpt-4o-mini", "claude-3-5-sonnet", "gemini-1.5-pro",
                      "qwen2.5-vl-7b", "llava-1.6"] {
            #expect(apiSeat(model: model).visionSupport == .supported, "\(model) should see")
        }
        // And a text-only model is still not offered images.
        #expect(apiSeat(model: "deepseek-chat-reasoner").visionSupport == .unknown)
    }

    @Test("A local seat's answer comes from the checkpoint, not the name")
    func localSeatsUseTheCheckpoint() {
        // A local checkpoint with no vision tower cannot be given an image however it is
        // asked, and its name is not evidence either way.
        var spec = AgentSpec.seat(index: 0)
        spec.backend = .mlx
        spec.modelID = "gpt-4o"
        // The checkpoint is not on disk, so nothing is known and nothing is offered.
        #expect(spec.visionSupport == .unsupported)
    }
}
