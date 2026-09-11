// ChatBotsCore — Tavily (https://api.tavily.com) search/extract client
//
// Both agents share one stateless client; the API is stateless too, so a single
// instance is enough and there is no per-agent rate-limit bookkeeping to do.

import Foundation

public struct TavilyClient: Sendable {

    /// The project's dev key. Override with `TAVILY_API_KEY` in the environment.
    public static let defaultAPIKey = "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"

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
    private let session: URLSession

    public init(apiKey: String? = nil) {
        self.apiKey =
            apiKey
            ?? ProcessInfo.processInfo.environment["TAVILY_API_KEY"]
            ?? Self.defaultAPIKey

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.httpAdditionalHeaders = ["User-Agent": "ChatBots/1.0 (macOS)"]
        self.session = URLSession(configuration: configuration)
    }

    public static var isConfigured: Bool {
        !(ProcessInfo.processInfo.environment["TAVILY_API_KEY"] ?? defaultAPIKey).isEmpty
    }

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

        var hits = try await post(
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

        // Empty-result responses do happen for very odd phrasing; retry once with the
        // advanced depth rather than burning one of the model's turns on a blank.
        if hits.isEmpty, depth == .basic {
            return try await search(query: query, maxResults: maxResults, depth: .advanced)
        }
        hits.removeAll { $0.content.isEmpty && $0.title == "(untitled)" }
        return hits
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
        guard let url = URL(string: "https://api.tavily.com" + path) else {
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
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw ChatBotsError.toolFailed("HTTP \(http.statusCode) \(snippet)")
        }

        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw ChatBotsError.toolFailed("unreadable Tavily response: \(error.localizedDescription)")
        }
    }
}
