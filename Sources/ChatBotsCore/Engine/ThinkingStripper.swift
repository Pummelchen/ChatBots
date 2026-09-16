// ChatBotsCore — splitting `<think>` reasoning from the visible answer
//
// The released MLXLMCommon splits reasoning only inside its FoundationModels adapter,
// so the raw `ChatSession` stream mixes `<think>` text with the answer. Rather than
// depend on that adapter, the split lives here: it is a pure state machine, so it is
// unit-tested without a model, and the transcript can never accidentally contain a
// model's private monologue.

import Foundation

/// How much a reasoning model is allowed to think before it must answer.
///
/// **Why levels are budgeted rather than requested.** Qwen 3.5's chat template exposes
/// exactly one thinking knob — a boolean `enable_thinking` — and the MLX release this app
/// pins has no budget-transition API, so there is no `reasoning_effort: "low"` to ask
/// for. What *is* controllable is how many tokens of reasoning we permit before closing
/// the block and requiring an answer, so the levels below are real but approximate:
/// a level is a ceiling, and a model that finishes thinking early is unaffected.
///
/// Levels also translate to the nearest native template flag when a checkpoint supports
/// one (`.off` requests `enable_thinking: false`; a checkpoint honouring
/// `reasoning_effort` would receive it), so the same control stays meaningful if a seat is
/// pointed at another model family.
public enum ThinkingMode: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Do not think at all. The template is asked for `enable_thinking: false`.
    case off
    /// A token's worth of deliberation — enough to pick a direction.
    case minimal
    case low
    case medium
    case high
    /// No budget at all: the model thinks until it decides it is done.
    case unlimited

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .unlimited: "Unlimited"
        }
    }

    public var symbol: String {
        switch self {
        case .off: "brain"
        case .minimal: "brain.head.profile"
        case .low: "brain.head.profile"
        case .medium: "brain.head.profile"
        case .high: "brain.head.profile"
        case .unlimited: "infinity"
        }
    }

    /// Ceiling on reasoning tokens, or `nil` when the model decides for itself.
    ///
    /// Calibrated against this app's own measurements: a short factual prompt spends
    /// roughly 250 reasoning tokens, so `minimal`/`low` genuinely bite while `high`
    /// leaves normal answers untouched.
    public var reasoningTokenBudget: Int? {
        switch self {
        case .off: 0
        case .minimal: 128
        case .low: 512
        case .medium: 2_048
        case .high: 8_192
        case .unlimited: nil
        }
    }

    public var thinks: Bool { self != .off }

    /// How this mode is expressed to the chat template.
    ///
    /// `enable_thinking` is the Qwen flag. `reasoning_effort` is included for checkpoints
    /// that understand it; a template that does not reference it ignores the extra key.
    public var templateContext: [String: any Sendable] {
        var context: [String: any Sendable] = ["enable_thinking": thinks]
        switch self {
        case .off:
            context["reasoning_effort"] = "none"
        case .minimal, .low:
            context["reasoning_effort"] = "low"
        case .medium:
            context["reasoning_effort"] = "medium"
        case .high, .unlimited:
            context["reasoning_effort"] = "high"
        }
        return context
    }

    /// One-line description for the control's help text.
    public var detail: String {
        switch self {
        case .off: "No thinking block; answer straight away"
        case .minimal: "Up to 128 reasoning tokens"
        case .low: "Up to 512 reasoning tokens"
        case .medium: "Up to 2,048 reasoning tokens"
        case .high: "Up to 8,192 reasoning tokens"
        case .unlimited: "No budget — think until finished"
        }
    }
}

/// Incrementally separates reasoning text from answer text in a generation stream.
///
/// Handles the Qwen 3.x shape, where the template prefills the *opening* delimiter
/// (`<|im_start|>assistant\n<think>\n`), so the stream begins already inside a
/// reasoning block and only the closing `</think>` is ever generated. `startsPrimed`
/// selects that behaviour; otherwise the stripper waits for an explicit `<think>`.
///
/// Text that might be the beginning of a delimiter is held back until the next chunk
/// resolves it, so a `<thi` + `nk>` split across two tokens is not printed literally.
public struct ThinkingStripper: Sendable {

    public struct Segment: Sendable, Equatable {
        public var reasoning: String
        public var answer: String
    }

    private let startDelimiter: String
    private let endDelimiter: String

    private var insideReasoning: Bool
    private var pending = ""
    private var sawAnyReasoning = false
    /// Set once the opening delimiter has been resolved (consumed or determined absent).
    private var openingResolved: Bool

    public init(
        startDelimiter: String = "<think>",
        endDelimiter: String = "</think>",
        startsPrimed: Bool = true
    ) {
        self.startDelimiter = startDelimiter
        self.endDelimiter = endDelimiter
        self.insideReasoning = startsPrimed
        self.openingResolved = startsPrimed
    }

    public var isInsideReasoning: Bool { insideReasoning }

    /// Process one decoded chunk.
    public mutating func process(_ chunk: String) -> Segment {
        pending += chunk
        var segment = Segment(reasoning: "", answer: "")

        while true {
            if insideReasoning {
                if let range = pending.range(of: endDelimiter) {
                    // Reasoning is display-only, so surrounding template newlines are
                    // trimmed rather than preserved.
                    let thought = String(pending[..<range.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    pending = String(pending[range.upperBound...])
                    if !thought.isEmpty {
                        segment.reasoning += thought
                        sawAnyReasoning = true
                    }
                    insideReasoning = false
                    // Drop a single newline the template puts after </think>.
                    if pending.hasPrefix("\n") { pending.removeFirst() }
                    continue
                }
                // Emit everything except a possible partial delimiter tail.
                let hold = Self.holdbackLength(of: pending, matching: endDelimiter)
                let emitCount = pending.count - hold
                if emitCount > 0 {
                    let text = String(pending.prefix(emitCount))
                    pending = String(pending.dropFirst(emitCount))
                    segment.reasoning += text
                    sawAnyReasoning = true
                }
                break
            }

            // Outside reasoning: resolve the opening delimiter once, then everything is answer.
            if !openingResolved {
                if pending.hasPrefix(startDelimiter) {
                    pending = String(pending.dropFirst(startDelimiter.count))
                    insideReasoning = true
                    continue
                }
                if startDelimiter.hasPrefix(pending) {
                    // Still could become the delimiter; wait for more input.
                    break
                }
                openingResolved = true
                continue
            }

            segment.answer += pending
            pending = ""
            break
        }

        return segment
    }

    /// Flush text held back for delimiter matching. Call once the stream ends.
    public mutating func finalize() -> Segment {
        let held = pending
        pending = ""
        if insideReasoning {
            sawAnyReasoning = sawAnyReasoning || !held.isEmpty
            insideReasoning = false
            return Segment(reasoning: held, answer: "")
        }
        return Segment(reasoning: "", answer: held)
    }

    public var hasReasoning: Bool { sawAnyReasoning }

    /// Length of the suffix of `text` that could be the start of `delimiter`.
    private static func holdbackLength(of text: String, matching delimiter: String) -> Int {
        let maximum = min(text.count, delimiter.count - 1)
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) {
            if text.hasSuffix(String(delimiter.prefix(length))) {
                return length
            }
        }
        return 0
    }
}

/// Detects a model that has fallen into a repetition loop.
///
/// Free-form sampling at a high temperature with a strong presence penalty can drive a
/// small model into a degenerate attractor: the text stops advancing and one phrase
/// repeats, sometimes with a few words varied between passes. Measured on this app with
/// the shipped sampler and thinking disabled, output settled into an 8-gram repeated
/// dozens of times at a distinct-word ratio of 0.10 and would have run to the full
/// 32,768-token cap.
///
/// Rather than paper over that by quietly changing the sampling settings, the loop is
/// detected and the turn ends. Detection has to tolerate the varied-filler form, so it
/// measures **near-repetition rate** over a rolling window: the fraction of recent
/// n-grams that have already been seen in that window. Ordinary prose sits far below the
/// threshold; a degenerate attractor saturates it.
public struct RepetitionDetector: Sendable {
    /// Words per compared phrase.
    private let gram: Int
    /// Recent words kept in the rolling window. Long enough that a slow drift still
    /// re-uses phrases, short enough that genuine long-form writing does not trip it.
    private let windowSize: Int
    /// Fraction of repeated n-grams that counts as degenerate.
    ///
    /// Calibrated on this app's own output: legitimate answers measured 0.00–0.14,
    /// while degenerate attractors measured 0.79–0.91. 0.30 sits in that gap with room
    /// on both sides.
    private let threshold: Double
    /// Don't judge until this many words have been generated.
    private let minimumWords: Int

    private var words: [String] = []

    public init(gram: Int = 8, windowSize: Int = 300, threshold: Double = 0.30, minimumWords: Int = 120) {
        self.gram = gram
        self.windowSize = windowSize
        self.threshold = threshold
        self.minimumWords = minimumWords
    }

    /// The rate measured on the most recent `ingest`, for diagnostics.
    public private(set) var lastRate: Double = 0

    /// Feed generated text. Returns `true` once the output looks degenerate.
    public mutating func ingest(_ text: String) -> Bool {
        words.append(contentsOf: Self.normalise(text))
        if words.count > windowSize {
            words.removeFirst(words.count - windowSize)
        }
        guard words.count >= minimumWords, words.count >= gram * 3 else { return false }

        var seen = Set<[String]>()
        var repeats = 0
        var total = 0
        for start in 0...(words.count - gram) {
            let phrase = Array(words[start..<(start + gram)])
            total += 1
            if !seen.insert(phrase).inserted { repeats += 1 }
        }
        guard total > 0 else { return false }
        lastRate = Double(repeats) / Double(total)
        return lastRate >= threshold
    }

    private static func normalise(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
