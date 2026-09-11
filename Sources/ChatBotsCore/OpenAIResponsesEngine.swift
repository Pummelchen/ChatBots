// ChatBotsCore — an LLM seat backed by the OpenAI Responses API
//
// Same `LLMEngine` contract as the in-process MLX engine, so a seat can be either one and
// the orchestrator never knows the difference. The differences that do exist are real and
// are stated here rather than hidden:
//
//   * Sampling maps to the Responses API's parameters. `temperature`, `top_p` and the
//     token cap are standard; `top_k`, `min_p` and `repetition_penalty` are LM Studio
//     extensions and are ignored by servers that do not implement them.
//   * The presence penalty uses OpenAI's sign convention (positive discourages
//     repetition), which is the opposite of MLX's. The seat stores the MLX sign, so this
//     engine negates it — one of only two places that happens.
//   * Web search tools are NOT wired up here. They are dispatched in-process by the MLX
//     engine and are currently unavailable on this backend, so a seat that switches
//     backend loses them. The UI says so.
//   * The server owns the weights, so "loading" is a reachability and model-existence
//     check rather than a weight load, and there is nothing to unload.

import Foundation

public actor OpenAIResponsesEngine: LLMEngine {

    public let spec: AgentSpec
    private let onStateChange: @Sendable (EngineState) -> Void
    private var ready = false
    private var lastError: String?
    private var lastStatsValue: TurnStats?

    public init(
        spec: AgentSpec,
        onStateChange: @escaping @Sendable (EngineState) -> Void = { _ in }
    ) {
        self.spec = spec
        self.onStateChange = onStateChange
    }

    public var isLoaded: Bool { ready }

    public var contextWindow: Int {
        // The server decides; the UI's context estimate is advisory either way.
        32_768
    }

    public var lastStats: TurnStats? { lastStatsValue }

    public var currentSpec: AgentSpec { spec }

    // MARK: - Reaching the server

    public func load() async throws {
        onStateChange(.loading(progress: 0))
        do {
            let models = try await availableModels()
            guard !models.isEmpty else {
                throw OpenAIResponsesError.streamFailed(
                    "the server has no model loaded — load one in LM Studio, then retry")
            }
            // Warn rather than fail on a name mismatch: some servers accept any id.
            if !models.contains(where: { $0 == spec.openAI.model }) {
                FileHandle.standardError.write(
                    Data(
                        "[ChatBots] \(spec.openAI.model) is not in the server's model list (\(models.joined(separator: ", "))); sending it anyway\n"
                            .utf8))
            }
            ready = true
            lastError = nil
            onStateChange(.ready)
        } catch {
            lastError = error.localizedDescription
            onStateChange(.failed(error.localizedDescription))
            throw error
        }
    }

    public func unload() async {
        // Nothing is resident locally; the server keeps its own lifecycle.
        ready = false
        onStateChange(.idle)
    }

    private func availableModels() async throws -> [String] {
        guard let url = endpointURL(path: "/v1/models") else {
            throw OpenAIResponsesError.badURL(spec.openAI.baseURL)
        }
        var request = URLRequest(url: url)
        if let key = spec.openAI.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OpenAIResponsesError.http(
                status: status,
                body: String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = root?["data"] as? [[String: Any]] ?? []
        return entries.compactMap { $0["id"] as? String }
    }

    private func endpointURL(path: String) -> URL? {
        var base = spec.openAI.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return URL(string: base + path)
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
        let agentID = spec.id
        let started = Date()

        if !tools.isEmpty {
            FileHandle.standardError.write(
                Data(
                    "[ChatBots] \(agentID) is on the OpenAI backend: its \(tools.count) web tool(s) are unavailable there\n"
                        .utf8))
        }

        // The harness logs has already been rendered into one user message by
        // PromptBuilder; the system message becomes the Responses API `instructions`.
        let instructions = messages.first { $0.role == .system }?.content
        let input = messages.filter { $0.role != .system }.map(\.content).joined(separator: "\n\n")

        let request = OpenAIResponsesClient.Request(
            instructions: instructions,
            input: input,
            temperature: spec.temperature,
            topP: spec.topP,
            topK: spec.topK > 0 ? spec.topK : nil,
            minP: spec.minP,
            presencePenalty: spec.presencePenalty,
            repetitionPenalty: spec.repetitionPenalty,
            maxOutputTokens: spec.generationCap,
            includeReasoning: spec.thinking.thinks,
            reasoningEffort: spec.thinking.reasoningEffort
        )

        let client = OpenAIResponsesClient(endpoint: spec.openAI)
        var answer = ""
        var usage = OpenAIUsage()
        var failed: String?

        for try await event in client.stream(request) {
            try Task.checkCancellation()
            switch event {
            case .text(let delta):
                answer += delta
                await onEvent(.token(agentID: agentID, text: delta))

            case .reasoning(let delta):
                await onEvent(.reasoning(agentID: agentID, text: delta))

            case .completed(let reported):
                usage = reported

            case .failed(let message):
                failed = message
            }
        }

        if let failed {
            await onEvent(.turnFailed(agentID: agentID, message: failed))
            throw OpenAIResponsesError.streamFailed(failed)
        }

        let seconds = Date().timeIntervalSince(started)
        let final = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let stats = TurnStats(
            promptTokens: usage.inputTokens,
            generationTokens: usage.outputTokens,
            cachedPromptTokens: usage.cachedTokens,
            stopReason: final.isEmpty ? "empty" : "stop",
            tokensPerSecond: seconds > 0 ? Double(usage.outputTokens) / seconds : 0,
            seconds: seconds
        )
        lastStatsValue = stats

        if final.isEmpty {
            await onEvent(
                .turnFailed(
                    agentID: agentID,
                    message:
                        "the server returned no text (reasoning tokens: \(usage.reasoningTokens)) — raise the output limit or turn thinking off"
                )
            )
        }

        await onEvent(.turnFinished(agentID: agentID, text: final, stats: stats))
        return final
    }
}

extension ThinkingMode {
    /// The nearest `reasoning.effort` value, for servers that accept one.
    ///
    /// Distinct from the token-ceiling approach used by the MLX backend: a server-side
    /// effort hint is a request, so this is the *only* real effort control available, and
    /// only where a server implements `reasoning.effort`.
    public var reasoningEffort: String? {
        switch self {
        case .off: "none"
        case .minimal, .low: "low"
        case .medium: "medium"
        case .high, .unlimited: "high"
        }
    }
}

extension AgentSpec {
    /// Whether this seat's tools work on its backend. Used by the UI to warn honestly.
    public var toolsWorkOnBackend: Bool {
        backend == .mlx
    }
}
