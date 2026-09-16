// ChatBotsCore — assembling a turn's text from the model's stream
//
// Split out of `MLXEngine.swift`, which held the engine, its sampling settings, its text assembler and
// its supporting actors in one 942-line file. The types did not change.

import Foundation

public struct TurnTextAssembler: Sendable {
    private var stripper: ThinkingStripper
    private var ceiling: ReasoningCeiling

    /// The answer text seen so far. The forced delimiter is deliberately not part of it.
    public private(set) var answer = ""
    /// True once any reasoning text has been produced.
    public private(set) var sawReasoning = false
    /// True once the mode's reasoning ceiling ended the turn.
    public private(set) var ceilingReached = false

    public init(thinking: ThinkingMode) {
        self.stripper = ThinkingStripper(startsPrimed: thinking.thinks)
        self.ceiling = ReasoningCeiling(mode: thinking)
    }

    /// What one chunk produced.
    public struct Step: Sendable, Equatable {
        public var reasoning: String
        public var answer: String
        /// Set on the chunk that reached the ceiling, so the caller stops the stream.
        public var ceilingReached: Bool
    }

    /// Process one decoded chunk.
    ///
    /// When the ceiling is reached the closing delimiter is run through the stripper, so
    /// reasoning it was holding back is still attributed and reported, but the model never
    /// sees it — the stream is abandoned and no answer can follow.
    public mutating func consume(_ chunk: String) -> Step {
        let segment = stripper.process(chunk)
        var step = Step(reasoning: segment.reasoning, answer: segment.answer, ceilingReached: false)
        if !segment.reasoning.isEmpty { sawReasoning = true }
        answer += segment.answer

        if ceiling.account(reasoning: segment.reasoning), stripper.isInsideReasoning {
            ceilingReached = true
            step.ceilingReached = true
            let closed = stripper.process(MLXEngine.forcedThinkingExit)
            step.reasoning += closed.reasoning
            step.answer += closed.answer
            answer += closed.answer
            if !closed.reasoning.isEmpty { sawReasoning = true }
        }
        return step
    }

    /// Flush text held back for delimiter matching once the stream ends.
    public mutating func finish() -> Step {
        let tail = stripper.finalize()
        if !tail.reasoning.isEmpty { sawReasoning = true }
        answer += tail.answer
        return Step(reasoning: tail.reasoning, answer: tail.answer, ceilingReached: false)
    }
}

/// The mode's reasoning ceiling ended the turn before the model produced an answer.
///
/// Thrown rather than returning an empty string, so a caller cannot present the truncated
/// turn as a successful empty answer; `ConversationEngine` turns the throw into a
/// `turnFailed` event.
public struct ReasoningCeilingError: LocalizedError, Sendable, Equatable {
    public let mode: ThinkingMode
    public let ceiling: Int

    public init(mode: ThinkingMode, ceiling: Int) {
        self.mode = mode
        self.ceiling = ceiling
    }

    public var errorDescription: String? {
        MLXEngine.reasoningCeilingNotice(mode: mode, ceiling: ceiling, producedAnswer: false)
    }
}
