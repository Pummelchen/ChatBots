// ChatBotsCoreTests — a reported failure ends the read, it does not wait out the timeout
//
// `response.failed` and `response.incomplete` yielded `.failed` but did not leave the read
// loop, so a server that reported a failure and then held the connection open kept the turn
// alive until the 600-second request timeout: a user waited ten minutes for an answer the server
// had already given. The same shape applied to a top-level `error` event. The terminal-event
// requirement makes the path more relevant rather than less — a stream with no terminal event is
// now a failure the reader must conclude rather than wait out.
//
// The distinguishing assertion is what arrives AFTER the failure. The scripted server's body
// ends, so a reader that stops at the failure never sees the trailing events; the pre-fix reader
// consumed them, and with them a `response.completed` that would have reported usage for a
// failed turn.

import Foundation
import Testing

@testable import ChatBotsCore

@MainActor
@Suite("A reported failure ends the read")
struct CLIStreamTerminationTests {

    private func request() -> OpenAIResponsesClient.Request {
        OpenAIResponsesClient.Request(input: "Say hello.")
    }

    /// Everything the scripted server sends, with the terminal event in the middle. Anything
    /// the reader emits from after the failure is evidence that it kept reading.
    private static func failureThenTrailing(_ failure: String) -> Data {
        sse([
            sseTextDelta("before"),
            failure,
            sseTextDelta("after"),
            sseCompleted(inputTokens: 99, outputTokens: 99),
            "[DONE]",
        ])
    }

    private func collect(
        _ body: Data
    ) async throws -> (text: String, failures: [String], completions: Int) {
        let server = try await ScriptedOpenAIServer(responsesBody: body)
        defer { server.stop() }
        let client = OpenAIResponsesClient(endpoint: scriptedEndpoint(port: server.port))
        var text = ""
        var failures: [String] = []
        var completions = 0
        for try await event in client.stream(request()) {
            switch event {
            case .text(let delta): text += delta
            case .failed(let message): failures.append(message)
            case .completed: completions += 1
            case .reasoning: break
            }
        }
        return (text, failures, completions)
    }

    @Test("response.failed ends the read instead of consuming what follows")
    func failedEndsTheRead() async throws {
        let result = try await collect(
            Self.failureThenTrailing(
                #"{"type":"response.failed","response":{"error":{"message":"the model crashed"}}}"#))
        #expect(result.failures == ["the model crashed"])
        #expect(result.text == "before", "text after the failure must not be read")
        #expect(result.completions == 0, "a completion after the failure must not be read")
    }

    @Test("response.incomplete ends the read instead of consuming what follows")
    func incompleteEndsTheRead() async throws {
        let result = try await collect(
            Self.failureThenTrailing(
                #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#))
        #expect(result.failures == ["incomplete: max_output_tokens"])
        #expect(result.text == "before", "text after the failure must not be read")
        #expect(result.completions == 0, "a completion after the failure must not be read")
    }

    @Test("A top-level error event ends the read too")
    func errorEndsTheRead() async throws {
        let result = try await collect(
            Self.failureThenTrailing(#"{"type":"error","message":"the server gave up"}"#))
        #expect(result.failures == ["the server gave up"])
        #expect(result.text == "before", "text after the failure must not be read")
        #expect(result.completions == 0, "a completion after the failure must not be read")
    }
}
