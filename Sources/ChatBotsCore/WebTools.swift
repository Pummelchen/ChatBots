// ChatBotsCore — the two web tools exposed to the models
//
// These are handed to MLX Swift as native tool specs, so Qwen 3.5 emits real
// `<tool_call>` blocks and the session dispatches them for us. Results come back as
// role:"tool" messages, which is why the model can cite what it found.

import Foundation

/// `web_search` — Tavily search, formatted as a compact numbered list.
public struct WebSearchTool: ToolProvider {
    public let client: TavilyClient
    public let maxResults: Int

    public init(client: TavilyClient = TavilyClient(), maxResults: Int = 5) {
        self.client = client
        self.maxResults = maxResults
    }

    public var name: String { "web_search" }
    public var description: String {
        "Search the live web. Use it to check facts, find sources, or look up anything "
            + "you are unsure about. Returns titles, URLs and snippets."
    }
    public var argumentName: String { "query" }
    public var argumentDescription: String { "The search query, in natural language." }

    public func run(argument: String) async throws -> ToolOutcome {
        let query = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ChatBotsError.toolFailed("empty search query")
        }

        let hits = try await client.search(query: query, maxResults: maxResults)
        guard !hits.isEmpty else {
            return ToolOutcome(
                text: "No results for \"\(query)\".",
                summary: "no results for \"\(query)\""
            )
        }

        let body = hits.enumerated().map { index, hit -> String in
            """
            \(index + 1). \(hit.title)
               URL: \(hit.url)
               \(hit.content)
            """
        }.joined(separator: "\n\n")

        return ToolOutcome(
            text: """
            Search results for "\(query)":

            \(body)

            Cite the URLs you rely on. If these results do not settle the point, search again \
            with different wording instead of guessing.
            """,
            summary: "\(hits.count) result(s) for \"\(query)\" — \(hits.first?.title ?? "")"
        )
    }
}

/// `fetch_page` — Tavily extract, for when a snippet is not enough.
public struct FetchPageTool: ToolProvider {
    public let client: TavilyClient
    public let maxCharacters: Int

    public init(client: TavilyClient = TavilyClient(), maxCharacters: Int = 6_000) {
        self.client = client
        self.maxCharacters = maxCharacters
    }

    public var name: String { "fetch_page" }
    public var description: String {
        "Fetch and read the full text of a web page by URL. Use it when a search snippet "
            + "is too short to answer the question. One URL per call."
    }
    public var argumentName: String { "url" }
    public var argumentDescription: String { "Absolute URL of the page to read, e.g. https://example.com/article" }

    /// The schemes `fetch_page` will fetch.
    ///
    /// Exactly these two, compared without regard to case. The guard here was
    /// `url.scheme?.hasPrefix("http")`, which accepted `httpx:` and `httpfoo:` — schemes this tool does not
    /// claim, handed to the extractor because they began with the right four letters — and it *refused*
    /// `HTTP://` and `Https://`, which are the same two schemes spelled the way RFC 3986 §3.1 allows (A159).
    static let readableSchemes: Set<String> = ["http", "https"]

    /// The URL `argument` names, or nil when it is not one this tool can read.
    ///
    /// Three requirements, each of them measured in `AUDIT/baseline/swift64/a159-probe/url-shapes.swift`
    /// rather than assumed: an http(s) scheme whatever its case; a non-empty host, because `http:`,
    /// `http://` and `http:///path` all parse as URLs and name nothing to fetch; and no whitespace, because
    /// Foundation parses `http://example.com/a b` happily and that space would travel to the extractor
    /// inside the URL it is given.
    static func readableURL(_ argument: String) -> URL? {
        let raw = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(where: \.isWhitespace),
            let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(),
            readableSchemes.contains(scheme),
            let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    public func run(argument: String) async throws -> ToolOutcome {
        let raw = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.readableURL(raw) else {
            throw ChatBotsError.toolFailed("\"\(raw)\" is not a readable http(s) URL")
        }

        let pages = try await client.extract(urls: [url.absoluteString], maxCharactersPerPage: maxCharacters)
        guard let page = pages.first, !page.content.isEmpty else {
            return ToolOutcome(
                text: "The page at \(url.absoluteString) returned no readable text.",
                summary: "no readable text at \(url.host() ?? url.absoluteString)"
            )
        }

        return ToolOutcome(
            text: """
            Content of \(page.url)\(page.title.isEmpty ? "" : " (\(page.title))"):

            \(page.content)
            """,
            summary: "read \(page.content.count) chars from \(page.title.isEmpty ? page.url : page.title)"
        )
    }
}
