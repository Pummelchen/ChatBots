// ChatBotsCoreTests — thinking levels and the repetition guard

import ChatBotsCore
import Testing

@Suite("ThinkingMode")
struct ThinkingModeTests {

    @Test("Budgets ascend from off to unlimited")
    func budgetsAscend() {
        let budgets = ThinkingMode.allCases.map(\.reasoningTokenBudget)
        // off is 0, unlimited is nil (no ceiling), the rest increase.
        #expect(budgets.first == Optional(0))
        #expect(budgets.last.flatMap { $0 } == nil, "unlimited has no ceiling")
        let bounded = budgets.compactMap { $0 }
        #expect(bounded == bounded.sorted())
        #expect(Set(bounded).count == bounded.count, "each level should be distinct")
    }

    @Test("Only off declines to think")
    func onlyOffSkipsThinking() {
        #expect(ThinkingMode.off.thinks == false)
        for mode in ThinkingMode.allCases where mode != .off {
            #expect(mode.thinks, "\(mode.rawValue) should think")
        }
    }

    @Test("Off asks the template to disable thinking; the others leave it on")
    func templateFlags() {
        #expect(ThinkingMode.off.templateContext["enable_thinking"] as? Bool == false)
        #expect(ThinkingMode.off.templateContext["reasoning_effort"] as? String == "none")
        for mode in ThinkingMode.allCases where mode != .off {
            #expect(mode.templateContext["enable_thinking"] as? Bool == true)
        }
    }

    @Test("The hard generation cap is the answer budget plus the thinking ceiling")
    func generationCap() {
        var spec = AgentSpec.seatA()
        spec.maxTokens = 1_000

        spec.thinking = .off
        #expect(spec.generationCap == 1_000)

        spec.thinking = .low
        #expect(spec.generationCap == 1_000 + 512)

        spec.thinking = .unlimited
        #expect(spec.generationCap == 1_000, "unlimited adds no ceiling to the cap")

        spec.thinking = .high
        #expect(spec.generationCap == 1_000 + 8_192)
    }

    @Test("Both seats share the requested preset by default")
    func sharedPreset() {
        let a = AgentSpec.seatA()
        let b = AgentSpec.seatB()
        for spec in [a, b] {
            #expect(spec.temperature == 1.0)
            #expect(spec.topP == 0.95)
            #expect(spec.topK == 20)
            #expect(spec.minP == 0.0)
            #expect(spec.repetitionPenalty == 1.0)
            #expect(spec.maxTokens == 32_768)
            #expect(spec.thinking.thinks)
        }
        // MLX subtracts the presence penalty, so the stored value must be negative.
        #expect(a.presencePenalty == -1.5)
        #expect(b.presencePenalty == -1.5)
    }

    @Test("The seat's thinking level can change without touching the model")
    func thinkingIsMutable() {
        var spec = AgentSpec.seatA()
        #expect(spec.thinking == AgentSpec.QwenSampling.thinking)
        spec.thinking = .off
        #expect(spec.thinking == .off)
        #expect(spec.modelID == AgentSpec.defaultModelID, "changing thinking must not disturb the seat")
    }
}

@Suite("RepetitionDetector")
struct RepetitionDetectorTests {

    /// Real degenerate output from this app: an 8-gram repeated dozens of times.
    private static let looping = String(
        repeating: "This is a more efficient shape for the egg to be, ",
        count: 40)

    /// Normal prose: no phrase repeats.
    private static let prose = """
        The ovoid shape of a bird egg balances mechanical strength against the needs of \
        the developing embryo. Ground-nesting birds tend to lay more pointed eggs, which \
        roll in a tight circle rather than wandering away. Cliff-nesting species lay \
        rounder eggs that stay put. The pattern is not one shape fits all; it tracks the \
        ecology of the nest. Shell thickness also correlates with curvature, so a more \
        elongated egg carries a thinner shell for the same volume, which matters for gas \
        exchange late in incubation. Taken together these pressures explain the observed \
        distribution of egg shapes far better than any single mechanical story.
        """

    @Test("A repeating phrase is caught")
    func catchesLoop() {
        var detector = RepetitionDetector()
        var fired = false
        // Feed in chunks, the way generation arrives.
        for chunk in Self.looping.chunked(into: 20) {
            if detector.ingest(chunk) { fired = true; break }
        }
        #expect(fired)
    }

    @Test("Ordinary prose is not flagged")
    func prosePasses() {
        var detector = RepetitionDetector()
        var fired = false
        for chunk in Self.prose.chunked(into: 20) where detector.ingest(chunk) {
            fired = true
        }
        #expect(!fired)
    }

    @Test("Short output is never judged")
    func shortOutputIgnored() {
        var detector = RepetitionDetector()
        // Below the minimum word count even though it repeats.
        #expect(detector.ingest("ha ha ha ha ha ha ha ha ha ha ha ha ha ha ha") == false)
    }

    @Test("Text that merely reuses common words is not flagged")
    func commonWordsAreFine() {
        // "the egg" and "of the" recur constantly in normal writing.
        let text = """
            The shape of the egg is the result of the biology of the bird. The shell of \
            the egg protects the embryo inside the egg. The size of the egg depends on \
            the size of the bird, and the clutch of the bird depends on the climate of \
            the region where the bird nests.
            """
        var detector = RepetitionDetector()
        #expect(detector.ingest(text) == false)
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        var chunks: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[index..<end]))
            index = end
        }
        return chunks
    }
}
