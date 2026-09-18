// ChatBotsCore — one generation turn, minus the model call
//
// `MLXEngine.swift` measured 2.2 % line coverage and the reason is structural: the
// whole turn — prompt assembly, the tool rounds, the thinking ceiling, the refusal paths and
// the notices a finished turn owes the reader — lived inside `generateExclusively`, whose
// first statement loaded weights. Nothing about that logic needs a GPU; only the call that
// produces the model's `Generation` stream does.
//
// So the model call is the one thing injected. `runTurn` performs the entire turn over a
// caller-supplied `makeStream`; `generateExclusively` supplies one built from the loaded
// container, and a test supplies a scripted one. The logic is therefore the same code on both
// paths rather than a re-implementation the tests could drift away from.

import CoreImage
import Foundation
import MLXLMCommon

extension MLXEngine {

    /// A conversation entry on its way to the model.
    ///
    /// `Chat.Message` is not `Sendable` (it can carry `CIImage`-backed media), so the prompt
    /// crosses into the model's isolation as plain strings and is rebuilt there. Tool metadata
    /// is kept alongside because it is part of that rebuild.
    struct TurnEntry: Sendable, Equatable {
        var role: String
        var content: String
        var toolCalls: [ToolCall] = []
        var toolResultID: String?
    }

    /// Everything one round of generation is given.
    ///
    /// A value rather than a closure's captured state, so a test can assert on exactly what the
    /// round was handed — which entries, which of them hosts the images, and whether the model
    /// was offered tools at all.
    struct RoundPrompt: Sendable {
        /// The conversation as it stands for this round: the opening prompt plus every tool
        /// round already appended.
        var entries: [TurnEntry]
        /// The entry that hosts this round's images, when there are any. Images go on the
        /// first round only; after a tool round the log already contains the image turn and
        /// re-sending it would duplicate it in the KV cache.
        var imageHostIndex: Int?
        /// Raw image bytes for this round. Decoded inside the model's isolation, where the
        /// image is used, because `UserInput.Image` is not `Sendable`.
        var images: [Data]
        /// The tools rendered into the model's tool specs, or nil when none were offered.
        var toolSpecs: [ToolSpec]?
        var parameters: GenerateParameters
        var additionalContext: [String: any Sendable]
    }

    /// A failure one finished turn must report, as the engine reports it.
    struct TurnNotice: Sendable, Equatable {
        var name: String
        var message: String
    }

    /// What the tool round after a generation round is given: one record per call, so the
    /// prompt entries can be framed after every call has been awaited.
    struct DispatchedCall: Sendable {
        var call: ToolCall
        var outcome: ToolOutcome
    }

    /// Run one turn's round loop over a caller-supplied model stream.
    ///
    /// This is the whole of a generation turn except for `await load()` and the call that
    /// turns a loaded container into a `Generation` stream. Everything the turn decides —
    /// which entries are sent, where the images ride, whether a round dispatched its tools,
    /// when the thinking ceiling ends the turn, and what a finished turn reports — is here, so
    /// it is exercised with a stub stream rather than only with weights.
    ///
    /// `makeStream` is called once per round with the fully assembled `RoundPrompt`.
    /// The two callbacks a turn reports through: a tool call as it is dispatched, and an event as
    /// it happens. Grouped so the callers cannot pass one and forget the other, and so `runTurn`
    /// stays inside its parameter budget.
    struct TurnObservers: Sendable {
        var onToolCall: @Sendable (String, String) async -> Void
        var onEvent: @Sendable (TurnEvent) async -> Void
    }

    /// What the turn is asked with: the messages, the tools it may call, and the images the seat
    /// can see. Grouped for the same reason as `TurnObservers`.
    struct TurnPrompt: Sendable {
        var messages: [PromptMessage]
        var tools: [any ToolProvider]
        var images: [Data]
    }

    /// What one round loop produced, for `finishTurn` to report.
    private struct TurnOutcome {
        var answer: String
        var sawReasoning: Bool
        var reasoningWasTruncated: Bool
        var loopDetected: Bool
        var stats: TurnStats
        var started: Date
    }

    /// What one generation round produced.
    private struct ChunkOutcome {
        var answer: String
        var toolCalls: [ToolCall]
        var sawReasoning: Bool
        var reasoningWasTruncated: Bool
        var loopDetected: Bool
        var stats: TurnStats
    }

    /// What dispatching one round's tool calls produced.
    private struct ToolDispatch {
        var dispatched: [DispatchedCall]
        var runCount: Int
        var truncated: Bool
    }

    /// The per-turn values every round reads and none changes, grouped so each helper stays
    /// inside its parameter budget, the way `TurnObservers` and `TurnPrompt` already are.
    private struct RoundContext {
        var thinking: ThinkingMode
        var agentID: String
        var emitReasoning: Bool
        var toolSpecs: [ToolSpec]?
        var parameters: GenerateParameters
        var additionalContext: [String: any Sendable]
        var turnTools: TurnToolSet
        var started: Date
        var makeStream: @Sendable (RoundPrompt) async -> AsyncThrowingStream<Generation, Error>
        var onToolCall: @Sendable (String, String) async -> Void
        var onEvent: @Sendable (TurnEvent) async -> Void
    }

    func runTurn(
        settings: TurnSettings,
        prompt: TurnPrompt,
        makeStream: @escaping @Sendable (RoundPrompt) async -> AsyncThrowingStream<Generation, Error>,
        observers: TurnObservers
    ) async throws -> String {
        let outcome = try await runRounds(
            settings: settings, prompt: prompt, makeStream: makeStream, observers: observers)
        return try await finishTurn(outcome, settings: settings, observers: observers)
    }

    /// The round loop: assemble each round's prompt, consume its stream, and dispatch the tools
    /// it collected until a rule ends the turn.
    private func runRounds(
        settings: TurnSettings,
        prompt: TurnPrompt,
        makeStream: @escaping @Sendable (RoundPrompt) async -> AsyncThrowingStream<Generation, Error>,
        observers: TurnObservers
    ) async throws -> TurnOutcome {
        let messages = prompt.messages
        let tools = prompt.tools
        let images = prompt.images
        let onToolCall = observers.onToolCall
        let onEvent = observers.onEvent
        try Task.checkCancellation()

        let agentID = settings.agentID
        let thinking = settings.thinking
        // The tools this turn may actually reach, resolved from the caller's array rather than
        // from the registry, so a name that was not offered cannot be dispatched.
        let turnTools = TurnToolSet(offered: tools, registry: toolRegistry)
        let toolSpecs = turnTools.isEmpty ? nil : tools.map { Self.toolSpec(for: $0) }
        // The cap is the answer budget plus whatever the thinking mode allows for reasoning.
        // Sampling mirrors the turn's settings exactly.
        let parameters = Self.parameters(for: settings)
        let additionalContext = settings.templateContext
        var entries = messages.map { TurnEntry(role: $0.role.rawValue, content: $0.content) }

        var answer = ""
        /// Set when this turn produced reasoning text, so an empty answer can be
        /// explained as "ran out of budget while thinking" rather than silence.
        var stripperSpentItsBudget = false
        /// Set when the ceiling cut the thought short, so the UI can say so.
        var reasoningWasTruncated = false
        /// Set when generation was cut short because the model began repeating itself.
        var loopDetected = false
        var stats = TurnStats()
        let started = Date.now

        let context = RoundContext(
            thinking: thinking, agentID: agentID, emitReasoning: thinking.thinks,
            toolSpecs: toolSpecs, parameters: parameters, additionalContext: additionalContext,
            turnTools: turnTools, started: started, makeStream: makeStream,
            onToolCall: onToolCall, onEvent: onEvent)

        /// Everything sent on the round currently in flight. Each round restates the
        /// whole list (rather than leaning on the session to accumulate) because the
        /// session's KV cache still reuses the shared prefix, and being explicit keeps
        /// the Qwen tool protocol below correct.
        var round = 0
        let maxToolRounds = 3
        /// Tool calls already dispatched this turn, across every round, so the per-turn cap is
        /// enforced cumulatively rather than per round.
        var dispatchedToolCalls = 0

        // Which pass over the prompt this is. Images go on the first one only: after a tool
        // round the log already contains the image turn, and re-sending it would duplicate it
        // in the KV cache and confuse a template expecting a single image token run.
        //
        // This was previously a `isToolRound` flag that nothing ever set, so the guard never
        // engaged and the ternary below it was dead code. A round counter says the same thing
        // and cannot silently stop working.
        var roundIndex = 0
        rounds: while true {
            let isFirstRound = roundIndex == 0
            roundIndex += 1
            let chunk = try await runRound(
                entries: entries, images: images, isFirstRound: isFirstRound,
                context: context, startingStats: stats)
            answer += chunk.answer
            stripperSpentItsBudget = stripperSpentItsBudget || chunk.sawReasoning
            reasoningWasTruncated = reasoningWasTruncated || chunk.reasoningWasTruncated
            loopDetected = loopDetected || chunk.loopDetected
            stats = chunk.stats

            // The loop stop is taken here rather than at the detection inside the round, so the
            // held-back partial delimiter the flush exists for is not dropped: `break rounds`
            // from inside the chunk loop skipped `assembler.finish()`, losing up to 7
            // characters of the answer (`ThinkingStripper` holds `endDelimiter.count - 1`).
            if loopDetected { break rounds }

            // A round the ceiling abandoned ends the turn here, whatever fragments arrived
            // while it was still inside reasoning. Dispatching a `.toolCall` collected in
            // that round would run another round and spend more of the very budget the
            // ceiling exists to bound.
            guard
                Self.roundAdvance(
                    reasoningWasTruncated: reasoningWasTruncated,
                    toolCallCount: chunk.toolCalls.count,
                    hasTools: toolSpecs != nil,
                    round: round,
                    maxToolRounds: maxToolRounds) == .dispatchTools
            else { break rounds }
            round += 1

            // Every call is run first and the prompt entries are framed once they all have an
            // outcome, so the framing cannot be left half-built if one of them throws. Only the
            // calls inside the per-turn cap run: `roundAdvance` bounds the rounds, not the calls
            // a round may carry, and the search budget is checked once before the turn.
            let dispatch = await dispatchToolCalls(
                chunk.toolCalls, context: context, alreadyDispatched: dispatchedToolCalls)
            dispatchedToolCalls += dispatch.runCount
            Self.appendToolRound(&entries, dispatched: dispatch.dispatched)
            // A model that asked for more calls than the cap allows gets no further round: the
            // cap exists to bound the spend, and the excess calls are dropped, not queued.
            if dispatch.truncated { break rounds }
        }

        return TurnOutcome(
            answer: answer, sawReasoning: stripperSpentItsBudget,
            reasoningWasTruncated: reasoningWasTruncated, loopDetected: loopDetected,
            stats: stats, started: started)
    }

    /// Assemble one round's prompt and consume its stream.
    private func runRound(
        entries: [TurnEntry],
        images: [Data],
        isFirstRound: Bool,
        context: RoundContext,
        startingStats: TurnStats
    ) async throws -> ChunkOutcome {
        let imagesForRound: [Data] = isFirstRound ? images : []
        let prompt = RoundPrompt(
            entries: entries,
            // Images ride on the user message itself, and only while the prompt is still
            // the opening one.
            imageHostIndex: imagesForRound.isEmpty ? nil : entries.lastIndex { $0.role == "user" },
            images: imagesForRound,
            toolSpecs: context.toolSpecs,
            parameters: context.parameters,
            additionalContext: context.additionalContext)
        let stream = await context.makeStream(prompt)
        return try await consumeChunks(stream, context: context, startingStats: startingStats)
    }

    /// Consume one round's `Generation` stream.
    ///
    /// Labelled, because the ceiling below has to leave the *stream*, not merely the `switch`:
    /// an unlabelled `break` inside a switch case exits the switch and the loop then keeps
    /// consuming chunks the round has already decided to abandon.
    private func consumeChunks(
        _ stream: AsyncThrowingStream<Generation, Error>,
        context: RoundContext,
        startingStats: TurnStats
    ) async throws -> ChunkOutcome {
        let thinking = context.thinking
        let agentID = context.agentID
        let emitReasoning = context.emitReasoning
        let onEvent = context.onEvent
        let started = context.started

        var assembler = TurnTextAssembler(thinking: thinking)
        var toolCalls: [ToolCall] = []
        var answer = ""
        var sawReasoning = false
        var reasoningWasTruncated = false
        var loopDetected = false
        // Reset each round, so a loop in one round cannot be inherited by the next.
        var repetition = RepetitionDetector()
        var stats = startingStats

        // Reports one stripped segment. This is a nested function that only forwards
        // events; it deliberately neither reads nor writes the turn's mutable state, which
        // the compiler rejects across `await` (and which was a real data-race finding).
        func report(_ segment: ThinkingStripper.Segment) async {
            if !segment.reasoning.isEmpty, emitReasoning {
                await onEvent(.reasoning(agentID: agentID, text: segment.reasoning))
            }
            if !segment.answer.isEmpty {
                await onEvent(.token(agentID: agentID, text: segment.answer))
            }
        }

        chunks: for try await generation in stream {
            try Task.checkCancellation()
            switch generation {
            case .chunk(let text):
                let step = assembler.consume(text)
                if !step.reasoning.isEmpty { sawReasoning = true }
                answer += step.answer
                await report(
                    ThinkingStripper.Segment(reasoning: step.reasoning, answer: step.answer))

                // Enforce the mode's ceiling. The stream is abandoned here: the pinned
                // MLX release has no budget-transition API, so there is no way to tell
                // the model to stop thinking and answer. The turn therefore has no
                // answer to come, and the notice in `finishTurn` says so rather than
                // pretending the model answered from the cut-off.
                if step.ceilingReached {
                    reasoningWasTruncated = true
                    break chunks
                }

                // A loop is a stop condition regardless of the token budget, which is
                // what keeps a bad sampler setting from producing 32k tokens of noise.
                if repetition.ingest(step.answer) {
                    loopDetected = true
                    break chunks
                }

            case .toolCall(let call):
                toolCalls.append(call)

            case .info(let info):
                stats = Self.stats(from: info, started: started)
            }
        }

        // A held-back partial delimiter must still be attributed to this round.
        let tail = assembler.finish()
        if !tail.reasoning.isEmpty { sawReasoning = true }
        answer += tail.answer
        await report(ThinkingStripper.Segment(reasoning: tail.reasoning, answer: tail.answer))

        return ChunkOutcome(
            answer: answer, toolCalls: toolCalls, sawReasoning: sawReasoning,
            reasoningWasTruncated: reasoningWasTruncated, loopDetected: loopDetected,
            stats: stats)
    }

    /// Run one round's tool calls, bounded by the per-turn cap.
    private func dispatchToolCalls(
        _ toolCalls: [ToolCall],
        context: RoundContext,
        alreadyDispatched: Int
    ) async -> ToolDispatch {
        let selection = Self.toolCallsWithinBudget(
            toolCalls, alreadyDispatched: alreadyDispatched)
        var dispatched: [DispatchedCall] = []
        for call in selection.run {
            let name = call.function.name
            let argument = Self.argumentString(of: call)
            await context.onToolCall(name, argument)

            let outcome = await context.turnTools.run(name: name, argument: argument)
            await context.onEvent(
                .toolResult(
                    agentID: context.agentID, name: name, summary: outcome.summary,
                    detail: outcome.text, billedUnits: outcome.billedUnits))
            dispatched.append(DispatchedCall(call: call, outcome: outcome))
        }
        return ToolDispatch(
            dispatched: dispatched, runCount: selection.run.count, truncated: selection.truncated)
    }

    /// Report what a finished turn produced: the scrubbed answer, the notices the reader is
    /// owed, and the turn's statistics.
    private func finishTurn(
        _ outcome: TurnOutcome,
        settings: TurnSettings,
        observers: TurnObservers
    ) async throws -> String {
        let agentID = settings.agentID
        let thinking = settings.thinking
        let reasoningCeiling = thinking.reasoningTokenBudget
        let generationCap = settings.generationCap

        let scrubbed = Self.stripFabricatedToolSyntax(outcome.answer)
        if scrubbed.removedLines > 0 {
            let notice =
                "[ChatBots] \(agentID) stripped \(scrubbed.removedLines) line(s) of fabricated "
                + "tool syntax from the answer\n"
            FileHandle.standardError.write(Data(notice.utf8))
        }
        let final = Self.clean(scrubbed.text, settings: settings)
        var stats = outcome.stats
        if stats.generationTokens == 0 {
            stats.seconds = Date.now.timeIntervalSince(outcome.started)
        }

        lastStats = stats

        // The notices and the fatal ceiling decision are pure rules, so what a finished turn
        // reports is pinned rather than inferred from a live generation.
        for notice in Self.turnNotices(
            finalAnswer: final,
            sawReasoning: outcome.sawReasoning,
            reasoningWasTruncated: outcome.reasoningWasTruncated,
            loopDetected: outcome.loopDetected,
            budget: ReasoningBudget(
                thinking: thinking, ceiling: reasoningCeiling ?? 0, generationCap: generationCap))
        {
            await observers.onEvent(
                .toolFailure(agentID: agentID, name: notice.name, message: notice.message))
        }
        if outcome.reasoningWasTruncated, final.isEmpty {
            // The ceiling abandoned the stream, so the model never saw the delimiter
            // and cannot answer from it. Fail rather than hand the caller an empty
            // turn dressed up as a successful one, which is what this used to do.
            throw ReasoningCeilingError(mode: thinking, ceiling: reasoningCeiling ?? 0)
        }

        await observers.onEvent(.turnFinished(agentID: agentID, text: final, stats: stats))
        return final
    }

}
