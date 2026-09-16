// ChatBotsCore — sampling settings, the reasoning ceiling and the headroom they need
//
// Split out of `MLXEngine.swift`, which held the engine, its sampling settings, its text assembler and
// its supporting actors in one 942-line file. The types did not change.

import Foundation

public struct TurnSettings: Sendable, Equatable {
    public var agentID: String
    public var modelID: String
    public var displayName: String
    public var answerBudget: Int
    public var thinking: ThinkingMode
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var minP: Double
    public var presencePenalty: Double?
    public var repetitionPenalty: Double?
    public var seed: UInt64
    /// The model's context window, once it is known. Only `.unlimited` uses it, to size its
    /// headroom without asking MLX for an infinite cap.
    public var contextWindow: Int?

    public init(spec: AgentSpec, thinking: ThinkingMode, contextWindow: Int?) {
        self.agentID = spec.id
        self.modelID = spec.modelID
        self.displayName = spec.displayName
        self.answerBudget = spec.maxTokens
        self.thinking = thinking
        self.temperature = spec.temperature
        self.topP = spec.topP
        self.topK = spec.topK
        self.minP = spec.minP
        self.presencePenalty = spec.presencePenalty
        self.repetitionPenalty = spec.repetitionPenalty
        self.seed = spec.samplingSeed
        self.contextWindow = contextWindow
    }

    /// Total tokens the model may emit: the answer budget plus reasoning headroom.
    public var generationCap: Int {
        MLXEngine.generationCap(
            answerBudget: answerBudget, thinking: thinking, contextWindow: contextWindow)
    }

    /// How this turn's thinking level is expressed to the chat template.
    public var templateContext: [String: any Sendable] { thinking.templateContext }
}

/// Accumulates a turn's reasoning and enforces the mode's ceiling.
///
/// The pinned MLX release has no budget-transition API, so the ceiling is a stop condition
/// the engine applies to its own stream rather than something the model is told about. The
/// budget is counted in roughly 4-characters-per-token units, which is accurate enough for
/// "think less" and needs no tokenizer round trip from the generation loop.
public struct ReasoningCeiling: Sendable, Equatable {
    public let mode: ThinkingMode
    public let ceiling: Int?
    /// Characters of reasoning seen so far. `tokens` is derived from this rather than accumulated
    /// per chunk, so the remainder is carried instead of discarded.
    private var characters = 0
    public private(set) var wasReached = false

    /// The reasoning counted so far, in the roughly-4-characters-per-token units the budget uses.
    public var tokens: Int { characters / 4 }

    public init(mode: ThinkingMode) {
        self.mode = mode
        self.ceiling = mode.reasoningTokenBudget
    }

    /// Account for one reasoning segment. Returns `true` the first time the ceiling is
    /// reached, and `false` on every later call, so the caller acts exactly once.
    ///
    /// Characters are accumulated and converted once. This used to add `reasoning.count / 4` per
    /// call, which is **zero for any segment shorter than four characters** — and a generation
    /// stream emits one token per call, most of them one to three characters — so `tokens` never
    /// grew, the ceiling never fired, and `.minimal`/`.low`/`.medium` behaved as if they were
    /// unlimited. The old behaviour was invisible to the tests because they feed 200-character
    /// segments, for which `/4` happens to be non-zero.
    public mutating func account(reasoning: String) -> Bool {
        guard !wasReached, let ceiling, ceiling > 0, !reasoning.isEmpty else { return false }
        characters += reasoning.count
        guard tokens >= ceiling else { return false }
        wasReached = true
        return true
    }
}

/// Splits decoded chunks into reasoning and answer, enforcing the mode's ceiling.
///
/// This is the engine's per-chunk text handling, extracted so the ceiling path is testable
/// without weights. Hitting the ceiling used to append a closing delimiter to the
/// answer and then abandoned the stream: the model never saw the delimiter, the answer
/// stayed empty, and the notice claimed the model had answered from the cut-off.
