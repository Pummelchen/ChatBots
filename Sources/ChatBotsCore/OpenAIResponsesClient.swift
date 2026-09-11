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
            "Server returned HTTP \(status): \(body.prefix(300))"
        case .streamFailed(let message):
            "The response failed: \(message)"
        case .noOutput:
            "The server completed the response without producing any text."
        case .cancelled:
            "Cancelled."
        }
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

    public init(
        baseURL: String = "http://localhost:1234",
        model: String = "mlx-community/Qwen3.5-4B-MLX-4bit",
        apiKey: String? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
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
    public var shortModelName: String {
        let last = model.split(separator: "/").last.map(String.init) ?? model
        return last.replacingOccurrences(of: "-MLX-4bit", with: "")
            .replacingOccurrences(of: "-4bit", with: "")
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
            reasoningEffort: String? = nil
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
        if let key = endpoint.apiKey, !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: body(for: request), options: [])

        let (bytes, response) = try await session.bytes(for: urlRequest)

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
                    sawText = true
                    continuation.yield(.text(delta))
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
    }

    /// `data: {...}` → `{...}`, or nil for comments, blank lines and other SSE fields.
    static func dataPayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        return payload.isEmpty ? nil : payload
    }

    private func body(for request: Request) -> [String: Any] {
        var body: [String: Any] = [
            "model": endpoint.model,
            "input": request.input,
            "stream": true,
        ]
        if let instructions = request.instructions, !instructions.isEmpty {
            body["instructions"] = instructions
        }
        if let temperature = request.temperature { body["temperature"] = temperature }
        if let topP = request.topP { body["top_p"] = topP }
        if let topK = request.topK, topK > 0 { body["top_k"] = topK }
        if let minP = request.minP { body["min_p"] = minP }
        // The Responses API uses OpenAI's sign convention for the presence penalty: a
        // positive value discourages repetition. The seat stores MLX's signed value, so it
        // is negated here — the mirror image of what MLXEngine does.
        if let presencePenalty = request.presencePenalty { body["presence_penalty"] = -presencePenalty }
        if let repetitionPenalty = request.repetitionPenalty { body["repetition_penalty"] = repetitionPenalty }
        if let maxOutputTokens = request.maxOutputTokens {
            body["max_output_tokens"] = maxOutputTokens
        }
        if request.includeReasoning {
            body["include"] = ["reasoning.encrypted_content"]
            if let effort = request.reasoningEffort {
                body["reasoning"] = ["effort": effort]
            }
        }
        return body
    }

    static func usage(from event: [String: Any]) -> OpenAIUsage {
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

    static func failureMessage(from event: [String: Any]) -> String {
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
