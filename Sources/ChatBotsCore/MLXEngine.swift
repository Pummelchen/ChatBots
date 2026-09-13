// ChatBotsCore — the MLX Swift implementation of one LLM seat
//
// One `MLXEngine` == one loaded model instance == one seat at the table. Two seats
// therefore hold two independent weight copies, which is the point: seat B can be
// pointed at a completely different checkpoint in `AgentSpec` without touching this
// file or the orchestrator.
//
// Loading goes through the `MLXHuggingFace` macros, which supply a Hugging Face hub
// downloader and a `swift-transformers` tokenizer for a model id. Weights are cached
// by the hub client, so the second `load()` on an already-downloaded model is local.

import CoreImage
import Foundation
import HuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import Tokenizers

/// Status of an engine's weights, for display.
public enum EngineState: Sendable, Equatable {
    case idle
    case loading(progress: Double)
    case ready
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Sampling and budget for one generation turn, resolved in a single place.
///
/// The bug this closes (A42) was a `compact` that built an overridden spec and handed it to
/// a `generate` which re-read the seat's own `spec`, so the digest ran with the seat's full
/// answer cap and live thinking level and the override was silently dead. Every setting the
/// model is configured with now comes through here, and `generateExclusively` reads nothing
/// else, so an override cannot be dropped on the floor again.
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
    public private(set) var tokens = 0
    public private(set) var wasReached = false

    public init(mode: ThinkingMode) {
        self.mode = mode
        self.ceiling = mode.reasoningTokenBudget
    }

    /// Account for one reasoning segment. Returns `true` the first time the ceiling is
    /// reached, and `false` on every later call, so the caller acts exactly once.
    public mutating func account(reasoning: String) -> Bool {
        guard !wasReached, let ceiling, ceiling > 0, !reasoning.isEmpty else { return false }
        tokens += reasoning.count / 4
        guard tokens >= ceiling else { return false }
        wasReached = true
        return true
    }
}

/// Splits decoded chunks into reasoning and answer, enforcing the mode's ceiling.
///
/// This is the engine's per-chunk text handling, extracted so the ceiling path is testable
/// without weights. A43 was that hitting the ceiling appended a closing delimiter to the
/// answer and then abandoned the stream: the model never saw the delimiter, the answer
/// stayed empty, and the notice claimed the model had answered from the cut-off.
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

public actor MLXEngine: LLMEngine {

    public let spec: AgentSpec
    let toolRegistry: ToolRegistry
    private let onStateChange: @Sendable (EngineState) -> Void

    private var container: ModelContainer?
    private var loadingTask: Task<ModelContainer, Error>?
    private var loadedContextWindow = 32_768
    private var didLogConfiguration = false
    /// Live thinking level. Starts from the seat's spec and is changed between turns by
    /// the pane control; `spec` itself stays immutable because it is a protocol property.
    private var currentThinking: ThinkingMode
    /// Live persona id, same reasoning as `currentThinking`.
    private var currentPersonaID: String
    /// Live display name, same reasoning as `currentPersonaID`.
    private var currentDisplayName: String

    /// Throughput of this seat's most recent turn, for diagnostics and benchmarks.
    public internal(set) var lastStats: TurnStats?

    public init(
        spec: AgentSpec,
        toolRegistry: ToolRegistry = .shared,
        onStateChange: @escaping @Sendable (EngineState) -> Void = { _ in }
    ) {
        self.spec = spec
        self.currentThinking = spec.thinking
        self.currentPersonaID = spec.personaID
        self.currentDisplayName = spec.displayName
        self.toolRegistry = toolRegistry
        self.onStateChange = onStateChange
    }

    public var isLoaded: Bool { container != nil }

    /// Change how much this seat may think. Read at the start of each turn, so it takes
    /// effect on the next turn and never mid-generation.
    ///
    /// `async` because the `LLMEngine` requirement is, and that is load-bearing rather than
    /// cosmetic: a synchronous method satisfies an async requirement, which left two candidates in
    /// scope at a call site naming this concrete type, and `await` chose the protocol extension's
    /// async no-op over this method. Every shipped call site goes through `any LLMEngine`, so the
    /// write was only ever discarded in a shape nobody was using yet (audit A115).
    public func setThinking(_ mode: ThinkingMode) async {
        currentThinking = mode
    }

    /// The level this seat will use on its next turn.
    public var thinking: ThinkingMode { currentThinking }

    /// Rename this seat. Takes effect on its next turn. `async` for the reason `setThinking` is.
    public func setDisplayName(_ name: String) async {
        currentDisplayName = name
    }

    /// The moderator's images, as raw bytes.
    ///
    /// Bytes rather than `CIImage`/`UserInput.Image` because neither is `Sendable`, and the
    /// generate path crosses into the model's own isolation. `Data` crosses cleanly and is
    /// decoded on the far side, where the image is going to be used anyway.
    private var imageData: [Data] = []

    /// How many images this seat is holding.
    ///
    /// The bytes themselves stay private; this is the whole of what a caller (or a test)
    /// needs to see that `setAttachments` filtered what it was given.
    var attachedImageCount: Int { imageData.count }

    public func setAttachments(_ documents: [AttachedDocument]) async {
        imageData = Self.usableImages(from: documents, specID: spec.id)
    }

    /// The style this seat will use on its next turn. `async` for the reason `setThinking` is.
    public func setPersona(_ personaID: String) async {
        currentPersonaID = personaID
    }

    /// Resolved through the seat's mode, so a research seat is not handed an
    /// entertainment character's directive.
    public var persona: PersonaStyle {
        PersonaCatalog.style(id: currentPersonaID, mode: spec.mode)
    }

    /// `spec` plus whatever the user has changed since. Mirrors `setThinking`/`setPersona`
    /// so there is a single place the live configuration is assembled.
    public var currentSpec: AgentSpec {
        var live = spec
        live.thinking = currentThinking
        live.personaID = currentPersonaID
        live.displayName = currentDisplayName
        return live
    }

    public var contextWindow: Int { loadedContextWindow }

    /// Condense a transcript. Runs as an ordinary turn with no tools, so the seat's own
    /// sampling and persona apply — which is what makes the digest read like that seat's
    /// understanding of the discussion rather than a generic extract.
    ///
    /// The turn's budget is the digest's own, not the seat's: `compactSummaryTokens` and
    /// thinking off reach the model through `compactTurnSettings`, which is the value
    /// `generate` is given.
    public func compact(prompt: String, maxTokens: Int) async throws -> String {
        let settings = Self.compactTurnSettings(
            seat: spec, maxTokens: maxTokens, contextWindow: loadedContextWindow)
        let summary = try await generate(
            messages: [
                .init(role: .system, content: "You condense discussions faithfully and add nothing."),
                .init(role: .user, content: prompt),
            ],
            tools: [],
            settings: settings,
            onToolCall: { _, _ in },
            onEvent: { _ in }
        )
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The turn `compact` must run: the digest's own small answer cap — never the seat's
    /// 32 768-token one — and thinking off, because summarising is not the place for
    /// deliberation.
    public static func compactTurnSettings(
        seat: AgentSpec, maxTokens: Int, contextWindow: Int?
    ) -> TurnSettings {
        var overridden = seat
        overridden.maxTokens = max(1, maxTokens)
        overridden.thinking = .off
        return TurnSettings(spec: overridden, thinking: .off, contextWindow: contextWindow)
    }

    // MARK: - Loading

    public func load() async throws {
        if container != nil { return }

        // Coalesce concurrent load calls: the UI may warm a seat up while the
        // orchestrator is already loading it for the first turn.
        if let loadingTask {
            _ = try await loadingTask.value
            return
        }

        let spec = self.spec
        let onStateChange = self.onStateChange
        let task = Task<ModelContainer, Error> {
            onStateChange(.loading(progress: 0))
            let progressBox = ProgressBox()

            return try await MLXGate.exclusive {
                // A checkpoint already in the project's `models/` folder is loaded straight
                // from disk — no hub round trip, and no dependence on whatever happens to
                // be in a shared cache. Anything else goes through the hub, which
                // `ModelStore.prepare()` has already pointed at the same folder, so a
                // download lands in the project too.
                if let local = ModelStore.localCheckpoint(for: spec.modelID) {
                    FileHandle.standardError.write(
                        Data("[ChatBots] \(spec.id) loading \(spec.modelID) from \(local.path)\n".utf8))
                    let tokenizerLoader: any TokenizerLoader = #huggingFaceTokenizerLoader()
                    // A checkpoint with a vision tower is loaded through the vision factory,
                    // which assembles the same `ModelContainer` but also builds the image
                    // processor. Loading a vision checkpoint through the text factory is
                    // what left images unusable before: the container was fine, it simply
                    // had no way to turn bytes into the patches the model expects.
                    if ModelStore.declaresVision(for: spec.modelID) == true {
                        return try await VLMModelFactory.shared.loadContainer(
                            from: local, using: tokenizerLoader)
                    }
                    return try await LLMModelFactory.shared.loadContainer(
                        from: local, using: tokenizerLoader)
                }
                FileHandle.standardError.write(
                    Data(
                        "[ChatBots] \(spec.id) \(spec.modelID) not found in \(ModelStore.directory().path); fetching it there\n"
                            .utf8))

                return try await #huggingFaceLoadModelContainer(
                    configuration: ModelConfiguration(id: spec.modelID)
                ) { progress in
                    let fraction =
                        progress.totalUnitCount > 0
                        ? Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
                        : 0
                    progressBox.report(fraction, to: onStateChange)
                }
            }
        }
        loadingTask = task

        do {
            let container = try await task.value
            self.container = container
            if let window = await Self.contextWindow(of: container) {
                self.loadedContextWindow = window
            }
            self.loadingTask = nil
            onStateChange(.ready)
        } catch {
            self.loadingTask = nil
            onStateChange(.failed(error.localizedDescription))
            throw error
        }
    }

    public func unload() async {
        loadingTask?.cancel()
        loadingTask = nil
        container = nil
        onStateChange(.idle)
    }

    /// Read the model's real context window once, so the UI can warn before the shared
    /// log outgrows it. The library does not surface this, so read the checkpoint's own
    /// JSON: `text_config` for the Qwen 3.5 wrapper, else the top level.
    private static func contextWindow(of container: ModelContainer) async -> Int? {
        guard
            let directory = await container.perform({ context -> URL? in
                if case .directory(let url) = context.configuration.id { return url }
                return nil
            })
        else { return nil }

        let url = directory.appending(component: "config.json")
        guard let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let textConfig = root["text_config"] as? [String: Any]
        for key in ["max_position_embeddings", "max_sequence_length"] {
            let nested = (textConfig?[key] as? NSNumber)?.intValue
            let flat = (root[key] as? NSNumber)?.intValue
            if let value = nested ?? flat, value > 0 {
                return value
            }
        }
        return nil
    }

    /// One step of the session-reuse probe.
    public struct ReuseProbeStep: Sendable {
        public var prefilled: Int
        public var prefillSeconds: Double
    }

    /// Diagnostic: does one `ChatSession` reuse its KV cache across calls?
    ///
    /// This decides whether a larger restructure — keeping a session alive per seat and
    /// sending only new turns — would actually save prefill, or whether MLX re-prefills
    /// regardless. It reports what the session itself says it reused.
    public func sessionReuseProbe() async throws -> [ReuseProbeStep] {
        try await load()
        guard let container else { throw ChatBotsError.engineNotLoaded }
        let thinking = currentThinking
        let parameters = GenerateParameters(maxTokens: 24, temperature: 0, topP: 1.0, seed: 1)
        let context = thinking.templateContext

        let results: [ReuseProbeStep] = try await container.perform {
            (modelContext: ModelContext) async throws -> [ReuseProbeStep] in
            let session = ChatSession(
                modelContext, generateParameters: parameters, additionalContext: context)
            var steps: [ReuseProbeStep] = []
            for index in 1...3 {
                // A long first prompt and short follow-ups: reuse shows up as the
                // follow-ups prefilling only their own tokens, no reuse as prefilling
                // the whole thing again.
                // Deliberately long, so that reuse is unmistakable in the numbers.
                let notes = String(repeating: "egg shell ovoid pressure membrane. ", count: 400)
                let prompt = index == 1
                    ? "Notes: \(notes)\n\nOne short sentence: what shape is an egg?"
                    : "One sentence: what does that imply?"
                var info: GenerateCompletionInfo?
                for try await event in session.streamDetails(to: prompt) {
                    if case .info(let value) = event { info = value }
                }
                await session.clear()
                steps.append(
                    ReuseProbeStep(
                        prefilled: info?.promptTokenCount ?? 0,
                        prefillSeconds: info?.promptTime ?? 0))
            }
            return steps
        }
        return results
    }

    // MARK: - Generation

    @discardableResult
    public func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        try await generate(
            messages: messages,
            tools: tools,
            settings: TurnSettings(
                spec: spec, thinking: currentThinking, contextWindow: loadedContextWindow),
            onToolCall: onToolCall,
            onEvent: onEvent)
    }

    /// `generate` with an explicit turn configuration.
    ///
    /// `compact` goes through here so it can run on its own budget and thinking level;
    /// every other caller goes through the public `generate`, which keeps the seat's live
    /// configuration.
    private func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        settings: TurnSettings,
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        try await load()

        // Resolved after loading, when the model's real context window is known.
        var settings = settings
        settings.contextWindow = loadedContextWindow

        // Held across the whole turn, not just the model call: the token stream keeps
        // evaluating on the GPU as it is consumed, so the slot must not be handed on
        // until that stream is drained. Release is explicit so ordering is
        // deterministic even on the error path.
        await MLXGate.shared.acquire()
        do {
            let text = try await generateExclusively(
                messages: messages, tools: tools, settings: settings,
                onToolCall: onToolCall, onEvent: onEvent)
            await MLXGate.shared.release()
            return text
        } catch {
            await MLXGate.shared.release()
            throw error
        }
    }

    /// The body of `generate`, run while holding the MLX gate.
    ///
    /// Only the model call lives here. `runTurn` performs the whole turn over an injected
    /// stream, and this is the one place that builds that stream from a loaded container, so
    /// the turn's logic is exercised by tests with a scripted stream rather than only with
    /// weights (audit A02).
    private func generateExclusively(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        settings: TurnSettings,
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        guard let container else { throw ChatBotsError.engineNotLoaded }
        try Task.checkCancellation()

        let images = imageData
        // `Chat.Message` is not Sendable (it can carry CIImage-backed media), so the text
        // prompt crosses into the model's isolation as plain strings and is rebuilt inside
        // `perform`.
        let text = try await runTurn(
            settings: settings,
            messages: messages,
            tools: tools,
            images: images,
            makeStream: { prompt in
                await container.perform { context -> AsyncThrowingStream<Generation, Error> in
                    // Decoded here, inside the model's isolation, from bytes that crossed it.
                    let decodedImages: [UserInput.Image] = prompt.images.compactMap { data in
                        CIImage(data: data).map { UserInput.Image.ciImage($0) }
                    }
                    var lastUserIndex: Int? = prompt.imageHostIndex
                    let messagesForRound = prompt.entries.enumerated().map { index, entry in
                        let isImageHost = lastUserIndex == index
                        if isImageHost { lastUserIndex = nil }
                        return Chat.Message(
                            role: Chat.Message.Role(rawValue: entry.role) ?? .user,
                            content: entry.content,
                            images: isImageHost ? decodedImages : [],
                            tool: entry.toolResultID.map { .result(id: $0) }
                                ?? (entry.toolCalls.isEmpty ? nil : .calls(entry.toolCalls))
                        )
                    }
                    // No `toolDispatch`: we dispatch ourselves so the assistant message
                    // that requested the tool is present in the transcript. Qwen 3.5's
                    // template requires it (and requires a following user turn) before it
                    // will render a tool response at all.
                    let session = ChatSession(
                        context,
                        generateParameters: prompt.parameters,
                        additionalContext: prompt.additionalContext,
                        tools: prompt.toolSpecs
                    )
                    return session.streamDetails(to: messagesForRound)
                }
            },
            onToolCall: onToolCall,
            onEvent: onEvent)
        logConfigurationOnce(container: container, settings: settings)
        return text
    }

    private func logConfigurationOnce(container: ModelContainer, settings: TurnSettings) {
        guard !didLogConfiguration else { return }
        didLogConfiguration = true
        let context = loadedContextWindow
        let sampler = String(
            format: "temp=%.2f topP=%.2f topK=%d minP=%.2f presence=%@ repetition=%@ maxOut=%d",
            settings.temperature, settings.topP, settings.topK, settings.minP,
            settings.presencePenalty.map { String(format: "%.2f", $0) } ?? "off",
            settings.repetitionPenalty.map { String(format: "%.2f", $0) } ?? "off",
            settings.generationCap)
        FileHandle.standardError.write(
            Data(
                "[ChatBots] \(settings.agentID) \(settings.modelID) ready — context \(context) tok, thinking \(settings.thinking.rawValue)\n[ChatBots] \(settings.agentID) sampler: \(sampler)\n"
                    .utf8)
        )
    }

    // MARK: - Helpers

    /// The hard `maxTokens` for one turn.
    ///
    /// A bounded mode adds its reasoning ceiling to the answer budget. `.unlimited` has no
    /// ceiling, but MLX needs a finite cap, so it is given the model's whole context window as
    /// headroom — and never less than `.high`, so choosing a higher level can never reduce the
    /// budget. The old arithmetic, `maxTokens + (nil ?? 0)`, gave unlimited *less* than high.
    ///
    /// Delegates to `ThinkingMode.generationCap`, the single implementation, so this and
    /// `AgentSpec.generationCap` cannot disagree (audit A90).
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

    /// Whether a finished round may run the tool calls it collected.
    ///
    /// A round the reasoning ceiling abandoned ends the turn whatever fragments arrived: a
    /// `.toolCall` chunk that came in while the stripper still considered itself inside
    /// reasoning is not a usable instruction, and acting on it would run another round and
    /// spend more of the budget the ceiling exists to bound. This used to fall through to the
    /// same `guard` as an ordinary round, so a protocol-violating model could turn a
    /// ceiling-abandoned turn into another tool round (audit A91).
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
            return "thinking hit the \(level) ceiling (\(ceiling) reasoning tokens) and was cut off; the turn keeps the answer written so far — raise the thinking level to let the model finish before answering"
        }
        return "thinking hit the \(level) ceiling (\(ceiling) reasoning tokens) and the turn ended before the model produced an answer — raise the thinking level or turn thinking off"
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
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": [
                    "type": "object",
                    "properties": [
                        tool.argumentName: [
                            "type": "string",
                            "description": tool.argumentDescription,
                        ] as [String: any Sendable]
                    ] as [String: any Sendable],
                    "required": [tool.argumentName],
                ] as [String: any Sendable],
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

/// Serialises every Metal-touching operation in the process.
///
/// Two MLX model instances are loaded here, and MLX's Metal backend is not safe to
/// drive from two places at once: running a second evaluation while another is in flight
/// aborts inside `mlx::core::metal::Device::get_command_encoder` /
/// `fast::CustomKernel::eval_gpu` with `EXC_BAD_ACCESS`, which showed up as
/// `Segmentation fault: 11` crash reports. Weight loading is serialised for the same
/// reason — two concurrent loads each build command encoders and compile kernels.
///
/// This costs almost nothing in practice: a conversation turn needs the previous
/// speaker's text to exist, so the turn loop is sequential anyway, and the GPU
/// serialises concurrent work rather than overlapping it (measured: each seat at exactly
/// 50% of its solo rate). It also makes the `--benchmark` mode honest.
actor MLXGate {
    static let shared = MLXGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // Hand the slot straight to the next waiter; `busy` stays true.
            waiters.removeFirst().resume()
        }
    }

    /// Run `body` with exclusive access to MLX.
    ///
    /// `rethrows` with an explicit release rather than `defer { Task { ... } }`: a
    /// detached release task could let a waiter in before `body` has actually finished
    /// with the GPU, which is the exact race this gate exists to prevent.
    static func exclusive<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        await shared.acquire()
        do {
            let result = try await body()
            await shared.release()
            return result
        } catch {
            await shared.release()
            throw error
        }
    }
}

/// Progress callbacks arrive from download threads; throttle before touching UI state.
///
/// `@unchecked Sendable` because its one piece of mutable state, `lastReported`, is confined to
/// `lock`: `report` is the only method that touches it and holds `lock` across the whole
/// read-modify-write. The `handler` call is deliberately made after `lock.unlock()`, so an
/// arbitrary callback never runs while the box is locked. What keeps the confinement true is
/// that `lastReported` is private, `lock` is a `let`, and `report` is the only accessor.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReported: Double = -1

    func report(_ fraction: Double, to handler: @Sendable (EngineState) -> Void) {
        lock.lock()
        let shouldReport = fraction - lastReported >= 0.02 || fraction >= 1.0
        if shouldReport { lastReported = fraction }
        lock.unlock()
        guard shouldReport else { return }
        handler(.loading(progress: fraction))
    }
}

// MARK: - Tool registry

/// Maps a tool name emitted by a model to a live `ToolProvider`.
///
/// `@unchecked Sendable` because its one piece of mutable state, `tools`, is confined to
/// `lock`: `register` writes the dictionary and `tool(named:)` reads it, each holding `lock`,
/// and `tools` is private so no other code can reach it. `tool(named:)` copies the provider out
/// under the lock and the caller awaits outside it, which is safe because `ToolProvider` refines
/// `Sendable` — the value that escapes the lock carries its own synchronisation. What keeps the
/// confinement true is that `lock` is a `let` and `register` and `tool(named:)` are the only
/// accessors of the dictionary.
public final class ToolRegistry: @unchecked Sendable {
    public static let shared = ToolRegistry()

    private let lock = NSLock()
    private var tools: [String: any ToolProvider] = [:]

    public init() {}

    public func register(_ tool: any ToolProvider) {
        lock.lock()
        defer { lock.unlock() }
        tools[tool.name] = tool
    }

    public func tool(named name: String) -> (any ToolProvider)? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]
    }
}

/// The tools one turn may run.
///
/// The caller's `tools` array is the whole of what a turn may reach. It is what was rendered
/// into the model's tool specs, so a call for any other name — a hallucinated call, or one
/// injected through the prompt — is a name the turn never offered and must be **refused rather
/// than dispatched**. Before this, dispatch went straight to `ToolRegistry.run(name:)` against
/// the injected registry, so `ConversationEngine` passing `tools: []` when the user had turned
/// web search off still let an emitted `web_search` call reach the network: a setting the
/// interface presents as "off" did not stop an outbound request (audit A104).
///
/// The registry remains the place a provider instance is injected — the CLI builds one with
/// `WebToolbox.makeRegistry()` and hands it to the engine — but it can only decide *which*
/// instance answers a name the caller offered. It can never widen the set.
///
/// `Sendable` because `byName` is built once in `init` and never mutated. The dictionary crosses
/// into `generateExclusively` and is read there while the model streams, but every value is a
/// `ToolProvider`, which refines `Sendable`, so no lock is needed.
struct TurnToolSet: Sendable {
    private let byName: [String: any ToolProvider]

    init(offered tools: [any ToolProvider], registry: ToolRegistry) {
        var resolved: [String: any ToolProvider] = [:]
        for tool in tools {
            // An offered tool runs even if the registry has never heard of it: the caller's
            // array is what makes it available. When the registry does know the name, its
            // instance is preferred, which is the injection point the CLI relies on.
            resolved[tool.name] = registry.tool(named: tool.name) ?? tool
        }
        self.byName = resolved
    }

    /// True when the caller offered no tools, which is how a seat with web search turned off
    /// arrives here.
    var isEmpty: Bool { byName.isEmpty }

    /// The names this turn may run, for the refusal message.
    var names: [String] { byName.keys.sorted() }

    /// Never throws: a refused or failed tool is reported back to the model as text so it can
    /// adapt, instead of killing the turn.
    func run(name: String, argument: String) async -> ToolOutcome {
        guard let tool = byName[name] else {
            let available = names.isEmpty ? "none" : names.joined(separator: ", ")
            return ToolOutcome(
                text: "Error: \(name) is not available in this turn. Available tools: \(available).",
                summary: "refused \(name) (not offered this turn)"
            )
        }
        do {
            return try await tool.run(argument: argument)
        } catch {
            return ToolOutcome(
                text: "Error from \(name): \(error.localizedDescription)",
                summary: "\(name) failed"
            )
        }
    }
}
