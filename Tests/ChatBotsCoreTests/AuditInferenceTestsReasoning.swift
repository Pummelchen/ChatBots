// ChatBotsCoreTests — audit coverage for the reasoning ceiling (A43)
//
// The ceiling used to append `</think>` to a local `answer` and abandon the model stream,
// so the model never saw the delimiter, the turn came back empty, and the notice claimed it
// "answered from there". Separately, `.unlimited` yielded a nil ceiling and the cap was
// computed as `maxTokens + (nil ?? 0)`, giving unlimited *less* headroom than `.high`.
//
// The budget arithmetic and the ceiling path are pure, so they are exercised here without
// loading weights. The model stream itself is not reachable without a GPU.

import ChatBotsCore
import Testing

@Suite("Reasoning ceiling (A43)")
struct AuditInferenceTestsReasoning {

    @Test("The generation cap is monotone across every thinking mode")
    func generationCapIsMonotone() {
        let budget = 1_000
        let contextWindow = 65_536
        let caps = ThinkingMode.allCases.map {
            MLXEngine.generationCap(
                answerBudget: budget, thinking: $0, contextWindow: contextWindow)
        }
        #expect(ThinkingMode.allCases.first == .off)
        #expect(caps.first == budget, "off must not pay reasoning headroom")
        #expect(caps == caps.sorted(), "a higher thinking level must never lower the cap")
        #expect(Set(caps).count == caps.count, "each level should differ when the window allows")

        let high = MLXEngine.generationCap(
            answerBudget: budget, thinking: .high, contextWindow: contextWindow)
        let unlimited = MLXEngine.generationCap(
            answerBudget: budget, thinking: .unlimited, contextWindow: contextWindow)
        #expect(unlimited > high, "unlimited must not get less headroom than high")

        // Even with no, or a tiny, context window, unlimited is never below high.
        for context in [nil, 0, 1_000, 9_000] as [Int?] {
            let bounded = MLXEngine.generationCap(
                answerBudget: budget, thinking: .high, contextWindow: context)
            let unbounded = MLXEngine.generationCap(
                answerBudget: budget, thinking: .unlimited, contextWindow: context)
            #expect(
                unbounded >= bounded,
                "unlimited fell below high with context \(String(describing: context))")
        }
    }

    @Test("The ceiling accounts reasoning in roughly four-character tokens")
    func ceilingAccounting() {
        var ceiling = ReasoningCeiling(mode: .minimal)  // 128
        #expect(ceiling.ceiling == 128)
        #expect(ceiling.account(reasoning: String(repeating: "a", count: 400)) == false)
        #expect(ceiling.account(reasoning: String(repeating: "a", count: 112)) == true)
        // It fires exactly once.
        #expect(ceiling.account(reasoning: String(repeating: "a", count: 400)) == false)
        #expect(ceiling.wasReached)
        #expect(ceiling.tokens == 128)

        // Unlimited has no ceiling and can never fire.
        var unlimited = ReasoningCeiling(mode: .unlimited)
        #expect(unlimited.ceiling == nil)
        #expect(unlimited.account(reasoning: String(repeating: "a", count: 40_000)) == false)

        // Off has zero headroom and also never fires.
        var off = ReasoningCeiling(mode: .off)
        #expect(off.ceiling == 0)
        #expect(off.account(reasoning: String(repeating: "a", count: 4_000)) == false)
    }

    @Test("A ceiling reached while thinking ends the turn with no answer and keeps the reasoning")
    func ceilingEndsTurnWithoutAnswer() {
        var assembler = TurnTextAssembler(thinking: .minimal)  // 128 reasoning tokens
        // 780 characters is 195 accounted tokens, past the 128 ceiling.
        let thought = String(repeating: "deliberation ", count: 60)
        let step = assembler.consume(thought)

        #expect(step.ceilingReached)
        #expect(assembler.ceilingReached)
        #expect(assembler.sawReasoning)
        #expect(!step.reasoning.isEmpty)
        // The forced delimiter must not be smuggled into the answer as content.
        #expect(assembler.answer.isEmpty, "answer was \(assembler.answer.debugDescription)")
        #expect(!assembler.answer.contains("</think>"))

        // The model never saw the delimiter, so nothing follows it.
        let tail = assembler.finish()
        #expect(tail.answer.isEmpty)
        #expect(assembler.answer.isEmpty)
        // The reasoning it was holding back is still reported, not dropped.
        #expect((step.reasoning + tail.reasoning).contains("deliberation"))
    }

    @Test("A model that closes its own think block is not treated as truncated")
    func normalAnswerIsUnaffected() {
        var assembler = TurnTextAssembler(thinking: .medium)
        let step = assembler.consume("short thought</think>The egg is ovoid.")
        #expect(!step.ceilingReached)
        #expect(!assembler.ceilingReached)
        #expect(step.reasoning == "short thought")
        #expect(assembler.answer == "The egg is ovoid.")
    }

    @Test("Thinking off is never cut off by a ceiling")
    func offNeverHitsACeiling() {
        var assembler = TurnTextAssembler(thinking: .off)
        let step = assembler.consume(String(repeating: "<think>", count: 1_000))
        #expect(!step.ceilingReached)
        #expect(!assembler.ceilingReached)
    }

    @Test("The ceiling notice describes what actually happened")
    func noticeIsTruthful() {
        let cutOff = MLXEngine.reasoningCeilingNotice(
            mode: .medium, ceiling: 2_048, producedAnswer: false)
        #expect(
            !cutOff.contains("answered from there"),
            "the old claim was false on a turn with no answer")
        #expect(cutOff.contains("before the model produced an answer"))
        #expect(cutOff.contains("2048"))
        #expect(cutOff.contains("medium"))

        let partial = MLXEngine.reasoningCeilingNotice(
            mode: .high, ceiling: 8_192, producedAnswer: true)
        #expect(!partial.contains("answered from there"))
        #expect(partial.contains("keeps the answer written so far"))

        // The thrown error carries the same honest text.
        let error = ReasoningCeilingError(mode: .medium, ceiling: 2_048)
        #expect(error.errorDescription == cutOff)
    }
}
