// ChatBotsCoreTests — the Responses API request we actually put on the wire
//
// The parameters a server accepts vary: OpenAI validates strictly and rejects unknown
// keys, while local engines accept extensions. Sending the wrong set is either a 400 or a
// silently-ignored setting, so the shape of the body is worth asserting rather than
// assuming.

import ChatBotsCore
import Foundation
import Testing

@Suite("OpenAI Responses request")
struct OpenAIResponsesTests {

    private func request() -> OpenAIResponsesClient.Request {
        OpenAIResponsesClient.Request(
            instructions: "You are a participant.",
            input: "Why are bird eggs ovoid?",
            temperature: 1.0,
            topP: 0.95,
            topK: 20,
            minP: 0.0,
            presencePenalty: -1.5,
            repetitionPenalty: 1.0,
            maxOutputTokens: 1_000,
            includeReasoning: true,
            reasoningEffort: "medium"
        )
    }

    @Test("A strict endpoint receives only parameters in OpenAI's schema")
    func strictBody() {
        let client = OpenAIResponsesClient(
            endpoint: OpenAIEndpoint(
                baseURL: "https://api.openai.com", model: "gpt-4o-mini",
                compatibility: .strict))
        let body = client.body(for: request())

        // Extensions OpenAI would reject.
        #expect(body["top_k"] == nil)
        #expect(body["min_p"] == nil)
        #expect(body["repetition_penalty"] == nil)

        // The parts of the schema that do apply.
        #expect(body["model"] as? String == "gpt-4o-mini")
        #expect(body["instructions"] as? String == "You are a participant.")
        #expect(body["input"] as? String == "Why are bird eggs ovoid?")
        #expect(body["stream"] as? Bool == true)
        #expect(body["temperature"] as? Double == 1.0)
        #expect(body["top_p"] as? Double == 0.95)
        #expect(body["max_output_tokens"] as? Int == 1_000)
    }

    @Test("An extended endpoint also receives the local-only parameters")
    func extendedBody() {
        let client = OpenAIResponsesClient(
            endpoint: OpenAIEndpoint(
                baseURL: "http://localhost:1234", model: "qwen35",
                compatibility: .extended))
        let body = client.body(for: request())

        #expect(body["top_k"] as? Int == 20)
        #expect(body["min_p"] as? Double == 0.0)
        #expect(body["repetition_penalty"] as? Double == 1.0)
    }

    @Test("The presence penalty is flipped to OpenAI's sign convention")
    func presencePenaltySign() {
        // The seat stores MLX's signed value (negative discourages repetition). OpenAI
        // takes the opposite sign, so a negative seat value must go out positive.
        for compatibility in APICompatibility.allCases {
            let client = OpenAIResponsesClient(
                endpoint: OpenAIEndpoint(
                    baseURL: "http://localhost:1234", model: "m",
                    compatibility: compatibility))
            let body = client.body(for: request())
            #expect(body["presence_penalty"] as? Double == 1.5, "\(compatibility)")
        }
    }

    @Test("Reasoning is only requested when thinking is on")
    func reasoningRequested() {
        var quiet = request()
        quiet.includeReasoning = false
        quiet.reasoningEffort = nil
        let client = OpenAIResponsesClient(
            endpoint: OpenAIEndpoint(baseURL: "http://localhost:1234", model: "m"))

        let body = client.body(for: quiet)
        #expect(body["reasoning"] == nil)
        #expect(body["include"] == nil)

        let thinking = client.body(for: request())
        #expect(thinking["include"] != nil)
        #expect((thinking["reasoning"] as? [String: String])?["effort"] == "medium")
    }

    @Test("Compatibility is inferred from the URL, defaulting to permissive for localhost")
    func compatibilityInference() {
        #expect(APICompatibility.inferred(fromBaseURL: "https://api.openai.com") == .strict)
        #expect(APICompatibility.inferred(fromBaseURL: "https://api.openai.com/v1") == .strict)
        #expect(APICompatibility.inferred(fromBaseURL: "http://localhost:1234") == .extended)
        #expect(APICompatibility.inferred(fromBaseURL: "http://127.0.0.1:8080") == .extended)
        #expect(APICompatibility.inferred(fromBaseURL: "http://192.168.1.9:1234") == .extended)
        #expect(APICompatibility.inferred(fromBaseURL: "https://openrouter.ai/api") == .strict)
    }

    @Test("A /v1 URL and a bare URL both resolve to one responses endpoint")
    func endpointURL() {
        let bare = OpenAIEndpoint(baseURL: "http://localhost:1234")
        let withV1 = OpenAIEndpoint(baseURL: "http://localhost:1234/v1")
        let trailing = OpenAIEndpoint(baseURL: "http://localhost:1234/v1/")
        let openai = OpenAIEndpoint(baseURL: "https://api.openai.com/v1")

        #expect(bare.responsesURL?.absoluteString == "http://localhost:1234/v1/responses")
        #expect(withV1.responsesURL?.absoluteString == "http://localhost:1234/v1/responses")
        #expect(trailing.responsesURL?.absoluteString == "http://localhost:1234/v1/responses")
        #expect(openai.responsesURL?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(OpenAIEndpoint(baseURL: "   ").responsesURL == nil)
    }

    @Test("A strict endpoint without a key is flagged before a request is attempted")
    func missingKeyDetection() {
        let noKey = OpenAIEndpoint(
            baseURL: "https://api.openai.com", model: "gpt-4o-mini", compatibility: .strict)
        #expect(noKey.isMissingKey)

        var withKey = noKey
        withKey.apiKey = "sk-test"
        #expect(!withKey.isMissingKey)

        // A local server needs no key even though it has no key.
        let local = OpenAIEndpoint(
            baseURL: "http://localhost:1234", model: "qwen35", compatibility: .extended)
        #expect(!local.isMissingKey)
    }

    @Test("Saved settings from before the compatibility field still decode")
    func decodesOlderSettings() throws {
        // The shape written by an earlier build: no `compatibility` key.
        let json = #"{"baseURL":"https://api.openai.com","model":"gpt-4o-mini"}"#
        let endpoint = try JSONDecoder().decode(OpenAIEndpoint.self, from: Data(json.utf8))
        #expect(endpoint.compatibility == .strict, "inferred from the URL, not defaulted blindly")
        #expect(endpoint.model == "gpt-4o-mini")
    }

    @Test("A model name is shown shortened, or left alone when there is nothing to strip")
    func shortModelName() {
        #expect(
            OpenAIEndpoint(model: "mlx-community/Qwen3.5-4B-MLX-4bit").shortModelName
                == "Qwen3.5-4B")
        #expect(OpenAIEndpoint(model: "gpt-4o-mini").shortModelName == "gpt-4o-mini")
    }

    @Test("SSE lines are parsed only when they carry data")
    func sseDataParsing() {
        #expect(OpenAIResponsesClient.dataPayload(from: "data: {\"a\":1}") == "{\"a\":1}")
        #expect(OpenAIResponsesClient.dataPayload(from: "data:{}") == "{}")
        // Event names, comments and blanks are not payloads.
        #expect(OpenAIResponsesClient.dataPayload(from: "event: response.created") == nil)
        #expect(OpenAIResponsesClient.dataPayload(from: ": keep-alive") == nil)
        #expect(OpenAIResponsesClient.dataPayload(from: "") == nil)
        #expect(OpenAIResponsesClient.dataPayload(from: "data:   ") == nil)
    }
}
