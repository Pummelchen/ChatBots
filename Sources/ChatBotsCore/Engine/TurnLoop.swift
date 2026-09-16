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

    /// The user turn appended after a tool round. A fixed string because the Qwen template
    /// requires a user turn after the tool results before it will generate again.
    static let toolContinuation = """
        [Tool results above] Continue your message to the group. Use what the \
        results add, and drop any claim they contradict. If they did not settle \
        the point, say so and answer from what you know rather than searching again \
        with the same wording.
        """

    /// Run one turn's round loop over a caller-supplied model stream.
    ///
    /// This is the whole of a generation turn except for `await load()` and the call that
    /// turns a loaded container into a `Generation` stream. Everything the turn decides —
    /// which entries are sent, where the images ride, whether a round dispatched its tools,
    /// when the thinking ceiling ends the turn, and what a finished turn reports — is here, so
    /// it is exercised with a stub stream rather than only with weights.
    ///
    /// `makeStream` is called once per round with the fully assembled `RoundPrompt`.
    func runTurn(
        settings: TurnSettings,
        messages: [PromptMessage],
        tools: [any ToolProvider],
        images: [Data],
        makeStream: @Sendable (RoundPrompt) async -> AsyncThrowingStream<Generation, Error>,
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        try Task.checkCancellation()

        let agentID = settings.agentID
        let thinking = settings.thinking
        let reasoningCeiling = thinking.reasoningTokenBudget
        /// Answer budget plus whatever this thinking level allows for reasoning.
        let generationCap = settings.generationCap
        // Copy the callbacks into locals: the tool-dispatch closure outlives this
        // scope, so it cannot capture the non-escaping parameters directly.
        let reportToolCall = onToolCall

        // The tools this turn may actually reach, resolved from the caller's array rather than
        // from the registry, so a name that was not offered cannot be dispatched.
        let turnTools = TurnToolSet(offered: tools, registry: toolRegistry)
        let toolSpecs = turnTools.isEmpty ? nil : tools.map { Self.toolSpec(for: $0) }

        // The cap is the answer budget plus whatever the thinking mode allows for
        // reasoning. Sampling mirrors the turn's settings exactly.
        let parameters = Self.parameters(for: settings)
        let additionalContext = settings.templateContext

        var entries = messages.map { TurnEntry(role: $0.role.rawValue, content: $0.content) }

        // Reasoning is streamed to the pane and never enters the log, so it is always
        // reported; `.off` simply produces none.
        let emitReasoning = thinking.thinks
        var answer = ""
        /// Set when this turn produced reasoning text, so an empty answer can be
        /// explained as "ran out of budget while thinking" rather than silence.
        var stripperSpentItsBudget = false
        /// Set when the ceiling cut the thought short, so the UI can say so.
        var reasoningWasTruncated = false
        /// Set when generation was cut short because the model began repeating itself.
        var loopDetected = false
        /// Watches for degenerate repetition; see `RepetitionDetector`.
        var repetition = RepetitionDetector()
        var stats = TurnStats()
        let started = Date.now

        /// Everything sent on the round currently in flight. Each round restates the
        /// whole list (rather than leaning on the session to accumulate) because the
        /// session's KV cache still reuses the shared prefix, and being explicit keeps
        /// the Qwen tool protocol below correct.
        var round = 0
        let maxToolRounds = 3

        // Nested functions capture their context by reference, which the compiler
        // correctly refuses to send across `await`. Returning the segment and folding
        // it here keeps every mutation in this actor's isolation.
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
            repetition = RepetitionDetector()
            let imagesForRound: [Data] = isFirstRound ? images : []
            let prompt = RoundPrompt(
                entries: entries,
                // Images ride on the user message itself, and only while the prompt is still
                // the opening one.
                imageHostIndex: imagesForRound.isEmpty ? nil : entries.lastIndex { $0.role == "user" },
                images: imagesForRound,
                toolSpecs: toolSpecs,
                parameters: parameters,
                additionalContext: additionalContext)

            let stream = await makeStream(prompt)

            var assembler = TurnTextAssembler(thinking: thinking)
            var toolCalls: [ToolCall] = []

            // Labelled, because the ceiling below has to leave the *stream*, not merely the
            // `switch`: an unlabelled `break` inside a switch case exits the switch and the
            // loop then keeps consuming chunks the round has already decided to abandon.
            chunks: for try await generation in stream {
                try Task.checkCancellation()
                switch generation {
                case .chunk(let text):
                    let step = assembler.consume(text)
                    if !step.reasoning.isEmpty { stripperSpentItsBudget = true }
                    answer += step.answer
                    await report(
                        ThinkingStripper.Segment(reasoning: step.reasoning, answer: step.answer))

                    // Enforce the mode's ceiling. The stream is abandoned here: the pinned
                    // MLX release has no budget-transition API, so there is no way to tell
                    // the model to stop thinking and answer. The turn therefore has no
                    // answer to come, and the notice below says so rather than pretending
                    // the model answered from the cut-off.
                    if step.ceilingReached {
                        reasoningWasTruncated = true
                        break chunks
                    }

                    // A loop is a stop condition regardless of the token budget, which is
                    // what keeps a bad sampler setting from producing 32k tokens of noise.
                    if repetition.ingest(step.answer) {
                        loopDetected = true
                        break rounds
                    }

                case .toolCall(let call):
                    toolCalls.append(call)

                case .info(let info):
                    stats = Self.stats(from: info, started: started)
                }
            }

            // A held-back partial delimiter must still be attributed to this round.
            let tail = assembler.finish()
            if !tail.reasoning.isEmpty { stripperSpentItsBudget = true }
            answer += tail.answer
            await report(ThinkingStripper.Segment(reasoning: tail.reasoning, answer: tail.answer))

            // A round the ceiling abandoned ends the turn here, whatever fragments arrived
            // while it was still inside reasoning. Dispatching a `.toolCall` collected in
            // that round would run another round and spend more of the very budget the
            // ceiling exists to bound. The decision is a pure function so the rule is
            // testable without weights.
            guard
                Self.roundAdvance(
                    reasoningWasTruncated: reasoningWasTruncated,
                    toolCallCount: toolCalls.count,
                    hasTools: toolSpecs != nil,
                    round: round,
                    maxToolRounds: maxToolRounds) == .dispatchTools
            else { break rounds }
            round += 1

            // Every call is run first and the prompt entries are framed once they all have an
            // outcome, so the framing cannot be left half-built if one of them throws.
            var dispatched: [DispatchedCall] = []
            for call in toolCalls {
                let name = call.function.name
                let argument = Self.argumentString(of: call)
                await reportToolCall(name, argument)

                let outcome = await turnTools.run(name: name, argument: argument)
                await onEvent(
                    .toolResult(
                        agentID: agentID, name: name, summary: outcome.summary, detail: outcome.text)
                )
                dispatched.append(DispatchedCall(call: call, outcome: outcome))
            }
            Self.appendToolRound(&entries, dispatched: dispatched)
        }

        let scrubbed = Self.stripFabricatedToolSyntax(answer)
        if scrubbed.removedLines > 0 {
            FileHandle.standardError.write(
                Data(
                    "[ChatBots] \(agentID) stripped \(scrubbed.removedLines) line(s) of fabricated tool syntax from the answer\n"
                        .utf8))
        }
        let final = Self.clean(scrubbed.text, settings: settings)
        if stats.generationTokens == 0 {
            stats.seconds = Date.now.timeIntervalSince(started)
        }

        lastStats = stats

        // The notices and the fatal ceiling decision are pure rules, so what a finished turn
        // reports is pinned rather than inferred from a live generation.
        for notice in Self.turnNotices(
            finalAnswer: final,
            sawReasoning: stripperSpentItsBudget,
            reasoningWasTruncated: reasoningWasTruncated,
            loopDetected: loopDetected,
            thinking: thinking,
            ceiling: reasoningCeiling ?? 0,
            generationCap: generationCap)
        {
            await onEvent(.toolFailure(agentID: agentID, name: notice.name, message: notice.message))
        }
        if reasoningWasTruncated, final.isEmpty {
            // The ceiling abandoned the stream, so the model never saw the delimiter
            // and cannot answer from it. Fail rather than hand the caller an empty
            // turn dressed up as a successful one, which is what this used to do.
            throw ReasoningCeilingError(mode: thinking, ceiling: reasoningCeiling ?? 0)
        }

        await onEvent(.turnFinished(agentID: agentID, text: final, stats: stats))
        return final
    }

    /// Append the shape the Qwen template renders after a tool round: the assistant turn
    /// carrying the calls, one tool result per call, then a user turn to continue.
    ///
    /// Pure apart from the array it appends to, so the framing is asserted directly rather than
    /// through a model.
    static func appendToolRound(_ entries: inout [TurnEntry], dispatched: [DispatchedCall]) {
        entries.append(
            TurnEntry(
                role: "assistant", content: "", toolCalls: dispatched.map(\.call)))
        for call in dispatched {
            entries.append(
                TurnEntry(role: "tool", content: call.outcome.text, toolResultID: call.call.id))
        }
        entries.append(TurnEntry(role: "user", content: toolContinuation))
    }

    /// The sampling and budget one turn's model call is driven with.
    ///
    /// Extracted from the generation loop so the parameters a turn actually runs with are
    /// asserted against the `TurnSettings` it was given, rather than assumed.
    static func parameters(for settings: TurnSettings) -> GenerateParameters {
        var parameters = GenerateParameters(
            maxTokens: settings.generationCap,
            temperature: Float(settings.temperature),
            topP: Float(settings.topP),
            topK: settings.topK,
            minP: Float(settings.minP),
            seed: settings.seed
        )
        // Both penalties are optional in the spec; `nil` leaves MLX's default (off).
        // Note MLX *subtracts* `presencePenalty`, so the spec stores it already signed.
        parameters.presencePenalty = settings.presencePenalty.map(Float.init)
        parameters.presenceContextSize = 256
        parameters.repetitionPenalty = settings.repetitionPenalty.map(Float.init)
        parameters.repetitionContextSize = 256
        return parameters
    }

    /// The turn's measured statistics from one model round's `info`.
    static func stats(from info: GenerateCompletionInfo, started: Date, now: Date = .now) -> TurnStats {
        TurnStats(
            promptTokens: info.promptTokenCount,
            prefillSeconds: info.promptTime,
            generationTokens: info.generationTokenCount,
            cachedPromptTokens: 0,
            stopReason: describe(info.stopReason),
            tokensPerSecond: info.generateTime > 0
                ? Double(info.generationTokenCount) / info.generateTime
                : 0,
            seconds: now.timeIntervalSince(started)
        )
    }

    /// The notices a finished turn owes the reader, in the order the engine emits them.
    ///
    /// A reasoning model can burn the entire budget inside `<think>` and emit no answer at
    /// all. That is legitimate behaviour, not an error, but the user must be told — otherwise
    /// the pane stays empty with no explanation. When the ceiling is what ended the turn, the
    /// ceiling's own notice is the truthful one and the budget notice is suppressed.
    static func turnNotices(
        finalAnswer: String,
        sawReasoning: Bool,
        reasoningWasTruncated: Bool,
        loopDetected: Bool,
        thinking: ThinkingMode,
        ceiling: Int,
        generationCap: Int
    ) -> [TurnNotice] {
        var notices: [TurnNotice] = []
        if finalAnswer.isEmpty, sawReasoning, !reasoningWasTruncated {
            notices.append(
                TurnNotice(
                    name: "generation",
                    message:
                        "spent the whole \(generationCap)-token budget thinking and produced no answer — raise the thinking level's headroom or turn thinking off"
                ))
        }
        if loopDetected {
            notices.append(
                TurnNotice(
                    name: "generation",
                    message:
                        "the model fell into a repetition loop and the turn was ended — its sampler settings are too loose for this prompt"
                ))
        }
        if reasoningWasTruncated {
            notices.append(
                TurnNotice(
                    name: "thinking",
                    message: reasoningCeilingNotice(
                        mode: thinking, ceiling: ceiling, producedAnswer: !finalAnswer.isEmpty)))
        }
        return notices
    }

    /// The image bytes an engine can actually use, in attachment order.
    ///
    /// A non-image attachment is not the engine's business — text documents reach the model
    /// through the prompt — and an image whose bytes cannot be decoded is reported and dropped
    /// rather than carried into the model's isolation to fail there. Pure, so it is exercised
    /// without weights.
    static func usableImages(from documents: [AttachedDocument], specID: String) -> [Data] {
        documents.filter { $0.kind.isImage }.compactMap { document in
            guard let data = document.imageData, CIImage(data: data) != nil else {
                FileHandle.standardError.write(
                    Data("[ChatBots] \(specID) could not read the attached image \(document.name)\n".utf8))
                return nil
            }
            return data
        }
    }
}
