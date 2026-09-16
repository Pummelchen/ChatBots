// ChatBotsCore — the web tools a seat may call
//
// Split out of `ConversationEngine.swift`, which held the orchestrator, its turn loop, its
// transcript plumbing, its context bookkeeping and its research mode in one 1613-line file.
// The toolbox is not part of the orchestrator: it is the one shared client and the tools
// built on it, handed to a turn when the seat has search enabled and budget left.

import Foundation

/// The web tools handed to a seat. One client, shared by every seat.
public enum WebToolbox {
    public static let client = TavilyClient()

    /// The tools this app knows how to offer.
    ///
    /// Listed regardless of whether a key is configured, deliberately. Whether a seat is
    /// offered tools at all is the seat's own `webSearchEnabled`, and that has to stay a
    /// property of the seat rather than of the machine — otherwise the same conversation
    /// behaves differently on a clone with a `.secrets.env` and one without, which is exactly
    /// the kind of hidden condition that is hard to reason about. Whether a search can
    /// actually run is decided where it matters: the opening brief says search is unavailable
    /// when there is no key, and the client refuses with a readable reason rather than sending
    /// an empty token.
    public static let tools: [any ToolProvider] = [
        WebSearchTool(client: client, maxResults: 5),
        FetchPageTool(client: client, maxCharacters: 6_000),
    ]

    /// A registry so an engine can resolve a model's tool call to a live provider.
    public static func makeRegistry() -> ToolRegistry {
        let registry = ToolRegistry()
        for tool in tools { registry.register(tool) }
        return registry
    }
}
