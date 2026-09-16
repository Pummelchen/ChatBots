// ChatBotsCoreTests — the public cap and the engine's cap are one answer
//
// The engine's headroom arithmetic was fixed in
// `MLXEngine.generationCap(answerBudget:thinking:contextWindow:)`, but `AgentSpec.generationCap`
// kept the old `maxTokens + (reasoningTokenBudget ?? 0)`. That made `.unlimited` — the mode the
// user picks precisely to stop bounding thought — the *smallest* cap of any level, and a public
// caller got the pre-fix answer. `ThinkingModeTests` pinned the wrong value, which is why this
// file also holds the cross-check: the property and the engine helper must agree for every mode
// and every context window, including none.
//
// `ThinkingModeTests.generationCap` was corrected in the same commit because it asserted the
// defect; this suite is the independent, wider check.

import ChatBotsCore
import Testing

@Suite("The generation cap agrees with the engine")
struct GenerationCapTests {

    /// Every context window the app can present: none, zero (unknown), a tiny one and the
    /// 262 144-token Qwen default.
    private let windows: [Int?] = [nil, 0, 1, 8_192, 32_768, 262_144]

    @Test("The property and the engine helper are the same function")
    func propertyMatchesEngine() {
        for window in windows {
            for mode in ThinkingMode.allCases {
                var spec = AgentSpec.seatA()
                spec.maxTokens = 4_096
                spec.contextWindow = window ?? 0
                spec.thinking = mode
                #expect(
                    spec.generationCap
                        == MLXEngine.generationCap(
                            answerBudget: 4_096, thinking: mode, contextWindow: window),
                    "\(mode.rawValue) with context \(String(describing: window))")
            }
        }
    }

    @Test("Unlimited is never below high, whatever the context window")
    func unlimitedIsNeverBelowHigh() {
        for window in windows {
            var spec = AgentSpec.seatA()
            spec.maxTokens = 1_000
            spec.contextWindow = window ?? 0

            spec.thinking = .high
            let high = spec.generationCap
            spec.thinking = .unlimited
            #expect(
                spec.generationCap >= high,
                "unlimited fell below high with context \(String(describing: window))")
        }
    }

    @Test("The property is monotone across every level")
    func propertyIsMonotone() {
        var spec = AgentSpec.seatA()
        spec.maxTokens = 1_000
        var previous = 0
        for mode in ThinkingMode.allCases {
            spec.thinking = mode
            #expect(spec.generationCap >= previous, "\(mode.rawValue) lowered the cap")
            previous = spec.generationCap
        }
    }
}
