// ChatBotsCore — the turn helpers that need no weights
//
// Split out of `MLXEngine.swift`, which held the engine, its loading path and the pure rules its turn
// loop obeys in one file. Everything here is stateless and `static`: the reasoning ceiling's notice, the
// round-advance rule, the fabricated-tool stripper, reply cleaning and the tool-call encoding. Being
// free of the actor's state is what lets them be exercised without loading a model. The code did not
// change.

import Foundation
import MLXLMCommon

extension MLXEngine {

    // MARK: - Helpers

    /// The hard `maxTokens` for one turn.
    ///
    /// A bounded mode adds its reasoning ceiling to the answer budget. `.unlimited` has no
    /// ceiling, but MLX needs a finite cap, so it is given the model's whole context window as
    /// headroom — and never less than `.high`, so choosing a higher level can never reduce the
    /// budget. The old arithmetic, `maxTokens + (nil ?? 0)`, gave unlimited *less* than high.
    ///
    /// Delegates to `ThinkingMode.generationCap`, the single implementation, so this and
    /// `AgentSpec.generationCap` cannot disagree.
    public static func generationCap(
        answerBudget: Int, thinking: ThinkingMode, contextWindow: Int?
    ) -> Int {
        thinking.generationCap(answerBudget: answerBudget, contextWindow: contextWindow)
    }

    /// What the round loop does after one generation round has ended.
    public enum RoundAdvance: Sendable, Equatable {
        /// Run the calls this round collected, then generate again.
        case dispatchTools
        /// The turn is over.
        case endTurn
    }

    /// The most tool calls one turn may dispatch, across every round.
    ///
    /// `roundAdvance`'s `maxToolRounds` bounds the *rounds*, not the calls: one round dispatches
    /// every call the model emitted in that round, so a model that emits a hundred
    /// `<tool_call>` blocks while search budget remains spends a hundred billed calls in a
    /// single turn. The budget is only consulted before a turn starts, so this is the missing
    /// half of the bound. Eight is more than any legitimate research turn has needed (the
    /// offered tool set has two entries and three rounds).
    public static let maximumToolCallsPerTurn = 8

    /// The calls one round may dispatch, given how many this turn has already run.
    ///
    /// Pure so the per-turn bound is testable without weights, like the other turn-loop rules.
    public static func toolCallsWithinBudget<C: Collection>(
        _ calls: C, alreadyDispatched: Int
    ) -> (run: [C.Element], truncated: Bool) {
        let room = max(0, maximumToolCallsPerTurn - alreadyDispatched)
        let run = Array(calls.prefix(room))
        return (run, run.count < calls.count)
    }

    /// Whether a finished round may run the tool calls it collected.
    ///
    /// A round the reasoning ceiling abandoned ends the turn whatever fragments arrived: a
    /// `.toolCall` chunk that came in while the stripper still considered itself inside
    /// reasoning is not a usable instruction, and acting on it would run another round and
    /// spend more of the budget the ceiling exists to bound. This used to fall through to the
    /// same `guard` as an ordinary round, so a protocol-violating model could turn a
    /// ceiling-abandoned turn into another tool round.
    ///
    /// Pure so the rule is testable without weights, like the rest of this section.
    public static func roundAdvance(
        reasoningWasTruncated: Bool,
        toolCallCount: Int,
        hasTools: Bool,
        round: Int,
        maxToolRounds: Int
    ) -> RoundAdvance {
        guard !reasoningWasTruncated else { return .endTurn }
        guard toolCallCount > 0, hasTools, round < maxToolRounds else { return .endTurn }
        return .dispatchTools
    }

    /// The truthful message for a turn the mode's reasoning ceiling cut short.
    ///
    /// The ceiling abandons the stream, so the model never sees the closing delimiter and
    /// cannot answer from it. The old notice claimed the opposite — "the model answered from
    /// there" — on a turn that came back empty.
    public static func reasoningCeilingNotice(
        mode: ThinkingMode, ceiling: Int, producedAnswer: Bool
    ) -> String {
        let level = mode.label.lowercased()
        if producedAnswer {
            return
                "thinking hit the \(level) ceiling (\(ceiling) reasoning tokens) and was cut off; the turn keeps the answer written so far — raise the thinking level to let the model finish before answering"
        }
        return
            "thinking hit the \(level) ceiling (\(ceiling) reasoning tokens) and the turn ended before the model produced an answer — raise the thinking level or turn thinking off"
    }

    /// Text that closes a reasoning block the model would have kept writing.
    ///
    /// Qwen is trained on `<think>…</think>`, and this pinned MLX release offers no
    /// budget-transition API, so ending the block with the delimiter it already knows is
    /// the least surprising way to force an answer. It is a real truncation and the UI
    /// says so.
    static let forcedThinkingExit = "\n</think>\n"

    /// Remove fabricated tool-call syntax the model may have written as plain text.
    ///
    /// Observed once in a long GUI conversation: a seat that had been calling `web_search`
    /// successfully began emitting `[web_search]` / `query: …` as body text, imitating
    /// both the tool protocol and this app's own `[Speaker]` log tags. Fabricated tool
    /// syntax is never useful to a reader, so it is stripped and reported rather than
    /// shown as content — the model's *real* tool calls never reach here, they are parsed
    /// and dispatched by the session.
    public static func stripFabricatedToolSyntax(_ text: String) -> (text: String, removedLines: Int) {
        let markers = ["[web_search]", "[fetch_page]", "<tool_call>", "</tool_call>"]
        var kept: [String] = []
        var removed = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isMarker = markers.contains { trimmed.hasPrefix($0) }
            let isQueryLine = trimmed.hasPrefix("query:") || trimmed.hasPrefix("Query:")
            if isMarker || isQueryLine {
                removed += 1
            } else {
                kept.append(line)
            }
        }
        return (kept.joined(separator: "\n"), removed)
    }

    /// Drop a stray delimiter or an echoed speaker tag the model may have emitted.
    static func clean(_ text: String, settings: TurnSettings) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["<think>", "</think>"] where output.hasPrefix(marker) {
            output.removeFirst(marker.count)
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["[\(settings.agentID)]", "\(settings.agentID):", "\(settings.displayName):"]
        where output.hasPrefix(prefix) {
            output.removeFirst(prefix.count)
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return output
    }

    static func describe(_ reason: GenerateStopReason) -> String {
        switch reason {
        case .stop: "stop"
        case .length: "length"
        case .cancelled: "cancelled"
        }
    }

    static func toolSpec(for tool: any ToolProvider) -> ToolSpec {
        let argument: [String: any Sendable] = [
            "type": "string",
            "description": tool.argumentDescription,
        ]
        let parameters: [String: any Sendable] = [
            "type": "object",
            "properties": [tool.argumentName: argument],
            "required": [tool.argumentName],
        ]
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": parameters,
            ] as [String: any Sendable],
        ]
    }

    /// Pull the single string argument out of a model's tool call.
    static func argumentString(of call: ToolCall) -> String {
        for (key, value) in call.function.arguments where key != "id" {
            switch value {
            case .string(let string): return string
            default:
                if let any = value.anyValue as? String { return any }
            }
        }
        return ""
    }
}
