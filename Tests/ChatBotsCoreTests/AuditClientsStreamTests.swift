// ChatBotsCoreTests — a truncated stream is not a finished turn (audit A54)
//
// The client's own header says "a completed stream is the only thing that counts as success",
// but nothing required completion: the loop ended at EOF or at `data: [DONE]` and emitted
// whatever text had arrived, and `sawText` was computed and then discarded. `generate` then
// recorded the fragment as a normal turn with `stopReason` "stop" and zero usage, so the token
// statistics silently became 0 and a half answer was indistinguishable from a whole one.
//
// These tests drive the real client and the real engine against a scripted local server whose
// stream ends where the test says it does, so "the connection stopped early" is produced by the
// transport rather than simulated.

import ChatBotsCore
import Foundation
import Testing

@MainActor
@Suite("A truncated stream is not a finished turn (audit A54)")
struct AuditClientsStreamTests {

    /// A delta followed by the terminal event: the success path, and the premise the rest of
    /// the file is measured against.
    private static let completedStream = sse([
        sseTextDelta("Hello"),
        sseCompleted(inputTokens: 7, outputTokens: 2),
        "[DONE]",
    ])

    /// A server that says it finished and produced nothing: the answer is empty, which is a failed
    /// turn rather than a finished one (A202).
    private static let completedWithoutText = sse([
        sseCompleted(inputTokens: 7, outputTokens: 0),
        "[DONE]",
    ])

    /// The finding: the same delta, and then the body simply ends.
    private static let truncatedStream = sse([sseTextDelta("Hello")])

    /// `data: [DONE]` with no completed event — the other way the loop can end without the
    /// server ever saying it finished.
    private static let doneWithoutCompletion = sse([sseTextDelta("Hello"), "[DONE]"])

    /// An explicit failure, which must keep its own reason rather than be replaced by the
    /// truncation error.
    private static let failedStream = sse([
        sseTextDelta("Hello"),
        #"{"type":"response.failed","response":{"error":{"message":"the model crashed"}}}"#,
    ])

    private func request() -> OpenAIResponsesClient.Request {
        OpenAIResponsesClient.Request(input: "Say hello.")
    }

    @Test("A stream that completes yields its text, its usage and no error")
    func completedStreamSucceeds() async throws {
        let server = try await ScriptedOpenAIServer(responsesBody: Self.completedStream)
        defer { server.stop() }
        let client = OpenAIResponsesClient(endpoint: scriptedEndpoint(port: server.port))

        var text = ""
        var usage: OpenAIUsage?
        for try await event in client.stream(request()) {
            switch event {
            case .text(let delta): text += delta
            case .completed(let reported): usage = reported
            case .reasoning, .failed: break
            }
        }

        #expect(text == "Hello")
        #expect(usage?.inputTokens == 7)
        #expect(usage?.outputTokens == 2)
    }

    @Test("A stream that ends mid-reply throws instead of finishing")
    func truncatedStreamThrows() async throws {
        let server = try await ScriptedOpenAIServer(responsesBody: Self.truncatedStream)
        defer { server.stop() }
        let client = OpenAIResponsesClient(endpoint: scriptedEndpoint(port: server.port))

        var text = ""
        var thrown: (any Error)?
        do {
            for try await event in client.stream(request()) {
                if case .text(let delta) = event { text += delta }
            }
        } catch {
            thrown = error
        }

        let error = try #require(thrown, "a stream that never completed must not be accepted")
        #expect(error is OpenAIResponsesError)
        #expect(
            error.localizedDescription.contains("incomplete"),
            "the error should say the reply was cut off, not report a finished turn")
        #expect(text == "Hello", "the fragment arrived before the cut, which is why it is a trap")
    }

    @Test("`data: [DONE]` alone is not a completed response")
    func doneWithoutCompletionThrows() async throws {
        let server = try await ScriptedOpenAIServer(responsesBody: Self.doneWithoutCompletion)
        defer { server.stop() }
        let client = OpenAIResponsesClient(endpoint: scriptedEndpoint(port: server.port))

        var thrown: (any Error)?
        do {
            for try await _ in client.stream(request()) {}
        } catch {
            thrown = error
        }
        #expect(thrown is OpenAIResponsesError, "[DONE] ended the loop but nothing completed")
    }

    @Test("An explicit failure keeps the server's own reason")
    func explicitFailureIsNotReplaced() async throws {
        let server = try await ScriptedOpenAIServer(responsesBody: Self.failedStream)
        defer { server.stop() }
        let client = OpenAIResponsesClient(endpoint: scriptedEndpoint(port: server.port))

        var failures: [String] = []
        // No throw: the failure is delivered as an event and the caller decides. What matters is
        // that the truncation rule does not overwrite it with a vaguer message.
        for try await event in client.stream(request()) {
            if case .failed(let message) = event { failures.append(message) }
        }
        #expect(failures == ["the model crashed"])
    }

    /// An empty answer must fail the turn rather than finish it.
    ///
    /// The engine emitted `turnFailed` and then `turnFinished` unconditionally, and the orchestrator
    /// records what the events say — so an empty turn was recorded as completed with no text, and
    /// `record(.turnFinished)` cleared the failure it had just been handed (A202).
    @Test("An empty answer fails the turn instead of finishing it")
    func emptyAnswerFailsTheTurn() async throws {
        let server = try await ScriptedOpenAIServer(responsesBody: Self.completedWithoutText)
        defer { server.stop() }
        let engine = OpenAIResponsesEngine(spec: scriptedSpec(port: server.port))

        // An actor, because `onEvent` is `@Sendable` and a captured `var` cannot be mutated from it.
        let recorder = TerminalEventRecorder()
        var thrown: (any Error)?
        do {
            _ = try await engine.generate(
                messages: [PromptMessage(role: .user, content: "Say hello.")],
                tools: [],
                onToolCall: { _, _ in },
                onEvent: { event in await recorder.record(event) })
        } catch {
            thrown = error
        }

        let events = await recorder.events
        #expect(thrown != nil, "a turn that produced no text must not return success")
        #expect(events == ["failed"], "and it must not also be announced as finished, was \(events)")
        let stats = await engine.lastStats
        #expect(stats == nil, "a failed turn records no statistics")
    }

    /// The consequence the finding names: the engine used to record the fragment as a normal
    /// turn. The assertion is on `lastStats` — pre-fix it is a `stop` with zero usage, post-fix
    /// the turn throws before any statistics are recorded.
    @Test("The engine does not record a truncated stream as a finished turn")
    func engineDoesNotRecordATruncatedTurn() async throws {
        let server = try await ScriptedOpenAIServer(responsesBody: Self.truncatedStream)
        defer { server.stop() }
        let engine = OpenAIResponsesEngine(spec: scriptedSpec(port: server.port))

        var thrown: (any Error)?
        do {
            _ = try await engine.generate(
                messages: [PromptMessage(role: .user, content: "Say hello.")],
                tools: [],
                onToolCall: { _, _ in },
                onEvent: { _ in })
        } catch {
            thrown = error
        }

        #expect(thrown != nil, "a truncated stream must fail the turn")
        let stats = await engine.lastStats
        #expect(stats == nil, "a truncated turn must not be reported as a stop with zero usage")
    }
}

/// Collects a turn's terminal events. An actor because the engine's callback is `@Sendable`.
private actor TerminalEventRecorder {
    private(set) var events: [String] = []

    func record(_ event: TurnEvent) {
        switch event {
        case .turnFailed: events.append("failed")
        case .turnFinished: events.append("finished")
        default: break
        }
    }
}
