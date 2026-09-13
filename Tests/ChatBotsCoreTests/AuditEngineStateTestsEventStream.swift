// ChatBotsCoreTests — A41: an unobserved event stream must not grow without bound
//
// `engine.events` was `.unbounded`. Nothing in the app iterates it — the HTTP and
// WebTransport servers subscribe with `observeEvents` — so with no reader the continuation
// retained every event for the life of the process, including one full prompt per
// `.turnStarted`. This drives a run that emits far more events than the buffer holds without
// ever touching the stream, then reads it and asserts what survived is bounded.

import ChatBotsCore
import Foundation
import Testing

/// Emits a burst of token events per turn, like a real generation does.
private actor ChattyEngine: LLMEngine {
    nonisolated let spec: AgentSpec
    private let burst: Int

    init(spec: AgentSpec, burst: Int) {
        self.spec = spec
        self.burst = burst
    }

    var isLoaded: Bool { true }
    var contextWindow: Int { 32_768 }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}
    func compact(prompt: String, maxTokens: Int) async throws -> String { "" }

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        for index in 0..<burst {
            await onEvent(.token(agentID: spec.id, text: "t\(index) "))
        }
        let text = String(repeating: "word ", count: burst)
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: burst, stopReason: "stop")))
        return text
    }
}

private actor EventRecorder {
    private(set) var events: [TurnEvent] = []
    func record(_ event: TurnEvent) { events.append(event) }
}

@MainActor
private func makeChattyEngine(burst: Int) -> ConversationEngine {
    let spec = AgentSpec.seat(index: 0)
    let stub = ChattyEngine(spec: spec, burst: burst)
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 1
    configuration.autoCompact = false
    return ConversationEngine(
        seats: [.init(spec: spec, engine: stub)], configuration: configuration)
}

/// Read whatever the stream buffered, then stop. Nothing is producing any more by the time
/// this is called, so the count is the buffer's contents.
@MainActor
private func drain(_ stream: AsyncStream<TurnEvent>, for duration: Duration) async -> [TurnEvent] {
    let recorder = EventRecorder()
    let reader = Task {
        for await event in stream { await recorder.record(event) }
    }
    try? await Task.sleep(for: duration)
    reader.cancel()
    return await recorder.events
}

@Suite("An unobserved event stream is bounded")
struct AuditEngineStateEventStreamTests {

    @Test("The buffer holds a bounded number of events, not the whole run")
    @MainActor
    func unobservedStreamIsBounded() async {
        // 400 token events is already more than the 256-event buffer, before the turn
        // events are counted, so an unbounded stream would hand all of them back.
        let engine = makeChattyEngine(burst: 400)
        engine.start(topic: "Why are eggs not round?")
        await engine.waitUntilFinished()

        let received = await drain(engine.events, for: .milliseconds(300))

        // The bound matches the one the WebTransport server gives each client
        // (`WebTransportServer.swift`: `.bufferingNewest(256)`).
        #expect(
            received.count == 256,
            "the stream handed back \(received.count) events; an unobserved buffer is not bounded")

        // Newest-kept, so the end of the run — the part a live consumer cares about — is what
        // survives a fall-behind, and the terminal event is not the casualty.
        if case .turnFinished = received.last {
            // expected
        } else {
            Issue.record("the surviving buffer did not end with the turn's terminal event")
        }
    }
}
