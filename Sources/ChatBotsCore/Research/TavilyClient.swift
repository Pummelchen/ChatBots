// ChatBotsCore — Tavily (https://api.tavily.com) search/extract client
//
// Both agents share one stateless client; the API is stateless too, so a single
// instance is enough and there is no per-agent rate-limit bookkeeping to do.

import Foundation

public struct TavilyClient: Sendable {

    /// The environment variable that supplies the key.
    public static let environmentKey = "TAVILY_API_KEY"

    /// The key, from the `TAVILY_API_KEY` environment variable or the gitignored
    /// `.secrets.env` at the project root.
    ///
    /// There is deliberately **no built-in default**. This repository is public, so a key
    /// written into the source is a key in every clone — and one was, which is why this has
    /// the shape it has now. `BuiltInKeys` already reads `.secrets.env` for the DeepSeek key,
    /// and this reuses that rather than growing a second mechanism.
    public static var configuredKey: String? {
        resolveKey(
            environment: ProcessInfo.processInfo.environment[environmentKey],
            secretsFile: BuiltInKeys.secretsFile())
    }

    /// The resolution itself, with both sources passed in.
    ///
    /// Separated from the environment so it can be tested without touching the process's
    /// variables or the developer's own `.secrets.env`: a test that reads the real file
    /// passes on the machine that wrote it and fails on a fresh clone.
    public static func resolveKey(environment: String?, secretsFile: [String: String]) -> String? {
        // Both sources are normalised through `BuiltInKeys.normalisedKey`, the same function the
        // DeepSeek path uses. The two paths used to trim differently — `.whitespaces` there,
        // `.whitespacesAndNewlines` here — so a CRLF `.secrets.env` produced a key with a
        // trailing carriage return on one path and a clean one on the other. One
        // normaliser is what stops that disagreement coming back.
        BuiltInKeys.normalisedKey(environment)
            ?? BuiltInKeys.normalisedKey(secretsFile[environmentKey])
    }

    public enum Depth: String, Sendable {
        case basic
        case advanced
    }

    public struct SearchHit: Sendable, Hashable {
        public var title: String
        public var url: String
        public var content: String
        public var score: Double?
    }

    public struct ExtractResult: Sendable, Hashable {
        public var url: String
        public var title: String
        public var content: String
    }

    private let apiKey: String
    private let baseURL: String
    /// Held in the same wrapper the OpenAI client uses, so the session is invalidated when the
    /// client is released and redirects are refused rather than followed with the key attached.
    private let session: ResponseSession

    public init(apiKey: String? = nil) {
        self.init(apiKey: apiKey, baseURL: "https://api.tavily.com")
    }

    /// The base URL is injectable so the search and retry logic can be tested against a local
    /// server instead of the live API. The public initialiser below always uses the real one,
    /// so this changes nothing about how the app reaches Tavily.
    init(apiKey: String?, baseURL: String) {
        self.apiKey = apiKey ?? Self.configuredKey ?? ""
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.httpAdditionalHeaders = ["User-Agent": "ChatBots/1.0 (macOS)"]
        // `NoRedirects`: this client used a bare `URLSession(configuration:)`, which follows a
        // 302 by default while the Authorization header is attached. The OpenAI client already
        // refused redirects for exactly that reason; the policy is shared now.
        self.session = ResponseSession(configuration: configuration, delegate: NoRedirects())
    }

    /// Whether a key is available. False on a fresh clone, which has no `.secrets.env`.
    public static var isConfigured: Bool { configuredKey != nil }

    // MARK: - Search

    /// The largest success body this client will read from Tavily.
    ///
    /// A search result is kilobytes and an extract is bounded by `maxCharactersPerPage` per page,
    /// so this is far past any honest response and still a bound on what an upstream can make this
    /// process allocate.
    static let maximumResponseBytes = 16 * 1024 * 1024

    public func search(
        query: String,
        maxResults: Int = 5,
        depth: Depth = .basic,
        includeAnswer: Bool = false
    ) async throws -> [SearchHit] {
        try await searchDetailed(
            query: query, maxResults: maxResults, depth: depth, includeAnswer: includeAnswer
        ).hits
    }

    /// The hits and how many billed upstream requests they cost.
    ///
    /// One request at `basic`. Two when the basic result was empty and the search retried at
    /// `advanced` — the research budget charges per call, so a `web_search` that retried used to
    /// cost two billed calls and be charged for one.
    public func searchDetailed(
        query: String,
        maxResults: Int = 5,
        depth: Depth = .basic,
        includeAnswer: Bool = false
    ) async throws -> (hits: [SearchHit], billedUnits: Int) {
        let response = try await post(
            path: "/search",
            body: TavilySearchRequest(
                query: query,
                searchDepth: depth.rawValue,
                maxResults: max(1, min(maxResults, 10)),
                includeAnswer: includeAnswer,
                includeRawContent: false
            ),
            as: TavilySearchResponse.self
        )
        var hits =
            response.results?.map {
                SearchHit(
                    title: $0.title ?? "(untitled)",
                    url: $0.url ?? "",
                    content: $0.content ?? $0.rawContent ?? "",
                    score: $0.score
                )
            } ?? []
        // `include_answer` asked Tavily for its own summary and then threw it away: the field was
        // decoded and never read, so the flag was a no-op and the retry's own comment about
        // keeping it was false. It is now the first hit, which is where a model reading the list
        // will see it.
        if includeAnswer, let answer = response.answer,
            !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            hits.insert(
                SearchHit(title: "Tavily answer", url: "", content: answer, score: nil), at: 0)
        }

        switch Self.outcome(for: hits, depth: depth) {
        case .hits(let usable):
            return (usable, 1)
        case .retryAdvanced:
            // The retry keeps the caller's `includeAnswer`. The recursive call used to drop it,
            // so a caller that asked for Tavily's own answer lost it on exactly the path the
            // retry exists for.
            let retried = try await searchDetailed(
                query: query, maxResults: maxResults, depth: .advanced,
                includeAnswer: includeAnswer)
            return (retried.hits, retried.billedUnits + 1)
        }
    }

    /// What a mapped search response means.
    ///
    /// The *ordering* here is the fix, which is why this is one function rather than two steps
    /// inside `search`: the blank-hit filter has to run before the retry is decided. It used to
    /// run after, so a response of three blank items mapped to a non-empty array, skipped the
    /// advanced-depth retry, and was then stripped to `[]` — and `WebSearchTool` reported "No
    /// results" for exactly the case the retry exists for. Separated from the
    /// network call so the rule can be tested directly as well as end to end.
    enum SearchOutcome: Equatable {
        /// Hits worth giving the model.
        case hits([SearchHit])
        /// Nothing usable at basic depth: try once more at `advanced`.
        case retryAdvanced
    }

    static func outcome(for hits: [SearchHit], depth: Depth) -> SearchOutcome {
        let usable = hits.filter { !($0.content.isEmpty && $0.title == "(untitled)") }
        if usable.isEmpty, depth == .basic { return .retryAdvanced }
        return .hits(usable)
    }

    // MARK: - Extract

    public func extract(urls: [String], maxCharactersPerPage: Int = 6_000) async throws -> [ExtractResult] {
        let response = try await post(
            path: "/extract",
            body: TavilyExtractRequest(urls: urls, extractDepth: "basic"),
            as: TavilyExtractResponse.self
        )

        if let failures = response.failedResults, !failures.isEmpty,
            (response.results ?? []).isEmpty
        {
            let detail = failures.compactMap { $0.error }.joined(separator: "; ")
            throw ChatBotsError.toolFailed(detail.isEmpty ? "extract returned no content" : detail)
        }

        return (response.results ?? []).map { item in
            let raw = item.rawContent ?? ""
            let clipped =
                raw.count > maxCharactersPerPage
                ? String(raw.prefix(maxCharactersPerPage)) + "\n…[truncated]"
                : raw
            return ExtractResult(
                url: item.url ?? urls.first ?? "",
                title: item.title ?? "",
                content: clipped
            )
        }
    }

    // MARK: - Transport

    private func post<Body: Encodable, Result: Decodable>(
        path: String,
        body: Body,
        as: Result.Type
    ) async throws -> Result {
        // Refused here rather than sent: an empty bearer token comes back as a 401, which
        // reads as "the key is wrong" when the truth is that there is no key at all.
        guard !apiKey.isEmpty else {
            throw ChatBotsError.toolFailed(
                "no Tavily key is configured — set \(Self.environmentKey) or add it to "
                    + BuiltInKeys.secretsFileName)
        }
        guard let url = URL(string: baseURL + path) else {
            throw ChatBotsError.toolFailed("bad Tavily URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        // The body is bounded while it arrives. `data(for:)` buffered whatever the peer sent, so a
        // hostile or compromised upstream could force an allocation of any size before a single
        // check ran; neither the results array nor the field lengths are bounded either, so the cap
        // is on the bytes rather than on a count that a long string can sidestep. A non-2xx only
        // needs a snippet for the message, so it stops at the snippet's length.
        var received = Data()
        let http: HTTPURLResponse
        do {
            let (bytes, response) = try await session.session.bytes(for: request)
            guard let typed = response as? HTTPURLResponse else {
                throw ChatBotsError.toolFailed("no HTTP response")
            }
            http = typed
            let isSuccess = (200..<300).contains(typed.statusCode)
            let limit = isSuccess ? Self.maximumResponseBytes : 400
            for try await byte in bytes {
                if received.count >= limit {
                    if isSuccess {
                        throw ChatBotsError.toolFailed(
                            "the Tavily response was larger than \(limit) bytes")
                    }
                    break
                }
                received.append(byte)
            }
        } catch let error as ChatBotsError {
            throw error
        } catch {
            throw ChatBotsError.toolFailed("network error: \(error.localizedDescription)")
        }

        guard (200..<300).contains(http.statusCode) else {
            // Cut bytes safely: a raw `data.prefix` can split a multi-byte character.
            let snippet = UTF8Text.decodeTruncated(UTF8Text.bytePrefix(received, 400)) ?? ""
            throw ChatBotsError.toolFailed("HTTP \(http.statusCode) \(snippet)")
        }

        do {
            return try JSONDecoder().decode(Result.self, from: received)
        } catch {
            throw ChatBotsError.toolFailed("unreadable Tavily response: \(error.localizedDescription)")
        }
    }
}

// MARK: - The wire types

// At file scope rather than inside the two functions: `CodingKeys` is what maps Tavily's
// snake_case field names onto Swift's, and a type nested that far trips the `nesting` rule.

private struct TavilySearchRequest: Encodable {
    let query: String
    let searchDepth: String
    let maxResults: Int
    let includeAnswer: Bool
    let includeRawContent: Bool

    enum CodingKeys: String, CodingKey {
        case query
        case searchDepth = "search_depth"
        case maxResults = "max_results"
        case includeAnswer = "include_answer"
        case includeRawContent = "include_raw_content"
    }
}

private struct TavilySearchItem: Decodable {
    let title: String?
    let url: String?
    let content: String?
    let rawContent: String?
    let score: Double?

    enum CodingKeys: String, CodingKey {
        case title, url, content, score
        case rawContent = "raw_content"
    }
}

private struct TavilySearchResponse: Decodable {
    let results: [TavilySearchItem]?
    let answer: String?
}

private struct TavilyExtractRequest: Encodable {
    let urls: [String]
    let extractDepth: String

    enum CodingKeys: String, CodingKey {
        case urls
        case extractDepth = "extract_depth"
    }
}

private struct TavilyExtractItem: Decodable {
    let url: String?
    let title: String?
    let rawContent: String?

    enum CodingKeys: String, CodingKey {
        case url, title
        case rawContent = "raw_content"
    }
}

private struct TavilyExtractFailure: Decodable {
    let url: String?
    let error: String?
}

private struct TavilyExtractResponse: Decodable {
    let results: [TavilyExtractItem]?
    let failedResults: [TavilyExtractFailure]?

    enum CodingKeys: String, CodingKey {
        case results
        case failedResults = "failed_results"
    }
}
