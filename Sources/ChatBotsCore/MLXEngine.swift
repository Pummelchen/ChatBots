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

public actor MLXEngine: LLMEngine {

    public let spec: AgentSpec
    private let toolRegistry: ToolRegistry
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
    public private(set) var lastStats: TurnStats?

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
    public func setThinking(_ mode: ThinkingMode) {
        currentThinking = mode
    }

    /// The level this seat will use on its next turn.
    public var thinking: ThinkingMode { currentThinking }

    /// Rename this seat. Takes effect on its next turn.
    public func setDisplayName(_ name: String) {
        currentDisplayName = name
    }

    /// The moderator's images, as raw bytes.
    ///
    /// Bytes rather than `CIImage`/`UserInput.Image` because neither is `Sendable`, and the
    /// generate path crosses into the model's own isolation. `Data` crosses cleanly and is
    /// decoded on the far side, where the image is going to be used anyway.
    private var imageData: [Data] = []

    public func setAttachments(_ documents: [AttachedDocument]) async {
        imageData = documents.filter { $0.kind.isImage }.compactMap { document in
            guard let data = document.imageData, CIImage(data: data) != nil else {
                FileHandle.standardError.write(
                    Data("[ChatBots] \(spec.id) could not read the attached image \(document.name)\n".utf8))
                return nil
            }
            return data
        }
    }

    /// The style this seat will use on its next turn.
    public func setPersona(_ personaID: String) {
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
    public func compact(prompt: String, maxTokens: Int) async throws -> String {
        var spec = self.spec
        spec.maxTokens = maxTokens
        spec.thinking = .off  // summarising is not the place for deliberation
        let summary = try await generate(
            messages: [
                .init(role: .system, content: "You condense discussions faithfully and add nothing."),
                .init(role: .user, content: prompt),
            ],
            tools: [],
            onToolCall: { _, _ in },
            onEvent: { _ in }
        )
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
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
        try await load()

        // Held across the whole turn, not just the model call: the token stream keeps
        // evaluating on the GPU as it is consumed, so the slot must not be handed on
        // until that stream is drained. Release is explicit so ordering is
        // deterministic even on the error path.
        await MLXGate.shared.acquire()
        do {
            let text = try await generateExclusively(
                messages: messages, tools: tools, onToolCall: onToolCall, onEvent: onEvent)
            await MLXGate.shared.release()
            return text
        } catch {
            await MLXGate.shared.release()
            throw error
        }
    }

    /// The body of `generate`, run while holding the MLX gate.
    private func generateExclusively(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        guard let container else { throw ChatBotsError.engineNotLoaded }
        try Task.checkCancellation()

        let spec = self.spec
        let agentID = spec.id
        let thinking = currentThinking
        let reasoningCeiling = thinking.reasoningTokenBudget
        /// Answer budget plus whatever this thinking level allows for reasoning.
        let generationCap = spec.maxTokens + (reasoningCeiling ?? 0)
        // Copy the callbacks into locals: the tool-dispatch closure outlives this
        // scope, so it cannot capture the non-escaping parameters directly.
        let reportToolCall = onToolCall
        // `Chat.Message` is not Sendable (it can carry CIImage-backed media), so the
        // text prompt crosses into the model's isolation as plain strings and is
        // rebuilt inside `perform`.
        let promptText = messages.map { (role: $0.role.rawValue, content: $0.content) }

        let toolSpecs = tools.isEmpty ? nil : tools.map { Self.toolSpec(for: $0) }
        let toolRegistry = self.toolRegistry

        // The cap is the answer budget plus whatever the thinking mode allows for
        // reasoning. Sampling mirrors the seat's spec exactly.
        var mutableParameters = GenerateParameters(
            maxTokens: generationCap,
            temperature: Float(spec.temperature),
            topP: Float(spec.topP),
            topK: spec.topK,
            minP: Float(spec.minP),
            seed: spec.samplingSeed
        )
        // Both penalties are optional in the spec; `nil` leaves MLX's default (off).
        // Note MLX *subtracts* `presencePenalty`, so the spec stores it already signed.
        mutableParameters.presencePenalty = spec.presencePenalty.map(Float.init)
        mutableParameters.presenceContextSize = 256
        mutableParameters.repetitionPenalty = spec.repetitionPenalty.map(Float.init)
        mutableParameters.repetitionContextSize = 256
        let parameters = mutableParameters
        let additionalContext = thinking.templateContext

        /// A conversation entry we can send across isolation. Tool metadata is kept
        /// alongside because `Chat.Message` itself is not `Sendable`.
        struct Entry: Sendable {
            var role: String
            var content: String
            var toolCalls: [ToolCall] = []
            var toolResultID: String?
        }

        var promptEntries = promptText.map { Entry(role: $0.role, content: $0.content) }

        // Reasoning is streamed to the pane and never enters the log, so it is always
        // reported; `.off` simply produces none.
        let emitReasoning = thinking.thinks
        var answer = ""
        /// Set when this turn produced reasoning text, so an empty answer can be
        /// explained as "ran out of budget while thinking" rather than silence.
        var stripperSpentItsBudget = false
        /// Reasoning tokens seen this turn, for the mode's ceiling.
        var reasoningTokens = 0
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

        // Both seats compute on the GPU. This is not a preference: Qwen 3.5's
        // linear-attention layers call `metal_kernel`, and MLX reports
        // "[metal_kernel] Only supports the GPU" if it is forced onto the CPU, so a
        // CPU seat is not possible for this checkpoint (and is slower for dense models
        // anyway). Apple GPUs are shared, so two seats coexist; when they generate at
        // the same time they time-share rather than overlap. The orchestrator's turn
        // loop is sequential, so in practice one seat is always idle.
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
            reasoningTokens = 0
            repetition = RepetitionDetector()
            let entriesForRound = promptEntries
            // Captured before the closure: `container.perform` runs off the actor, so it can
            // see neither the engine's properties nor a mutable local.
            let imagesForRound: [Data] = isFirstRound ? imageData : []
            let stream = await container.perform {
                context -> AsyncThrowingStream<Generation, Error> in
                // Images ride on the user message itself. They are attached only while the
                // prompt is still the opening one: after a tool round the log already
                // contains the image turn, and re-sending it would both duplicate it in the
                // KV cache and confuse a template that expects one image token run.
                let attachImages = !imagesForRound.isEmpty
                var lastUserIndex: Int? = attachImages
                    ? entriesForRound.lastIndex { $0.role == "user" } : nil
                // Decoded here, inside the model's isolation, from bytes that crossed it.
                let decodedImages: [UserInput.Image] = imagesForRound.compactMap { data in
                    CIImage(data: data).map { UserInput.Image.ciImage($0) }
                }

                let messagesForRound = entriesForRound.enumerated().map { index, entry in
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
                    generateParameters: parameters,
                    additionalContext: additionalContext,
                    tools: toolSpecs
                )
                return session.streamDetails(to: messagesForRound)
            }

            var stripper = ThinkingStripper(startsPrimed: thinking.thinks)
            var toolCalls: [ToolCall] = []

            for try await generation in stream {
                try Task.checkCancellation()
                switch generation {
                case .chunk(let text):
                    let segment = stripper.process(text)
                    if !segment.reasoning.isEmpty {
                        stripperSpentItsBudget = true
                        reasoningTokens += segment.reasoning.count / 4
                    }
                    answer += segment.answer
                    await report(segment)

                    // Enforce the mode's ceiling. The budget is counted in roughly
                    // 4-characters-per-token units rather than exact token ids, which is
                    // accurate enough for "think less" and needs no extra bookkeeping
                    // from the generation loop.
                    if let ceiling = reasoningCeiling, ceiling > 0, reasoningTokens >= ceiling,
                        stripper.isInsideReasoning
                    {
                        reasoningWasTruncated = true
                        answer += Self.forcedThinkingExit
                        break
                    }

                    // A loop is a stop condition regardless of the token budget, which is
                    // what keeps a bad sampler setting from producing 32k tokens of noise.
                    if repetition.ingest(segment.answer) {
                        loopDetected = true
                        break rounds
                    }

                case .toolCall(let call):
                    toolCalls.append(call)

                case .info(let info):
                    stats = TurnStats(
                        promptTokens: info.promptTokenCount,
                        prefillSeconds: info.promptTime,
                        generationTokens: info.generationTokenCount,
                        cachedPromptTokens: 0,
                        stopReason: Self.describe(info.stopReason),
                        tokensPerSecond: info.generateTime > 0
                            ? Double(info.generationTokenCount) / info.generateTime
                            : 0,
                        seconds: Date.now.timeIntervalSince(started)
                    )
                }
            }

            // A held-back partial delimiter must still be attributed to this round.
            let tail = stripper.finalize()
            if !tail.reasoning.isEmpty { stripperSpentItsBudget = true }
            answer += tail.answer
            await report(tail)

            guard !toolCalls.isEmpty, toolSpecs != nil, round < maxToolRounds else { break rounds }
            round += 1

            // Assistant turn carrying the calls, then one tool result per call, then a
            // user turn to continue. This is exactly the shape the Qwen template renders.
            promptEntries.append(Entry(role: "assistant", content: "", toolCalls: toolCalls))
            for call in toolCalls {
                let name = call.function.name
                let argument = Self.argumentString(of: call)
                await reportToolCall(name, argument)

                let outcome = await toolRegistry.run(name: name, argument: argument)
                await onEvent(
                    .toolResult(agentID: agentID, name: name, summary: outcome.summary, detail: outcome.text)
                )
                promptEntries.append(
                    Entry(role: "tool", content: outcome.text, toolResultID: call.id))
            }
            promptEntries.append(
                Entry(
                    role: "user",
                    content: """
                    [Tool results above] Continue your message to the group. Use what the \
                    results add, and drop any claim they contradict. If they did not settle \
                    the point, say so and answer from what you know rather than searching again \
                    with the same wording.
                    """
                )
            )
        }

        let scrubbed = Self.stripFabricatedToolSyntax(answer)
        if scrubbed.removedLines > 0 {
            FileHandle.standardError.write(
                Data(
                    "[ChatBots] \(agentID) stripped \(scrubbed.removedLines) line(s) of fabricated tool syntax from the answer\n"
                        .utf8))
        }
        let final = Self.clean(scrubbed.text, spec: spec)
        if stats.generationTokens == 0 {
            stats.seconds = Date.now.timeIntervalSince(started)
        }
        // A reasoning model can burn the entire budget inside `<think>` and emit no
        // answer at all. That is legitimate behaviour, not an error, but the user must be
        // told — otherwise the pane just stays empty with no explanation.
        if final.isEmpty, stripperSpentItsBudget {
            await onEvent(
                .toolFailure(
                    agentID: agentID,
                    name: "generation",
                    message: "spent the whole \(generationCap)-token budget thinking and produced no answer — raise the thinking level's headroom or turn thinking off"
                )
            )
        }

        lastStats = stats
        if loopDetected {
            await onEvent(
                .toolFailure(
                    agentID: agentID,
                    name: "generation",
                    message: "the model fell into a repetition loop and the turn was ended — its sampler settings are too loose for this prompt"
                )
            )
        }

        if reasoningWasTruncated {
            await onEvent(
                .toolFailure(
                    agentID: agentID,
                    name: "thinking",
                    message: "thinking stopped at the \(thinking.label.lowercased()) ceiling (\(reasoningCeiling ?? 0) tokens) and the model answered from there"
                )
            )
        }

        await onEvent(.turnFinished(agentID: agentID, text: final, stats: stats))
        logConfigurationOnce(container: container, spec: spec)
        return final
    }

    private func logConfigurationOnce(container: ModelContainer, spec: AgentSpec) {
        guard !didLogConfiguration else { return }
        didLogConfiguration = true
        let context = loadedContextWindow
        let sampler = String(
            format: "temp=%.2f topP=%.2f topK=%d minP=%.2f presence=%@ repetition=%@ maxOut=%d",
            spec.temperature, spec.topP, spec.topK, spec.minP,
            spec.presencePenalty.map { String(format: "%.2f", $0) } ?? "off",
            spec.repetitionPenalty.map { String(format: "%.2f", $0) } ?? "off",
            spec.generationCap)
        FileHandle.standardError.write(
            Data(
                "[ChatBots] \(spec.id) \(spec.modelID) ready — context \(context) tok, thinking \(currentThinking.rawValue)\n[ChatBots] \(spec.id) sampler: \(sampler)\n"
                    .utf8)
        )
    }

    // MARK: - Helpers

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
    private static func clean(_ text: String, spec: AgentSpec) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["<think>", "</think>"] where output.hasPrefix(marker) {
            output.removeFirst(marker.count)
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["[\(spec.id)]", "\(spec.id):", "\(spec.displayName):"]
        where output.hasPrefix(prefix) {
            output.removeFirst(prefix.count)
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return output
    }

    private static func describe(_ reason: GenerateStopReason) -> String {
        switch reason {
        case .stop: "stop"
        case .length: "length"
        case .cancelled: "cancelled"
        }
    }

    private static func toolSpec(for tool: any ToolProvider) -> ToolSpec {
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

    /// Never throws: a failed tool is reported back to the model as text so it can
    /// adapt, instead of killing the turn.
    func run(name: String, argument: String) async -> ToolOutcome {
        guard let tool = tool(named: name) else {
            return ToolOutcome(
                text: "Error: no tool named \"\(name)\" exists. Available tools: web_search, fetch_page.",
                summary: "unknown tool \(name)"
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
