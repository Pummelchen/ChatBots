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
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Status of an engine's weights, for display.
public actor MLXEngine: LLMEngine {

    public let spec: AgentSpec
    let toolRegistry: ToolRegistry
    private let onStateChange: @Sendable (EngineState) -> Void

    // `container` and `currentThinking` are internal rather than private because `private` is
    // file-scoped in Swift and `MLXEngine+ReuseProbe.swift` drives a session against the loaded
    // container at the seat's live thinking level. Nothing outside this module can see them.
    var container: ModelContainer?
    private var loadingTask: Task<ModelContainer, Error>?
    private var loadedContextWindow = 32_768
    private var didLogConfiguration = false
    /// Live thinking level. Starts from the seat's spec and is changed between turns by
    /// the pane control; `spec` itself stays immutable because it is a protocol property.
    var currentThinking: ThinkingMode
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
    /// write was only ever discarded in a shape nobody was using yet.
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
                // Bounded where it is read. The value travels with the checkpoint, and it
                // flows into `ThinkingMode.generationCap` as an `Int` addition; a config
                // declaring a value near `Int.max` overflowed it and trapped on the first
                // turn. A million tokens is past anything this app can run, so the bound
                // costs nothing real.
                return min(value, Self.maximumContextWindow)
            }
        }
        return nil
    }

    /// The largest context window a checkpoint's `config.json` may declare.
    public static let maximumContextWindow = 1_048_576

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
    /// weights.
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

}

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
