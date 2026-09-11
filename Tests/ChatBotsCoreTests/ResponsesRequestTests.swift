// ChatBotsCoreTests — the request sent to a Responses-API server
//
// Two bugs found by testing against DeepSeek live here, because both were invisible against
// a local server and both produced an *empty reply* rather than an error.

import ChatBotsCore
import Testing

@Suite("Responses API requests")
struct ResponsesRequestTests {

    private func request(
        thinking: ThinkingMode,
        maxTokens: Int = 100,
        includeReasoning: Bool? = nil
    ) -> OpenAIResponsesClient.Request {
        var spec = AgentSpec.seat(index: 0)
        spec.thinking = thinking
        spec.maxTokens = maxTokens
        let endpoint = OpenAIEndpoint(
            baseURL: "https://api.deepseek.com/v1", model: "deepseek-v4-pro")
        let client = OpenAIResponsesClient(endpoint: endpoint)
        return OpenAIResponsesClient.Request(
            instructions: "You are Agent 1.",
            input: "Say ready",
            temperature: spec.temperature,
            topP: spec.topP,
            topK: spec.topK,
            minP: spec.minP,
            presencePenalty: spec.presencePenalty,
            repetitionPenalty: spec.repetitionPenalty,
            maxOutputTokens: spec.serverOutputCap,
            includeReasoning: includeReasoning ?? thinking.thinks,
            reasoningEffort: thinking.reasoningEffort
        )
    }

    @Test("The effort is sent even when the reasoning text is not wanted")
    func effortIsAlwaysSent() throws {
        // The bug: with thinking off the effort was omitted, so the server defaulted to
        // reasoning anyway and spent the entire output ceiling doing it.
        let client = OpenAIResponsesClient(
            endpoint: OpenAIEndpoint(
                baseURL: "https://api.deepseek.com/v1", model: "deepseek-v4-pro"))
        var off = request(thinking: .off)
        off.includeReasoning = false
        let body = client.body(for: off)

        let reasoning = try #require(body["reasoning"] as? [String: String])
        #expect(reasoning["effort"] == "none", "thinking off must actually ask for no thinking")
        // The encrypted reasoning content is a separate concern, and is not requested.
        #expect(body["include"] == nil)
    }

    @Test("Asking for reasoning text also asks for the effort")
    func effortAccompaniesInclude() throws {
        let client = OpenAIResponsesClient(
            endpoint: OpenAIEndpoint(
                baseURL: "https://api.deepseek.com/v1", model: "deepseek-v4-pro"))
        let body = client.body(for: request(thinking: .medium, includeReasoning: true))
        #expect((body["reasoning"] as? [String: String])?["effort"] == "medium")
        #expect(body["include"] != nil)
    }

    @Test("Every thinking level maps to an effort the server understands")
    func effortMapping() {
        #expect(ThinkingMode.off.reasoningEffort == "none")
        #expect(ThinkingMode.minimal.reasoningEffort == "low")
        #expect(ThinkingMode.low.reasoningEffort == "low")
        #expect(ThinkingMode.medium.reasoningEffort == "medium")
        #expect(ThinkingMode.high.reasoningEffort == "high")
        #expect(ThinkingMode.unlimited.reasoningEffort == "high")
    }

    @Test("The output ceiling leaves room for reasoning, which shares it")
    func outputCapLeavesRoomForReasoning() {
        // A server counts reasoning tokens against the same ceiling as the answer, so a
        // small answer budget would be consumed before any answer was written. Measured
        // against DeepSeek: 100 and 300 tokens both produced an empty reply.
        for mode in [ThinkingMode.minimal, .low, .medium, .high, .unlimited] {
            var spec = AgentSpec.seat(index: 0)
            spec.thinking = mode
            spec.maxTokens = 100
            #expect(spec.serverOutputCap >= 4_096, "\(mode) needs headroom for reasoning")
        }
    }

    @Test("A generous answer budget is not lowered")
    func largeBudgetIsKept() {
        var spec = AgentSpec.seat(index: 0)
        spec.thinking = .medium
        spec.maxTokens = 32_768
        #expect(spec.serverOutputCap == 32_768, "the floor must not cap a large budget")
    }

    @Test("Thinking off keeps a smaller floor, since nothing is being reasoned")
    func offKeepsSmallerCeiling() {
        var spec = AgentSpec.seat(index: 0)
        spec.thinking = .off
        spec.maxTokens = 60
        // Still floored: even with no reasoning the ceiling counts every output token, and a
        // 60-token cap truncated an answer mid-sentence when measured.
        #expect(spec.serverOutputCap == 1_024)
        #expect(spec.serverOutputCap < 4_096, "off should not pay the reasoning headroom")
    }
}
