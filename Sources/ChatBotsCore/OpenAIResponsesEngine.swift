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
        self.currentDisplayName = spec.displayName
        self.currentThinking = spec.thinking
        self.currentPersona = spec.personaID
        self.onStateChange = onStateChange
    }

    public var isLoaded: Bool { ready }

    /// The seat's context window, which no OpenAI-compatible server advertises through
    /// `/v1/models`.
    ///
    /// If the same checkpoint happens to be on disk, its own config is authoritative and
    /// is preferred — guessing too large here would mean compaction never ran. Otherwise
    /// the configured value is used.
    public var contextWindow: Int {
        ModelStore.declaredContextWindow(for: spec.modelID) ?? spec.contextWindow
    }

    /// Condense a transcript through the same endpoint, with no tools.
    public func compact(prompt: String, maxTokens: Int) async throws -> String {
        var spec = self.spec
        spec.maxTokens = maxTokens
        spec.thinking = .off
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

    public var lastStats: TurnStats? { lastStatsValue }

    /// Live display name, thinking level and style.
    ///
    /// These have to be held here rather than read from `spec`: a seat reaches the UI
    /// through this engine, and the UI changes it while a conversation runs, so `spec` is
    /// only the configuration it was built with.
    private var currentDisplayName: String
    private var currentThinking: ThinkingMode
    private var currentPersona: String

    public func setDisplayName(_ name: String) { currentDisplayName = name }
    public func setThinking(_ mode: ThinkingMode) { currentThinking = mode }
    public func setPersona(_ personaID: String) { currentPersona = personaID }

    public var persona: PersonaStyle {
        PersonaCatalog.style(id: currentPersona, mode: spec.mode)
    }
    public var thinking: ThinkingMode { currentThinking }

    public var currentSpec: AgentSpec {
        var live = spec
        live.displayName = currentDisplayName
        live.thinking = currentThinking
        live.personaID = currentPersona
        return live
    }

    // MARK: - Reaching the server

    public func load() async throws {
        onStateChange(.loading(progress: 0))
        // A strict endpoint with no key will only ever 401, so say so before trying.
        if spec.openAI.isMissingKey {
            let message =
                "\(spec.openAI.baseURL) needs an API key — set one in the API sheet, or export OPENAI_API_KEY"
            onStateChange(.failed(message))
            throw OpenAIResponsesError.streamFailed(message)
        }
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
        // The reachability probe must authenticate the same way the real request does,
        // including the built-in key, or a working endpoint would look unreachable.
        if let key = spec.openAI.effectiveAPIKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OpenAIResponsesError.http(
                status: status,
                body: UTF8Text.decodeTruncated(UTF8Text.bytePrefix(data, 300)) ?? "")
        }
        return try Self.modelIDs(fromModelsBody: data)
    }

    /// The model ids in a `/v1/models` body.
    ///
    /// A body that is not JSON, or not the shape the endpoint documents, is an **error**, not an
    /// empty list. `try? JSONSerialization…` used to swallow the decode failure into `[]`, which
    /// `load` then reported as "the server has no model loaded — load one in LM Studio" (audit
    /// A57): a server that answered was described as a server with no model, and the moderator
    /// was told to do something that would not help.
    static func modelIDs(fromModelsBody data: Data) throws -> [String] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OpenAIResponsesError.streamFailed(
                "the server's /v1/models response could not be read as JSON: "
                    + error.localizedDescription)
        }
        guard let root = object as? [String: Any] else {
            throw OpenAIResponsesError.streamFailed(
                "the server's /v1/models response was not a JSON object")
        }
        guard let entries = root["data"] as? [[String: Any]] else {
            throw OpenAIResponsesError.streamFailed(
                "the server's /v1/models response did not contain a model list")
        }
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

    /// Images the seat was given, refreshed by the orchestrator each turn.
    ///
    /// An image whose bytes are not a type the Responses API accepts is *named* rather than
    /// dropped in silence. Intake converts anything ImageIO can read into PNG or JPEG and
    /// refuses the rest, so in normal use this cannot happen; it is reachable for an attachment
    /// restored from settings that was added before that, or built by a caller that bypassed
    /// intake. Either way the model must not be given a text-only turn with no indication that
    /// a picture was left behind.
    public func setAttachments(_ documents: [AttachedDocument]) async {
        var accepted: [OpenAIResponsesClient.ImageAttachment] = []
        for document in documents {
            guard document.kind.isImage else { continue }
            guard let mediaType = document.imageMediaType,
                let base64 = document.imageBase64
            else {
                let notice =
                    "[ChatBots] \(spec.id): image '\(document.name)' was not sent — its bytes "
                    + "are not a format the Responses API accepts\n"
                FileHandle.standardError.write(Data(notice.utf8))
                continue
            }
            accepted.append(
                OpenAIResponsesClient.ImageAttachment(mediaType: mediaType, base64: base64))
        }
        images = accepted
    }

    private var images: [OpenAIResponsesClient.ImageAttachment] = []

    public func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        // Probe only when this engine has not yet reached the server. `generate` used to call
        // `load()` unconditionally, so every turn paid a `/v1/models` round trip — and a
        // transient probe failure, or a server that does not serve `/v1/models` at all, failed
        // an otherwise good turn even though the model request itself would have worked. `ready`
        // is cleared by `unload()`, so a deliberate unload still re-probes on the next turn
        // (audit A57).
        if !ready {
            try await load()
        }
        let agentID = spec.id
        let started = Date.now

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
            maxOutputTokens: spec.serverOutputCap,
            includeReasoning: spec.thinking.thinks,
            reasoningEffort: spec.thinking.reasoningEffort,
            images: spec.visionSupport.allowsImages ? images : []
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

        let seconds = Date.now.timeIntervalSince(started)
        let final = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let stats = TurnStats(
            promptTokens: usage.inputTokens,
            prefillSeconds: 0,
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

extension AgentSpec {
    /// The output ceiling to ask a server for.
    ///
    /// Distinct from `generationCap`, which is an *answer* budget: for MLX that is the whole
    /// story, but a Responses-API server counts reasoning tokens against the same ceiling.
    /// Measured against DeepSeek, a reasoning model asked for 100 or 300 output tokens spent
    /// every one of them thinking and returned no text at all — the request is not "answer
    /// in 100 tokens", it is "stop after 100 tokens of any kind". So a floor is applied
    /// whenever the ceiling is small enough that reasoning would consume it.
    ///
    /// The floor is not a promise that the answer will be short; it only stops the answer
    /// being impossible. A seat genuinely wanting terse replies should use `thinking: off`.
    public var serverOutputCap: Int {
        // Even with thinking off this server-side ceiling counts every output token, so a
        // very small cap truncates the answer mid-sentence — measured: 60 tokens produced
        // "One advantage: ovoid eggs roll in " and nothing more. `effort: none` is honoured
        // (the response reported zero reasoning tokens), so thinking off really does mean
        // off; it just does not mean the answer can be arbitrarily short.
        guard thinking != ThinkingMode.off else { return max(maxTokens, 1_024) }
        // Measured against DeepSeek: with a ceiling of 100 or 300 every token went to
        // reasoning and the reply was empty. `deepseek-v4-pro` then completed at 1,024,
        // while `deepseek-flash` spent 1,511 on one request and more than 2,048 on the next
        // — the amount varies per request, so no floor is a guarantee.
        //
        // 4,096 is headroom rather than a prediction: this is a *ceiling*, not a target, so
        // a model that needs less stops earlier and pays nothing for the extra. What it
        // costs is the worst case, and the alternative — a reply that cannot be produced at
        // all — is worse. A seat that wants genuinely terse answers should set
        // `thinking: off`, where this floor does not apply.
        return max(maxTokens, 4_096)
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
