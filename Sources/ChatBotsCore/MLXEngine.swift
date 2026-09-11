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

import Foundation
import HuggingFace
import MLXLLM
import MLXLMCommon
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

    /// Throughput of this seat's most recent turn, for diagnostics and benchmarks.
    public private(set) var lastStats: TurnStats?

    public init(
        spec: AgentSpec,
        toolRegistry: ToolRegistry = .shared,
        onStateChange: @escaping @Sendable (EngineState) -> Void = { _ in }
    ) {
        self.spec = spec
        self.toolRegistry = toolRegistry
        self.onStateChange = onStateChange
    }

    public var isLoaded: Bool { container != nil }

    public var contextWindow: Int { loadedContextWindow }

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
                try await #huggingFaceLoadModelContainer(
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
        // Copy the callbacks into locals: the tool-dispatch closure outlives this
        // scope, so it cannot capture the non-escaping parameters directly.
        let reportToolCall = onToolCall
        // `Chat.Message` is not Sendable (it can carry CIImage-backed media), so the
        // text prompt crosses into the model's isolation as plain strings and is
        // rebuilt inside `perform`.
        let promptText = messages.map { (role: $0.role.rawValue, content: $0.content) }

        let toolSpecs = tools.isEmpty ? nil : tools.map { Self.toolSpec(for: $0) }
        let toolRegistry = self.toolRegistry

        // `maxTokens` is what the model may *emit*, thinking included; give the
        // thinking block its own headroom so a long thought cannot eat the answer.
        var mutableParameters = GenerateParameters(
            maxTokens: spec.thinkingBudget + spec.maxTokens,
            temperature: Float(spec.temperature),
            topP: Float(spec.topP),
            seed: spec.samplingSeed
        )
        mutableParameters.repetitionPenalty = 1.05
        mutableParameters.repetitionContextSize = 256
        let parameters = mutableParameters
        let additionalContext = spec.reasoning.templateContext

        /// A conversation entry we can send across isolation. Tool metadata is kept
        /// alongside because `Chat.Message` itself is not `Sendable`.
        struct Entry: Sendable {
            var role: String
            var content: String
            var toolCalls: [ToolCall] = []
            var toolResultID: String?
        }

        var promptEntries = promptText.map { Entry(role: $0.role, content: $0.content) }

        let emitReasoning = spec.reasoning == .stream
        var answer = ""
        var stats = TurnStats()
        let started = Date()

        /// Everything sent on the round currently in flight. Each round restates the
        /// whole list (rather than leaning on the session to accumulate) because the
        /// session's KV cache still reuses the shared prefix, and being explicit keeps
        /// the Qwen tool protocol below correct.
        var round = 0
        let maxToolRounds = 3

        // Nested functions capture their context by reference, which the compiler
        // correctly refuses to send across `await`. Returning the segment and folding
        // it here keeps every mutation in this actor's isolation.
        func emit(_ segment: ThinkingStripper.Segment) async -> String {
            if !segment.reasoning.isEmpty, emitReasoning {
                await onEvent(.reasoning(agentID: agentID, text: segment.reasoning))
            }
            if !segment.answer.isEmpty {
                await onEvent(.token(agentID: agentID, text: segment.answer))
            }
            return segment.answer
        }

        // Both seats compute on the GPU. This is not a preference: Qwen 3.5's
        // linear-attention layers call `metal_kernel`, and MLX reports
        // "[metal_kernel] Only supports the GPU" if it is forced onto the CPU, so a
        // CPU seat is not possible for this checkpoint (and is slower for dense models
        // anyway). Apple GPUs are shared, so two seats coexist; when they generate at
        // the same time they time-share rather than overlap. The orchestrator's turn
        // loop is sequential, so in practice one seat is always idle.
        rounds: while true {
            let entriesForRound = promptEntries
            let stream = await container.perform {
                context -> AsyncThrowingStream<Generation, Error> in
                let messagesForRound = entriesForRound.map { entry in
                    Chat.Message(
                        role: Chat.Message.Role(rawValue: entry.role) ?? .user,
                        content: entry.content,
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

            var stripper = ThinkingStripper(startsPrimed: spec.reasoning != .off)
            var toolCalls: [ToolCall] = []

            for try await generation in stream {
                try Task.checkCancellation()
                switch generation {
                case .chunk(let text):
                    answer += await emit(stripper.process(text))

                case .toolCall(let call):
                    toolCalls.append(call)

                case .info(let info):
                    stats = TurnStats(
                        promptTokens: info.promptTokenCount,
                        generationTokens: info.generationTokenCount,
                        cachedPromptTokens: 0,
                        stopReason: Self.describe(info.stopReason),
                        tokensPerSecond: info.generateTime > 0
                            ? Double(info.generationTokenCount) / info.generateTime
                            : 0,
                        seconds: Date().timeIntervalSince(started)
                    )
                }
            }

            // A held-back partial delimiter must still be attributed to this round.
            answer += await emit(stripper.finalize())

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

        let final = Self.clean(answer, spec: spec)
        if stats.generationTokens == 0 {
            stats.seconds = Date().timeIntervalSince(started)
        }
        if final.isEmpty, stats.stopReason == "length" {
            await onEvent(
                .toolFailure(
                    agentID: agentID,
                    name: "generation",
                    message: "the model spent its whole token budget without producing an answer — raise max tokens"
                )
            )
        }

        lastStats = stats
        await onEvent(.turnFinished(agentID: agentID, text: final, stats: stats))
        logConfigurationOnce(container: container, spec: spec)
        return final
    }

    private func logConfigurationOnce(container: ModelContainer, spec: AgentSpec) {
        guard !didLogConfiguration else { return }
        didLogConfiguration = true
        let context = loadedContextWindow
        FileHandle.standardError.write(
            Data(
                "[ChatBots] \(spec.id) \(spec.modelID) ready — context \(context) tok, reasoning \(spec.reasoning.rawValue)\n"
                    .utf8)
        )
    }

    // MARK: - Helpers

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
    static func exclusive<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        await shared.acquire()
        defer { Task { await shared.release() } }
        return try await body()
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
