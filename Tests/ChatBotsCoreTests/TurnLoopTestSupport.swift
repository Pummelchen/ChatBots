// ChatBotsCoreTests — the stubs a turn-loop test drives the real loop with.
//
// A scripted `Generation` list, the recorders that capture what the loop sent and emitted, and the
// helpers that build a turn. Shared by `TurnLoopModelTests` and `TurnLoopRuleTests`, which used to be
// two suites of one 734-line file.

import Foundation
import MLXLMCommon
import Synchronization
import Testing

@testable import ChatBotsCore

/// The stubs, recorders and fixtures the turn-loop suites drive the real loop with.
///
/// Namespaced so the shared helpers cannot collide with a private one in another test file.
enum TurnLoopHarness {

    actor ScriptedRounds {
        private var rounds: [[Generation]]
        private var prompts: [MLXEngine.RoundPrompt] = []

        init(_ rounds: [[Generation]]) { self.rounds = rounds }

        func stream(for prompt: MLXEngine.RoundPrompt) -> AsyncThrowingStream<Generation, Error> {
            prompts.append(prompt)
            let script = rounds.isEmpty ? [] : rounds.removeFirst()
            return AsyncThrowingStream<Generation, Error> { continuation in
                for generation in script { continuation.yield(generation) }
                continuation.finish()
            }
        }

        func recorded() -> [MLXEngine.RoundPrompt] { prompts }
    }

    /// Everything the turn emitted, in order.
    final class EventRecorder: Sendable {
        private let storage = Mutex<[TurnEvent]>([])

        func record(_ event: TurnEvent) { storage.withLock { $0.append(event) } }
        var events: [TurnEvent] { storage.withLock { $0 } }

        var tokens: [String] {
            events.compactMap { if case .token(_, let text) = $0 { return text } else { return nil } }
        }
        var reasoning: [String] {
            events.compactMap {
                if case .reasoning(_, let text) = $0 { return text } else { return nil }
            }
        }
        var failures: [(name: String, message: String)] {
            events.compactMap {
                if case .toolFailure(_, let name, let message) = $0 { return (name, message) }
                return nil
            }
        }
        var finished: [(text: String, stats: TurnStats)] {
            events.compactMap {
                if case .turnFinished(_, let text, let stats) = $0 { return (text, stats) }
                return nil
            }
        }
        var toolResults: [(name: String, summary: String, detail: String)] {
            events.compactMap {
                if case .toolResult(_, let name, let summary, let detail) = $0 {
                    return (name, summary, detail)
                }
                return nil
            }
        }
    }

    /// The tool calls the loop reported before dispatch.
    final class CallRecorder: Sendable {
        private let storage = Mutex<[(name: String, argument: String)]>([])
        func record(_ name: String, _ argument: String) {
            storage.withLock { $0.append((name, argument)) }
        }
        var calls: [(name: String, argument: String)] { storage.withLock { $0 } }
    }

    /// A tool that records what it was asked, so "it ran" is a fact rather than an inference.
    final class StubTool: ToolProvider {
        let name: String
        let description = "a tool used by the turn-loop tests"
        let argumentName = "query"
        let argumentDescription = "what to look up"
        private let received = Mutex<[String]>([])

        init(name: String) { self.name = name }

        var arguments: [String] { received.withLock { $0 } }

        func run(argument: String) async throws -> ToolOutcome {
            received.withLock { $0.append(argument) }
            return ToolOutcome(text: "result for \(argument)", summary: "\(name) ran")
        }
    }

    /// A 1×1 PNG, so the image path carries real decodable bytes.
    static let tinyPNG: Data = {
        guard
            let data = Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
            )
        else {
            Issue.record("the fixture PNG is not valid base64")
            return Data()
        }
        return data
    }()

    // MARK: - Fixtures

    static func spec(
        id: String = "Agent 1",
        displayName: String = "Mira",
        thinking: ThinkingMode = .off
    ) -> AgentSpec {
        AgentSpec(
            id: id, displayName: displayName, maxTokens: 512, contextWindow: 32_768,
            webSearchEnabled: true, thinking: thinking)
    }

    static func settings(
        _ spec: AgentSpec, thinking: ThinkingMode? = nil, contextWindow: Int? = 32_768
    ) -> TurnSettings {
        TurnSettings(spec: spec, thinking: thinking ?? spec.thinking, contextWindow: contextWindow)
    }

    static func info(
        prompt: Int = 10, generation: Int = 4, generateTime: Double = 2
    ) -> GenerateCompletionInfo {
        GenerateCompletionInfo(
            promptTokenCount: prompt, generationTokenCount: generation,
            promptTime: 0.5, generationTime: generateTime, stopReason: .stop)
    }

    static func call(_ name: String, argument: String, id: String) -> ToolCall {
        ToolCall(
            function: .init(name: name, arguments: ["query": .string(argument)]), id: id)
    }

    /// Run one turn through the real loop with a scripted model.
    @discardableResult
    static func performTurn(
        engine: MLXEngine,
        settings turnSettings: TurnSettings,
        messages: [PromptMessage],
        tools: [any ToolProvider] = [],
        images: [Data] = [],
        rounds: ScriptedRounds,
        events: EventRecorder,
        calls: CallRecorder = CallRecorder()
    ) async throws -> String {
        try await engine.runTurn(
            settings: turnSettings,
            messages: messages,
            tools: tools,
            images: images,
            makeStream: { await rounds.stream(for: $0) },
            onToolCall: { name, argument in calls.record(name, argument) },
            onEvent: { events.record($0) })
    }
}
