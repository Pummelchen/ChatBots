// ChatBotsCoreTests — audit coverage for the compaction budget (A42)
//
// `compact` used to build an overridden spec (`maxTokens = compactSummaryTokens`,
// `thinking = .off`) and then call a `generate` that re-read the seat's own immutable
// `spec`. The local was never read, so the digest ran with the seat's full 32 768-token
// cap and its live thinking level while its own comment claimed thinking was off.
//
// The wiring now runs through `TurnSettings`, which `generate` reads and nothing else.
// These tests pin the settings the compact turn is built with; the model call itself
// needs weights and is not exercised here.

import ChatBotsCore
import Testing

@Suite("Compaction budget (A42)")
struct AuditInferenceTestsCompact {

    @Test("The compact turn uses the digest's answer cap, not the seat's")
    func compactUsesItsOwnCap() {
        let seat = AgentSpec.seatA()
        #expect(seat.maxTokens == 32_768)

        let settings = MLXEngine.compactTurnSettings(
            seat: seat, maxTokens: 900, contextWindow: 32_768)
        #expect(settings.answerBudget == 900)
        // Thinking off contributes no reasoning headroom, so the whole cap is the digest's.
        #expect(settings.generationCap == 900)
        #expect(settings.thinking == .off)

        // This is what the old code produced: the seat's own settings, not the digest's.
        let unoverridden = TurnSettings(spec: seat, thinking: .off, contextWindow: 32_768)
        #expect(
            unoverridden.generationCap == 32_768,
            "the seat's full cap is exactly what the dropped override used to spend")

        // Sampling and identity still come from the seat.
        #expect(settings.agentID == seat.id)
        #expect(settings.temperature == seat.temperature)
        #expect(settings.topP == seat.topP)
    }

    @Test("A compact turn never thinks, whatever the seat's live level is")
    func compactIsAlwaysOff() {
        for level in ThinkingMode.allCases {
            var seat = AgentSpec.seatB()
            seat.thinking = level
            let settings = MLXEngine.compactTurnSettings(
                seat: seat, maxTokens: 900, contextWindow: 32_768)
            #expect(settings.thinking == .off, "\(level.rawValue) leaked into the digest")
            #expect(
                settings.generationCap == 900,
                "\(level.rawValue) added reasoning headroom to the digest")
            #expect(settings.templateContext["enable_thinking"] as? Bool == false)
        }
    }

    @Test("The digest cap follows compactSummaryTokens rather than a constant")
    func capFollowsTheConfiguration() {
        var configuration = ConversationEngine.Configuration()
        configuration.compactSummaryTokens = 1_500
        let settings = MLXEngine.compactTurnSettings(
            seat: .seatA(), maxTokens: configuration.compactSummaryTokens, contextWindow: 32_768)
        #expect(settings.generationCap == 1_500)
    }
}
