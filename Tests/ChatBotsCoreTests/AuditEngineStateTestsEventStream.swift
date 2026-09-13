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

/// Read the stream until it stops producing, then stop.
///
/// The producer has already finished by the time this is called, so what is buffered is what the
/// stream holds — but the *reader* still has to be scheduled, and a fixed window was a race against
/// whatever else the machine was doing. On a loaded host this test reported 172 events, and once 7,
/// against an expected 256 (A108). Reading until nothing new has arrived for a quiet period is a
/// property of the stream rather than of the machine's load.
@MainActor
private func drain(_ stream: AsyncStream<TurnEvent>) async -> [TurnEvent] {
    let recorder = EventRecorder()
    let reader = Task {
        for await event in stream { await recorder.record(event) }
    }
    // 50 ms per step, giving up after eight steps with nothing new: 400 ms of quiet.
    let step = Duration.milliseconds(50)
    let quietSteps = 8
    var lastCount = 0
    var quiet = 0
    while quiet < quietSteps {
        try? await Task.sleep(for: step)
        let count = await recorder.events.count
        if count == lastCount {
            quiet += 1
        } else {
            quiet = 0
            lastCount = count
        }
    }
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

        let received = await drain(engine.events)

        // The bound matches the one the WebTransport server gives each client
        // (`WebTransportServer.swift`: `.bufferingNewest(256)`).
        #expect(
            received.count == 256,
            "the stream handed back \(received.count) events; an unobserved buffer keeps the newest 256 and no more")

        // Newest-kept, so the end of the run — the part a live consumer cares about — is what
        // survives a fall-behind, and the terminal event is not the casualty.
        if case .turnFinished = received.last {
            // expected
        } else {
            Issue.record("the surviving buffer did not end with the turn's terminal event")
        }
    }
}
