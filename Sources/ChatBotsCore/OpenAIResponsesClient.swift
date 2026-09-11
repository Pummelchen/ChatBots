// ChatBotsCore — OpenAI Responses API backend
//
// The current OpenAI API is the Responses API (`POST /v1/responses`), not the older
// `/v1/chat/completions`, and LM Studio serves it locally (0.3.39+, and Open Responses
// compliant) as well as OpenAI hosting it. One client therefore drives a local model or a
// cloud one; only the base URL and key differ.
//
// The streaming protocol is server-sent events carrying *typed* events, which is a
// meaningfully different shape from chat completions: text arrives as
// `response.output_text.delta`, the model's thinking arrives on its own
// `response.reasoning_text.delta` channel, and the terminal event is `response.completed`.
// Errors can arrive mid-stream as `response.failed` or an `error` event, so a completed
// stream is the only thing that counts as success.

import Foundation

public enum OpenAIResponsesError: LocalizedError, Sendable {
    case badURL(String)
    case http(status: Int, body: String)
    case streamFailed(String)
    case noOutput
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .badURL(let value):
            "Not a usable base URL: \(value)"
        case .http(let status, let body):
            "Server returned HTTP \(status): \(UTF8Text.prefix(body, 300))"
        case .streamFailed(let message):
            "The response failed: \(message)"
        case .noOutput:
            "The server completed the response without producing any text."
        case .cancelled:
            "Cancelled."
        }
    }
}

/// Which parameters an endpoint will accept.
///
/// The Responses API's schema is fixed but not every implementation tolerates unknown
/// keys: OpenAI itself validates strictly and rejects anything outside its schema, while
/// local engines (LM Studio) accept extensions. Sending `top_k` to OpenAI is a 400, so the
/// choice has to be explicit rather than assumed.
public enum APICompatibility: String, Sendable, Codable, CaseIterable, Identifiable {
    /// OpenAI proper: only parameters in the published schema.
    case strict
    /// Local engines: also send `top_k`, `min_p` and `repetition_penalty`.
    case extended

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .strict: "OpenAI (strict)"
        case .extended: "Extended (LM Studio et al.)"
        }
    }

    /// A sensible default from the URL: anything that is not OpenAI is probably local.
    public static func inferred(fromBaseURL baseURL: String) -> APICompatibility {
        let lowered = baseURL.lowercased()
        let isOpenAI =
            lowered.contains("api.openai.com")
            || lowered.contains("openai.azure.com")
            || lowered.contains("openrouter.ai")
        return isOpenAI ? .strict : .extended
    }
}

/// Human names for model identifiers.
///
/// The point is that a model should be called what its maker calls it, not what its API slug
/// happens to be. A server reports `deepseek-v4-pro`; the product is DeepSeek V4.1 Flash. Left
/// to the raw id, every screen in the app shows the slug, and the same model gets a different
/// label depending on which server it was reached through.
public enum ModelNames {

    /// Known identifiers and the name to show for them, longest match first so a more
    /// specific entry wins over a general one.
    private static let table: [(match: String, name: String)] = [
        ("deepseek-v4-pro", "DeepSeek V4.1 Pro"),
        ("deepseek-v4.1-pro", "DeepSeek V4.1 Pro"),
        ("deepseek-v4-flash", "DeepSeek V4.1 Flash"),
        ("deepseek-v4.1-flash", "DeepSeek V4.1 Flash"),
        ("deepseek-v4", "DeepSeek V4.1"),
        ("deepseek-v3", "DeepSeek V3"),
        ("deepseek-reasoner", "DeepSeek Reasoner"),
        ("deepseek-chat", "DeepSeek Chat"),
        ("gpt-4o-mini", "GPT-4o mini"),
        ("gpt-4o", "GPT-4o"),
        ("gpt-4.1-mini", "GPT-4.1 mini"),
        ("gpt-4.1", "GPT-4.1"),
        ("claude-opus-4", "Claude Opus 4"),
        ("claude-sonnet-4", "Claude Sonnet 4"),
        ("claude-haiku-4", "Claude Haiku 4"),
        ("claude-3-5-sonnet", "Claude 3.5 Sonnet"),
        ("claude-3-5-haiku", "Claude 3.5 Haiku"),
        ("gemini-2.5-pro", "Gemini 2.5 Pro"),
        ("gemini-2.5-flash", "Gemini 2.5 Flash"),
    ]

    /// The name to show for a model identifier.
    ///
    /// An unknown identifier is cleaned up rather than discarded: separators become spaces and
    /// words are capitalised, so `my-org/llama-3-8b-instruct` reads as "Llama 3 8b Instruct"
    /// instead of being shown raw or left blank.
    public static func friendly(_ modelID: String) -> String {
        let lowered = modelID.lowercased()
        // Drop a server prefix such as `mlx-community/` before matching.
        let slug = lowered.split(separator: "/").last.map(String.init) ?? lowered
        if let known = table.first(where: { slug.contains($0.match) }) { return known.name }
        return prettify(slug)
    }

    /// Turn a slug into something readable without pretending to know what it is.
    static func prettify(_ slug: String) -> String {
        let words = slug.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
        guard !words.isEmpty else { return slug }
        return words.map { word -> String in
            // Keep a version-like token as it is: "4b" reads better than "4B" inside a name
            // that is already mixed case, and "8b" is not a word.
            if word.first?.isNumber == true { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}

/// Keys the app can find for itself, so it works without a setup step.
///
/// **Not compiled into the source.** A key in a repository is a key that is public the moment
/// the repository is, and GitHub refuses the push anyway — its secret scanning blocked exactly
/// that. So the key is read, in order, from:
///
///   1. the environment (`DEEPSEEK_API_KEY`), for a shell or a launch agent
///   2. a local file, `.secrets.env` in the project root, which is gitignored
///   3. the value an endpoint already holds, if the user typed one
///
/// The file is the practical route on a desktop: present, but never committed. A fresh clone
/// without it simply has no DeepSeek key, which the interface already reports rather than
/// failing silently.
public enum BuiltInKeys {

    /// The environment variable that supplies the key.
    public static let deepSeekEnvironmentKey = "DEEPSEEK_API_KEY"

    /// The gitignored file the key can be read from.
    public static let secretsFileName = ".secrets.env"

    /// The DeepSeek key, or nil when this machine has none configured.
    public static var deepSeek: String? {
        if let value = ProcessInfo.processInfo.environment[deepSeekEnvironmentKey],
            !value.trimmingCharacters(in: .whitespaces).isEmpty
        {
            return value.trimmingCharacters(in: .whitespaces)
        }
        return secretsFile()[deepSeekEnvironmentKey]
    }

    /// Parse `.secrets.env`, one `NAME=value` per line.
    ///
    /// Deliberately minimal: no expansion, no quoting rules, no includes. It holds one or two
    /// keys and a parser with features is a parser with surprises.
    public static func secretsFile(in root: URL? = nil) -> [String: String] {
        let directory = root ?? ModelStore.projectRoot() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = directory.appending(path: secretsFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var values: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[trimmed.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            // Tolerate quotes, because people write them.
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !name.isEmpty { values[name] = value }
        }
        return values
    }

    /// The key for a base URL, or nil when this app has none to offer.
    ///
    /// The host is compared **exactly**, not by substring. `contains("api.deepseek.com")`
    /// would match `api.deepseek.com.evil.test`, which is a lookalike domain someone could
    /// register — and sending a real key there is the one mistake that turns a convenience
    /// into a disclosure. The host is taken from the parsed URL, so a path or a query that
    /// happens to contain the name cannot fool it either.
    public static func key(forBaseURL baseURL: String) -> String? {
        guard let host = host(of: baseURL), allowedHosts.contains(host) else { return nil }
        return deepSeek
    }

    /// The hosts this app will send its built-in key to.
    static let allowedHosts: Set<String> = ["api.deepseek.com"]

    /// The host of a base URL, lowercased, or nil when there is not one.
    static func host(of baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        // A base URL is normally given with a scheme; tolerate one without.
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URLComponents(string: candidate)?.host else { return nil }
        return host.lowercased()
    }
}

/// Configuration for an OpenAI-compatible endpoint.
public struct OpenAIEndpoint: Sendable, Hashable, Codable {
    /// Base URL without a path, e.g. `http://localhost:1234`. `/v1/responses` is appended.
    public var baseURL: String
    /// Model identifier as the *server* names it. For LM Studio this is the loaded model's
    /// identifier, which is its path-like key.
    public var model: String
    /// Optional bearer token. Local servers usually need none; OpenAI requires one.
    public var apiKey: String?
    /// Which parameters this endpoint accepts.
    public var compatibility: APICompatibility

    public init(
        baseURL: String = "http://localhost:1234",
        model: String = "mlx-community/Qwen3.5-4B-MLX-4bit",
        apiKey: String? = nil,
        compatibility: APICompatibility? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.compatibility = compatibility ?? APICompatibility.inferred(fromBaseURL: baseURL)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "http://localhost:1234"
        self.baseURL = baseURL
        self.model =
            try container.decodeIfPresent(String.self, forKey: .model)
            ?? "mlx-community/Qwen3.5-4B-MLX-4bit"
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        // Older saved settings predate the field; infer from the URL.
        self.compatibility =
            try container.decodeIfPresent(APICompatibility.self, forKey: .compatibility)
            ?? APICompatibility.inferred(fromBaseURL: baseURL)
    }

    /// True when a key is needed but missing, which is worth saying before a wasted request.
    /// The key actually sent: an explicit one wins, then the environment, then the key built
    /// into this app, and only for a host that key belongs to.
    ///
    /// Resolved here rather than stored, so a saved endpoint keeps whatever the user typed
    /// and the fallback stays a fallback — nothing is written into their settings that they
    /// did not put there.
    public var effectiveAPIKey: String? {
        if let apiKey, !apiKey.isEmpty { return apiKey }
        return BuiltInKeys.key(forBaseURL: baseURL)
    }

    public var isMissingKey: Bool {
        compatibility == .strict && (effectiveAPIKey ?? "").isEmpty
    }

    /// The full endpoint, tolerating a base URL given with or without a trailing slash or
    /// with `/v1` already present.
    public var responsesURL: URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        let path = trimmed.hasSuffix("/v1") ? "/responses" : "/v1/responses"
        return URL(string: trimmed + path)
    }

    /// Derived from the model id so the UI can show something short.
    /// The name to show for this endpoint's model.
    ///
    /// Superseded by `ModelNames.friendly`, which knows what the models are actually called;
    /// kept because it is the sensible fallback for an identifier nothing recognises.
    public var shortModelName: String {
        ModelNames.friendly(model)
    }
}

/// One streamed piece of a response.
public enum OpenAIStreamEvent: Sendable {
    case text(String)
    case reasoning(String)
    /// Usage and timing from the terminal event.
    case completed(OpenAIUsage)
    case failed(String)
}

public struct OpenAIUsage: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var cachedTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, reasoningTokens: Int = 0, cachedTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedTokens = cachedTokens
    }
}

public struct OpenAIResponsesClient: Sendable {
    private let endpoint: OpenAIEndpoint
    private let session: URLSession

    public init(endpoint: OpenAIEndpoint) {
        self.endpoint = endpoint
        var configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3_600
        configuration.httpAdditionalHeaders = ["User-Agent": "ChatBots/1.0 (macOS)"]
        self.session = URLSession(configuration: configuration)
    }

    /// Everything a request can set. Mirrors the app's seat configuration; fields the
    /// endpoint does not understand are simply included and ignored by servers that do
    /// not know them (the Responses API is extensible by design).
    /// One attached image, ready to send.
    public struct ImageAttachment: Sendable, Hashable {
        public var mediaType: String
        public var base64: String

        public init(mediaType: String, base64: String) {
            self.mediaType = mediaType
            self.base64 = base64
        }

        public var dataURL: String { "data:\(mediaType);base64,\(base64)" }
    }

    public struct Request: Sendable {
        public var instructions: String?
        public var input: String
        public var temperature: Double?
        public var topP: Double?
        /// OpenAI's newer `top_k`, and the LM Studio extensions below, are not part of the
        /// published schema; they are sent because local engines accept them and unknown
        /// keys are ignored elsewhere.
        public var topK: Int?
        public var minP: Double?
        public var presencePenalty: Double?
        public var repetitionPenalty: Double?
        public var maxOutputTokens: Int?
        /// Ask for the model's reasoning, if the server exposes it.
        public var includeReasoning: Bool
        /// LM Studio accepts a JSON-schema-ish `reasoning` object; `effort` maps to the
        /// app's thinking levels where supported.
        public var reasoningEffort: String?
        /// Images to send with the prompt. Non-empty only for a seat that can see.
        public var images: [ImageAttachment] = []

        public init(
            instructions: String? = nil,
            input: String,
            temperature: Double? = nil,
            topP: Double? = nil,
            topK: Int? = nil,
            minP: Double? = nil,
            presencePenalty: Double? = nil,
            repetitionPenalty: Double? = nil,
            maxOutputTokens: Int? = nil,
            includeReasoning: Bool = false,
            reasoningEffort: String? = nil,
            images: [ImageAttachment] = []
        ) {
            self.instructions = instructions
            self.input = input
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.minP = minP
            self.presencePenalty = presencePenalty
            self.repetitionPenalty = repetitionPenalty
            self.maxOutputTokens = maxOutputTokens
            self.includeReasoning = includeReasoning
            self.reasoningEffort = reasoningEffort
            self.images = images
        }
    }

    /// Stream a response. Throws for transport and HTTP errors; per-event failures arrive
    /// as `.failed`.
    public func stream(_ request: Request) -> AsyncThrowingStream<OpenAIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Accumulates decoded text, holding back a trailing partial UTF-8 sequence until the
    /// next chunk completes it.
    ///
    /// A server that cuts its stream between bytes rather than between characters would
    /// otherwise deliver `U+FFFD` in place of the character. MLX's own streaming
    /// detokenizer guards this explicitly — "if the new segment ends with REPLACEMENT
    /// CHARACTER this means that the token didn't produce a complete unicode character" —
    /// and this is the equivalent for the HTTP path.
    public struct UTF8StreamBuffer: Sendable {
        public init() {}
        private var pending = Data()

        /// Feed raw bytes, which may end mid-character.
        ///
        /// Prefer this over the `String` overload: decoding a byte fragment on its own
        /// produces replacement characters *before* the buffer can reassemble it, which is
        /// the very thing this exists to prevent.
        public mutating func append(_ bytes: Data) -> String {
            pending.append(bytes)
            guard let text = String(data: pending, encoding: .utf8) else {
                // Incomplete tail: wait for the rest. Bounded, so a genuinely undecodable
                // stream cannot buffer without limit.
                if pending.count > 16 {
                    let salvaged = UTF8Text.decodeTruncated(pending) ?? ""
                    pending = Data()
                    return salvaged
                }
                return ""
            }
            pending = Data()
            return text
        }

        /// Feed an already-decoded chunk. Safe only when the chunk is known to be whole;
        /// see `append(_:)` for the byte form.
        public mutating func append(_ chunk: String) -> String {
            append(Data(chunk.utf8))
        }

        /// Bytes still held when the stream ends. An incomplete final character is dropped
        /// rather than emitted as a replacement character.
        public mutating func flush() -> String {
            defer { pending = Data() }
            return UTF8Text.decodeTruncated(pending) ?? ""
        }
    }


    private func run(
        _ request: Request,
        into continuation: AsyncThrowingStream<OpenAIStreamEvent, Error>.Continuation
    ) async throws {
        guard let url = endpoint.responsesURL else {
            throw OpenAIResponsesError.badURL(endpoint.baseURL)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = endpoint.effectiveAPIKey, !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if ProcessInfo.processInfo.environment["CHATBOTS_TRACE_API"] != nil {
            let preview = String(
                data: (try? JSONSerialization.data(
                    withJSONObject: body(for: request), options: [.sortedKeys])) ?? Data(),
                encoding: .utf8) ?? "?"
            FileHandle.standardError.write(Data("[trace] POST \(url.absoluteString)\n[trace] \(preview)\n".utf8))
        }
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: body(for: request), options: [])

        let (bytes, response) = try await session.bytes(for: urlRequest)
        // `flush()` is applied after the loop, below.

        guard let http = response as? HTTPURLResponse else {
            throw OpenAIResponsesError.streamFailed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The body carries the server's explanation; read a little of it.
            var detail = ""
            for try await line in bytes.lines {
                detail += line
                if detail.count > 600 { break }
            }
            throw OpenAIResponsesError.http(status: http.statusCode, body: detail)
        }

        var sawText = false
        var utf8 = UTF8StreamBuffer()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let payload = Self.dataPayload(from: line) else { continue }
            if payload == "[DONE]" { break }
            guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                as? [String: Any]
            else { continue }

            let type = event["type"] as? String ?? ""
            switch type {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String, !delta.isEmpty {
                    // Through the buffer: a chunk may end mid-character.
                    let safe = utf8.append(delta)
                    if !safe.isEmpty {
                        sawText = true
                        continuation.yield(.text(safe))
                    }
                }

            case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
                if let delta = event["delta"] as? String, !delta.isEmpty {
                    continuation.yield(.reasoning(delta))
                }

            case "response.completed", "response.done":
                // A response can complete having produced no text at all when the model
                // only reasoned or only called a tool; the caller decides what that means.
                _ = sawText
                continuation.yield(.completed(Self.usage(from: event)))

            case "response.failed", "response.incomplete":
                let message = Self.failureMessage(from: event)
                continuation.yield(.failed(message))

            case "error":
                continuation.yield(.failed(Self.failureMessage(from: event)))

            default:
                break
            }
        }

        let tail = utf8.flush()
        if !tail.isEmpty { continuation.yield(.text(tail)) }
    }

    /// `data: {...}` → `{...}`, or nil for comments, blank lines and other SSE fields.
    public static func dataPayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        return payload.isEmpty ? nil : payload
    }

    /// The JSON body for a request.
    ///
    /// Public so the shape actually put on the wire can be asserted in tests: whether the
    /// local-only parameters are included is exactly the kind of detail that silently
    /// breaks against a stricter server.
    /// The `input` field: a plain string, or content blocks when an image is attached.
    ///
    /// Images cannot travel in a string, so the whole input has to change shape — a message
    /// array whose user turn carries `input_text` and `input_image` parts. Sent as a data URL
    /// so there is no second request and no file the server has to be able to reach.
    static func encodeInput(_ text: String, images: [ImageAttachment]) -> Any {
        guard !images.isEmpty else { return text }
        var content: [[String: Any]] = [
            ["type": "input_text", "text": text]
        ]
        for image in images {
            content.append(["type": "input_image", "image_url": image.dataURL])
        }
        return [["role": "user", "content": content]]
    }

    public func body(for request: Request) -> [String: Any] {
        var body: [String: Any] = [
            "model": endpoint.model,
            "input": Self.encodeInput(request.input, images: request.images),
            "stream": true,
        ]
        if let instructions = request.instructions, !instructions.isEmpty {
            body["instructions"] = instructions
        }
        if let temperature = request.temperature { body["temperature"] = temperature }
        if let topP = request.topP { body["top_p"] = topP }
        // Extensions: harmless where understood, a 400 on OpenAI proper.
        if endpoint.compatibility == .extended {
            if let topK = request.topK, topK > 0 { body["top_k"] = topK }
            if let minP = request.minP { body["min_p"] = minP }
        }
        // The Responses API uses OpenAI's sign convention for the presence penalty: a
        // positive value discourages repetition. The seat stores MLX's signed value, so it
        // is negated here — the mirror image of what MLXEngine does.
        if let presencePenalty = request.presencePenalty { body["presence_penalty"] = -presencePenalty }
        if endpoint.compatibility == .extended, let repetitionPenalty = request.repetitionPenalty {
            body["repetition_penalty"] = repetitionPenalty
        }
        if let maxOutputTokens = request.maxOutputTokens {
            body["max_output_tokens"] = maxOutputTokens
        }
        // The effort is sent whenever it is known, *independently* of whether the reasoning
        // text is wanted back. These are two different things, and conflating them was a
        // real bug: with thinking off the effort was omitted entirely, so the server fell
        // back to its own default — which on a reasoning model means it reasoned anyway,
        // spent the whole output ceiling doing so, and returned nothing. Measured against
        // DeepSeek: identical requests, three runs, two of them empty.
        if let effort = request.reasoningEffort {
            body["reasoning"] = ["effort": effort]
        }
        if request.includeReasoning {
            body["include"] = ["reasoning.encrypted_content"]
        }
        return body
    }

    public static func usage(from event: [String: Any]) -> OpenAIUsage {
        let response = event["response"] as? [String: Any] ?? event
        let usage = response["usage"] as? [String: Any] ?? [:]
        let inputDetails = usage["input_tokens_details"] as? [String: Any] ?? [:]
        let outputDetails = usage["output_tokens_details"] as? [String: Any] ?? [:]
        return OpenAIUsage(
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            reasoningTokens: outputDetails["reasoning_tokens"] as? Int ?? 0,
            cachedTokens: inputDetails["cached_tokens"] as? Int ?? 0
        )
    }

    public static func failureMessage(from event: [String: Any]) -> String {
        let response = event["response"] as? [String: Any] ?? event
        if let error = response["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return message
        }
        if let message = event["message"] as? String { return message }
        if let reason = response["incomplete_details"] as? [String: Any],
            let why = reason["reason"] as? String
        {
            return "incomplete: \(why)"
        }
        return "the server reported a failure without a message"
    }
}
