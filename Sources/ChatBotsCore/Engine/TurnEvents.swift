// ChatBotsCore — what happens during a turn, streamed to the front ends
//
// Split out of `ChatModels.swift`, which held the whole shared vocabulary in one 862-line file. The
// types did not change; only the file each one lives in did.

import Foundation

// MARK: - Events

/// Everything interesting that happens during a turn, streamed to the UI.
public enum TurnEvent: Sendable {
    /// A turn is about to begin. `prompt` is the exact message list sent to the engine.
    case turnStarted(agentID: String, prompt: [PromptMessage])
    /// Visible answer text.
    case token(agentID: String, text: String)
    /// `<think>` block text. Displayed collapsed, never fed back into history.
    case reasoning(agentID: String, text: String)
    /// The model asked for a web tool.
    case toolCall(agentID: String, name: String, query: String)
    /// Result of that tool, truncated for display.
    case toolResult(agentID: String, name: String, summary: String, detail: String)
    /// A tool failed; the model is told so and carries on.
    case toolFailure(agentID: String, name: String, message: String)
    /// The turn produced its final text.
    case turnFinished(agentID: String, text: String, stats: TurnStats)
    /// The turn ended badly; the loop decides whether to continue.
    case turnFailed(agentID: String, message: String)
}

/// Throughput information for one turn.
public struct TurnStats: Sendable, Hashable, Codable {
    public var promptTokens: Int
    /// Seconds spent prefilling the prompt, before the first token appeared.
    public var prefillSeconds: Double
    /// Prompt tokens processed per second during prefill — the number that decides how
    /// long a long conversation takes to get going.
    public var prefillTokensPerSecond: Double {
        prefillSeconds > 0 ? Double(promptTokens) / prefillSeconds : 0
    }

    public var generationTokens: Int
    public var cachedPromptTokens: Int
    public var stopReason: String
    public var tokensPerSecond: Double
    public var seconds: Double

    public init(
        promptTokens: Int = 0,
        prefillSeconds: Double = 0,
        generationTokens: Int = 0,
        cachedPromptTokens: Int = 0,
        stopReason: String = "",
        tokensPerSecond: Double = 0,
        seconds: Double = 0
    ) {
        self.promptTokens = promptTokens
        self.prefillSeconds = prefillSeconds
        self.generationTokens = generationTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.stopReason = stopReason
        self.tokensPerSecond = tokensPerSecond
        self.seconds = seconds
    }
}

/// A message as it will be rendered by the model's chat template.
///
/// Kept as our own type rather than `Chat.Message` so the core stays independent of
