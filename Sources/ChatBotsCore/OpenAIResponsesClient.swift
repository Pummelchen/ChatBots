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
    /// An endpoint this client will not send to, and the rule that refused it.
    case refusedEndpoint(String, reason: String)
    case http(status: Int, body: String)
    case streamFailed(String)
    case noOutput
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .badURL(let value):
            "Not a usable base URL: \(value)"
        case .refusedEndpoint(let value, let reason):
            "The endpoint \(value) is not used: \(reason)."
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

    /// The compact label a seat shows for an MLX checkpoint.
    ///
    /// Derived from the identifier rather than stored beside it: `AgentSpec.seat(index:modelID:)` set
    /// `modelShortName` to the *default* checkpoint's name whatever it was asked for, so
    /// `chatbots-cli --model-a <another checkpoint>` told every seat's prompt — "running
    /// Qwen3.5-4B-4bit on the moderator's Mac" — and every badge that it was running the default
    /// (A200). The `-MLX` marker comes out because it names the runtime rather than the model, and the
    /// engine here is always MLX; that leaves the default checkpoint reading exactly as it did.
    public static func shortName(_ modelID: String) -> String {
        let slug = modelID.split(separator: "/").last.map(String.init) ?? modelID
        let trimmed = slug.replacingOccurrences(of: "-MLX", with: "")
        return trimmed.isEmpty ? slug : trimmed
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
        normalisedKey(ProcessInfo.processInfo.environment[deepSeekEnvironmentKey])
            ?? normalisedKey(secretsFile()[deepSeekEnvironmentKey])
    }

    /// A key value as it should be used, or nil when there is not really one.
    ///
    /// **One function for every key path**, because they did disagree: this file trimmed
    /// `.whitespaces`, which excludes `\r`, while `TavilyClient` trimmed
    /// `.whitespacesAndNewlines`. A CRLF `.secrets.env` therefore gave the DeepSeek path a key
    /// ending in a carriage return — non-empty, so `isMissingKey` stayed false and no warning
    /// was shown, while the Authorization header carried a control character and the 401 that
    /// came back read as "the key is wrong" rather than "there is no usable key". Both resolvers
    /// now normalise through here, so the difference cannot come back one caller at a time.
    /// Blank is absent rather than an empty key: an exported-but-empty variable otherwise means
    /// sending `Bearer ` to the API.
    public static func normalisedKey(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Parse `.secrets.env`, one `NAME=value` per line.
    ///
    /// Deliberately minimal: no expansion, no quoting rules, no includes. It holds one or two
    /// keys and a parser with features is a parser with surprises.
    ///
    /// Line endings are normalised before the split, and that is not cosmetic. `split(separator:
    /// "\n")` does **not** split a CRLF file: Swift's `Character` is an extended grapheme
    /// cluster and `CR LF` is one cluster, so no character equals `"\n"` and the whole file
    /// arrives as a single "line" (measured). A CRLF file therefore used to parse as one entry
    /// whose value was the remainder of the file — so with the two keys this file documents,
    /// neither key was usable and neither was reported missing. Lines are then trimmed with
    /// `.whitespacesAndNewlines`, so a lone `\r` cannot ride inside a key either (audit A55).
    public static func secretsFile(in root: URL? = nil) -> [String: String] {
        let directory = root ?? ModelStore.projectRoot() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = directory.appending(path: secretsFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var values: [String: String] = [:]
        for line in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[trimmed.startIndex..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
    ///
    /// Trimmed with `.whitespacesAndNewlines`, not `.whitespaces`: `responsesURL` already
    /// strips line endings, so a base URL ending in `\n` was requestable but this check read
    /// its host as nil and refused to attach the built-in key — two halves of the same
    /// endpoint disagreeing about the same string (A106, the shape A55 fixed for keys).
    static func host(of baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
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
        model: String = AgentSpec.defaultModelID,
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
            // The default checkpoint, not a copy of its name (A208). Older saved settings predate the
            // field, and this is what they meant.
            ?? AgentSpec.defaultModelID
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
    ///
    /// The typed value goes through `BuiltInKeys.normalisedKey`, the same function the file
    /// and environment paths use. It is the third caller the A55 fix named, and it had the
    /// same defect: a pasted key with a trailing newline was taken verbatim, so it carried a
    /// control character into the Authorization header while being non-empty, which kept
    /// `isMissingKey` false and suppressed the warning that should have said there was no
    /// usable key. A value that is only whitespace now reads as absent rather than as an
    /// empty bearer token (audit A106).
    public var effectiveAPIKey: String? {
        if let typed = BuiltInKeys.normalisedKey(apiKey) { return typed }
        return BuiltInKeys.key(forBaseURL: baseURL)
    }

    public var isMissingKey: Bool {
        compatibility == .strict && (effectiveAPIKey ?? "").isEmpty
    }

    /// The full endpoint, tolerating a base URL given with or without a trailing slash or
    /// with `/v1` already present.
    ///
    /// Nil when the endpoint is one this client will not send to, which is `endpointRefusal`'s
    /// decision rather than a parsing accident.
    public var responsesURL: URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        let path = trimmed.hasSuffix("/v1") ? "/responses" : "/v1/responses"
        guard let url = URL(string: trimmed + path) else { return nil }
        guard Self.endpointRefusal(url) == nil else { return nil }
        return url
    }

    /// Why this client will not send a request to `url`, or nil when it will.
    ///
    /// Two rules, both about an address that arrives from configuration a user — or, before A136, any
    /// web page — could set. It has to be http or https: a `file://` base URL made a model request
    /// read the local disk. And it must not be link-local, where cloud metadata services live, since
    /// `http://169.254.169.254/…` is the classic way a request path like this hands out credentials,
    /// and a non-2xx body is echoed back into the snapshot the front ends display.
    ///
    /// Loopback and private addresses stay allowed on purpose — pointing a seat at LM Studio or Ollama
    /// on this Mac or on the LAN is the thing this app is for, so refusing them would break the
    /// product to close a hole it does not have. A name that resolves to a link-local address is not
    /// covered by a string check like this one; the redirect policy on the session is what keeps a
    /// validated endpoint from being re-pointed behind the check (A141).
    static func endpointRefusal(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "only http and https endpoints are used"
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return "the endpoint has no host"
        }
        if host.hasPrefix("169.254.") || host.hasPrefix("fe80:") || host.hasPrefix("[fe80:") {
            return "it is link-local, which is where cloud metadata services answer"
        }
        return nil
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

/// A session delegate whose only job is to refuse redirects.
///
/// `completionHandler(nil)` means "do not follow": the redirect response is the answer, so a 302 from
/// an endpoint shows up as a non-2xx rather than as a request to wherever it pointed.
///
/// Stateless, and `Sendable` because of it — `URLSession` keeps it for the session's lifetime and the
/// client is sent between tasks.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// The client's session, held by the one thing here that can clean up after itself.
///
/// `URLSession` is not released when the last reference to it goes. It stays alive — with its delegate
/// and its connection pool — until it is invalidated, which was measured while this finding was fixed:
/// a session dropped without invalidating is still alive afterwards, and the same session invalidated
/// first is not. A struct cannot do anything when it is deallocated, so the session lives in a class
/// whose `deinit` is the invalidate.
final class ResponseSession: Sendable {
    let session: URLSession

    init(configuration: URLSessionConfiguration, delegate: URLSessionDelegate) {
        self.session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        // `finishTasksAndInvalidate` rather than `invalidateAndCancel`: a session released after a turn
        // has already finished has nothing in flight to cancel, and cancelling is for the caller that is
        // deliberately giving up on a request it started.
        session.finishTasksAndInvalidate()
    }
}

public struct OpenAIResponsesClient: Sendable {
    private let endpoint: OpenAIEndpoint
    /// The session this client owns. Internal, not private, because the lifetime test holds a weak
    /// reference to it — the only way to observe that a released client closes it (A201).
    let responseSession: ResponseSession

    public init(endpoint: OpenAIEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3_600
        configuration.httpAdditionalHeaders = ["User-Agent": "ChatBots/1.0 (macOS)"]
        // No redirects. The endpoint is validated before the request (`endpointRefusal`), and following
        // a redirect is how a URL that passed that check reaches a host that never did — a cloud
        // endpoint answering 302 to a metadata address, with the body echoed into the snapshot (A141).
        self.responseSession = ResponseSession(
            configuration: configuration, delegate: NoRedirects())
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


    /// The endpoint's URL, or the error that says why there is not one.
    ///
    /// Its own function because `run` is at its `function_body_length` budget, and because the two
    /// reasons a base URL is unusable — it does not parse, or it parses and is refused — are worth
    /// telling apart in a UI: "not a usable base URL" is what a typo produces (A141).
    /// How much of a traced request body is printed.
    ///
    /// Enough to see the shape of a prompt and where a field went wrong; not enough to spill a whole
    /// conversation into a log, which is what it did with no cap at all (A140).
    static let traceLimit = 2_000

    /// Whether `CHATBOTS_TRACE_API` was set to something that means "on".
    ///
    /// The test was `!= nil`, so `CHATBOTS_TRACE_API=0` turned the trace *on* — not what anyone
    /// writing that means, and the switch prints the conversation (A140).
    static func traceIsOn(_ value: String?) -> Bool {
        guard let value else { return false }
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !(lowered.isEmpty || lowered == "0" || lowered == "false" || lowered == "no")
    }

    private func endpointURL() throws -> URL {
        guard let url = endpoint.responsesURL else {
            if let parsed = URL(string: endpoint.baseURL),
                let reason = OpenAIEndpoint.endpointRefusal(parsed)
            {
                throw OpenAIResponsesError.refusedEndpoint(endpoint.baseURL, reason: reason)
            }
            throw OpenAIResponsesError.badURL(endpoint.baseURL)
        }
        return url
    }

    /// Write the request to standard error, when the trace switch is on.
    ///
    /// Its own function because `run` is at its `function_body_length` budget, and because this is the
    /// one place that writes the conversation somewhere other than the chosen endpoint, so it should
    /// be reviewable on its own (A140).
    ///
    /// Bounded, and with the images left out rather than cut off mid-base64: a request body is the
    /// whole conversation plus every attached image, and standard error is a terminal, a launchd log or
    /// a container log — `SECURITY.md` says the conversation leaves the machine only to the chosen
    /// endpoint. What is printed is still the request's own shape, so it remains useful for the
    /// protocol debugging it exists for.
    private func traceRequest(_ url: URL, _ request: Request) {
        let omitted = request.images.isEmpty ? "" : ", \(request.images.count) image payload(s) omitted"
        let payload = body(for: request, images: [])
        let encoded =
            (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let text = String(data: encoded, encoding: .utf8) ?? "?"
        let preview = UTF8Text.prefix(text, Self.traceLimit)
        let header = "[trace] POST \(url.absoluteString) (\(encoded.count) bytes\(omitted))\n"
        FileHandle.standardError.write(Data(header.utf8))
        FileHandle.standardError.write(Data("[trace] \(preview)\n".utf8))
    }

    private func run(
        _ request: Request,
        into continuation: AsyncThrowingStream<OpenAIStreamEvent, Error>.Continuation
    ) async throws {
        let url = try endpointURL()

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = endpoint.effectiveAPIKey, !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if Self.traceIsOn(ProcessInfo.processInfo.environment["CHATBOTS_TRACE_API"]) {
            traceRequest(url, request)
        }
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: body(for: request), options: [])

        let (bytes, response) = try await responseSession.session.bytes(for: urlRequest)
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

        // A completed response is the only thing that counts as success (see the header). The
        // loop can end at EOF or at `data: [DONE]`, and either can happen mid-stream when a
        // connection drops, a proxy truncates, or a server is killed — so "the bytes stopped"
        // is not evidence that the turn finished. `sawCompleted` is what separates the two.
        var sawCompleted = false
        // An explicit failure is already the answer; it is reported as `.failed` and the caller
        // turns it into the thrown error. It must not also produce the truncation error below,
        // which would replace the server's own reason with a less useful one.
        var sawFailure = false
        var utf8 = UTF8StreamBuffer()
        // Labelled so a terminal event can end the read, not merely the `switch` it is decoded
        // in. A `break` inside a case only leaves the case.
        readLoop: for try await line in bytes.lines {
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
                sawCompleted = true
                continuation.yield(.completed(Self.usage(from: event)))

            case "response.failed", "response.incomplete":
                let message = Self.failureMessage(from: event)
                sawFailure = true
                continuation.yield(.failed(message))
                // The server has already given its answer, so the read ends here. Without this
                // the loop went back to `bytes.lines` for a connection a server may hold open,
                // and the turn stayed alive until the 600-second request timeout — ten minutes
                // of waiting for a failure that was reported at once. It is also what concludes
                // a stream that reports failure and then sends nothing: A54 made a missing
                // terminal event a failure the reader must act on rather than wait out (A107).
                break readLoop

            case "error":
                sawFailure = true
                continuation.yield(.failed(Self.failureMessage(from: event)))
                break readLoop

            default:
                break
            }
        }

        let tail = utf8.flush()
        if !tail.isEmpty { continuation.yield(.text(tail)) }

        // Truncated: the stream ended without the server ever saying it completed. Whatever
        // text arrived is a fragment, and reporting it as a finished turn would record a
        // `stop` with zero usage — the token statistics silently become 0, and a half answer is
        // indistinguishable from a whole one. Throwing is what makes the caller's normal
        // error handling report the turn as failed instead.
        if !sawCompleted, !sawFailure {
            throw OpenAIResponsesError.streamFailed(
                "the connection ended before the response completed, so the reply is incomplete")
        }
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

    /// The JSON body for a request.
    ///
    /// `images` is an override for the trace, which prints the body with the image payloads left out
    /// rather than spilling base64 into a log: the images travel inline in `input` as data URLs
    /// (A140).
    public func body(for request: Request, images: [ImageAttachment]? = nil) -> [String: Any] {
        var body: [String: Any] = [
            "model": endpoint.model,
            "input": Self.encodeInput(request.input, images: images ?? request.images),
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
