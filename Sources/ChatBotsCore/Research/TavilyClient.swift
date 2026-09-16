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
    private let session: URLSession

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
        self.session = URLSession(configuration: configuration)
    }

    /// Whether a key is available. False on a fresh clone, which has no `.secrets.env`.
    public static var isConfigured: Bool { configuredKey != nil }

    // MARK: - Search

    public func search(
        query: String,
        maxResults: Int = 5,
        depth: Depth = .basic,
        includeAnswer: Bool = false
    ) async throws -> [SearchHit] {
        struct Request: Encodable {
            let query: String
            let search_depth: String
            let max_results: Int
            let include_answer: Bool
            let include_raw_content: Bool
        }
        struct Response: Decodable {
            struct Item: Decodable {
                let title: String?
                let url: String?
                let content: String?
                let raw_content: String?
                let score: Double?
            }
            let results: [Item]?
            let answer: String?
        }

        let mapped =
            try await post(
                path: "/search",
                body: Request(
                    query: query,
                    search_depth: depth.rawValue,
                    max_results: max(1, min(maxResults, 10)),
                    include_answer: includeAnswer,
                    include_raw_content: false
                ),
                as: Response.self
            ).results?.map {
                SearchHit(
                    title: $0.title ?? "(untitled)",
                    url: $0.url ?? "",
                    content: $0.content ?? $0.raw_content ?? "",
                    score: $0.score
                )
            } ?? []

        switch Self.outcome(for: mapped, depth: depth) {
        case .hits(let hits):
            return hits
        case .retryAdvanced:
            // The retry keeps the caller's `includeAnswer`. The recursive call used to drop it,
            // so a caller that asked for Tavily's own answer lost it on exactly the path the
            // retry exists for. No caller passes `true` today, which is why it went unnoticed.
            return try await search(
                query: query, maxResults: maxResults, depth: .advanced,
                includeAnswer: includeAnswer)
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
        struct Request: Encodable {
            let urls: [String]
            let extract_depth: String
        }
        struct Response: Decodable {
            struct Item: Decodable {
                let url: String?
                let title: String?
                let raw_content: String?
            }
            struct Failure: Decodable {
                let url: String?
                let error: String?
            }
            let results: [Item]?
            let failed_results: [Failure]?
        }

        let response = try await post(
            path: "/extract",
            body: Request(urls: urls, extract_depth: "basic"),
            as: Response.self
        )

        if let failures = response.failed_results, !failures.isEmpty,
            (response.results ?? []).isEmpty
        {
            let detail = failures.compactMap { $0.error }.joined(separator: "; ")
            throw ChatBotsError.toolFailed(detail.isEmpty ? "extract returned no content" : detail)
        }

        return (response.results ?? []).map { item in
            let raw = item.raw_content ?? ""
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

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChatBotsError.toolFailed("network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw ChatBotsError.toolFailed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Cut bytes safely: a raw `data.prefix` can split a multi-byte character.
            let snippet = UTF8Text.decodeTruncated(UTF8Text.bytePrefix(data, 400)) ?? ""
            throw ChatBotsError.toolFailed("HTTP \(http.statusCode) \(snippet)")
        }

        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw ChatBotsError.toolFailed("unreadable Tavily response: \(error.localizedDescription)")
        }
    }
}
