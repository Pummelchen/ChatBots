// ChatBotsCore — splitting `<think>` reasoning from the visible answer
//
// The released MLXLMCommon splits reasoning only inside its FoundationModels adapter,
// so the raw `ChatSession` stream mixes `<think>` text with the answer. Rather than
// depend on that adapter, the split lives here: it is a pure state machine, so it is
// unit-tested without a model, and the transcript can never accidentally contain a
// model's private monologue.

import Foundation

/// How a seat treats a reasoning model's thinking block.
public enum ReasoningMode: String, Sendable, Codable, CaseIterable {
    /// Let the model think; the `<think>` text is routed to the UI as `.reasoning`
    /// and never written to the shared log.
    case stream
    /// Ask the template to disable thinking entirely (`enable_thinking: false`).
    case off
    /// Keep thinking on but discard it — neither shown nor logged.
    case discard

    /// The chat-template flag for this mode, or `nil` to leave the template default.
    public var templateContext: [String: any Sendable]? {
        switch self {
        case .off: ["enable_thinking": false]
        case .stream, .discard: ["enable_thinking": true]
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
