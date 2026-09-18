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

/// The client's session, held by the one thing here that can clean up after itself.
///
/// `URLSession` is not released when the last reference to it goes. It stays alive — with its delegate
/// and its connection pool — until it is invalidated, which was measured while this finding was fixed:
/// a session dropped without invalidating is still alive afterwards, and the same session invalidated

public struct OpenAIResponsesClient: Sendable {
    private let endpoint: OpenAIEndpoint
    /// The session this client owns. Internal, not private, because the lifetime test holds a weak
    /// reference to it — the only way to observe that a released client closes it.
    let responseSession: ResponseSession

    public init(endpoint: OpenAIEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3_600
        configuration.httpAdditionalHeaders = ["User-Agent": "ChatBots/1.0 (macOS)"]
        // No redirects. The endpoint is validated before the request (`endpointRefusal`), and following
        // a redirect is how a URL that passed that check reaches a host that never did — a cloud
        // endpoint answering 302 to a metadata address, with the body echoed into the snapshot.
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
    /// telling apart in a UI: "not a usable base URL" is what a typo produces.
    /// How much of a traced request body is printed.
    ///
    /// Enough to see the shape of a prompt and where a field went wrong; not enough to spill a whole
    /// conversation into a log, which is what it did with no cap at all.
    static let traceLimit = 2_000

    /// Whether `CHATBOTS_TRACE_API` was set to something that means "on".
    ///
    /// The test was `!= nil`, so `CHATBOTS_TRACE_API=0` turned the trace *on* — not what anyone
    /// writing that means, and the switch prints the conversation.
    static func traceIsOn(_ value: String?) -> Bool {
        guard let value else { return false }
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // `off`, `disabled` and `none` were outside this list, so `CHATBOTS_TRACE_API=off` —
        // the most natural way to write "do not print the conversation" — turned the trace
        // **on**. An operator who writes `off` must get off.
        let off: Set<String> = ["0", "false", "no", "off", "disabled", "none"]
        return !(lowered.isEmpty || off.contains(lowered))
    }

    /// The URL with userinfo, query and fragment removed, for the trace line.
    ///
    /// `absoluteString` reproduced a credential a user had embedded in the base URL
    /// (`https://user:sk-…@host`) or passed as a query parameter, while `SECURITY.md` says the
    /// trace does not print the API key. The trace only needs the destination.
    static func traceSafeURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? "\(url.scheme ?? "?")://\(url.host ?? "?")\(url.path)"
    }

    /// The largest SSE line this client will buffer.
    ///
    /// `AsyncBytes.lines` buffers a whole line before yielding it, so a hostile or broken
    /// endpoint sending one enormous line (with no newline) grew this client's memory without
    /// limit — the 600-character cap on the error body was applied only after the line was
    /// already in memory. One megabyte is far past any real event: a delta is a few characters.
    static let maximumEventLineBytes = 1_048_576

    /// The most of a non-2xx body this client reads before reporting the status.
    static let maximumErrorBodyBytes = 4_096

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

    /// The body of the endpoint's `/v1/models` listing.
    ///
    /// Through `modelsURL`, which applies `endpointRefusal`, and through this client's own
    /// session, which refuses redirects — the same two controls the generation path uses. The
    /// engine's reachability probe used to build its own URL and call `URLSession.shared`, so
    /// a `file://` or link-local base URL was fetched and a 302 was followed with the API key
    /// attached, and up to 300 bytes of the response were echoed into the snapshot the LAN
    /// front ends display.
    public func modelsBody() async throws -> Data {
        guard let url = endpoint.modelsURL else {
            if let parsed = URL(string: endpoint.baseURL),
                let reason = OpenAIEndpoint.endpointRefusal(parsed)
            {
                throw OpenAIResponsesError.refusedEndpoint(endpoint.baseURL, reason: reason)
            }
            throw OpenAIResponsesError.badURL(endpoint.baseURL)
        }
        var request = URLRequest(url: url)
        if let key = endpoint.effectiveAPIKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await responseSession.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OpenAIResponsesError.http(
                status: status,
                body: UTF8Text.decodeTruncated(UTF8Text.bytePrefix(data, 300)) ?? "")
        }
        return data
    }

    /// Write the request to standard error, when the trace switch is on.
    ///
    /// Its own function because `run` is at its `function_body_length` budget, and because this is the
    /// one place that writes the conversation somewhere other than the chosen endpoint, so it should
    /// be reviewable on its own.
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
        let header = "[trace] POST \(Self.traceSafeURL(url)) (\(encoded.count) bytes\(omitted))\n"
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
            // The body carries the server's explanation; read a little of it, by bytes rather
            // than by lines: `bytes.lines` buffers a whole line first, so one enormous line
            // would be in memory before the cap could stop it.
            var detailBytes = Data()
            for try await byte in bytes {
                detailBytes.append(byte)
                if detailBytes.count >= Self.maximumErrorBodyBytes { break }
            }
            let detail = String(bytes: detailBytes, encoding: .utf8) ?? ""
            throw OpenAIResponsesError.http(status: http.statusCode, body: detail)
        }

        try await readEventStream(bytes, into: continuation)
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
    /// rather than spilling base64 into a log: the images travel inline in `input` as data URLs.
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
