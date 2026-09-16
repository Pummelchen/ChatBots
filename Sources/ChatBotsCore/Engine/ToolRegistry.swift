// ChatBotsCore — the tools a turn may call, and their dispatch
//
// Split out of `MLXEngine.swift`, which held the engine, its sampling settings, its text assembler and
// its supporting actors in one 942-line file. The types did not change.

import Foundation

/// Maps a tool name emitted by a model to a live `ToolProvider`.
///
/// `@unchecked Sendable` because its one piece of mutable state, `tools`, is confined to
/// `lock`: `register` writes the dictionary and `tool(named:)` reads it, each holding `lock`,
/// and `tools` is private so no other code can reach it. `tool(named:)` copies the provider out
/// under the lock and the caller awaits outside it, which is safe because `ToolProvider` refines
/// `Sendable` — the value that escapes the lock carries its own synchronisation. What keeps the
/// confinement true is that `lock` is a `let` and `register` and `tool(named:)` are the only
/// accessors of the dictionary.
public final class ToolRegistry: @unchecked Sendable {
    public static let shared = ToolRegistry()

    private let lock = NSLock()
    private var tools: [String: any ToolProvider] = [:]

    public init() {}

    public func register(_ tool: any ToolProvider) {
        lock.lock()
        defer { lock.unlock() }
        tools[tool.name] = tool
    }

    public func tool(named name: String) -> (any ToolProvider)? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]
    }
}

/// The tools one turn may run.
///
/// The caller's `tools` array is the whole of what a turn may reach. It is what was rendered
/// into the model's tool specs, so a call for any other name — a hallucinated call, or one
/// injected through the prompt — is a name the turn never offered and must be **refused rather
/// than dispatched**. Before this, dispatch went straight to `ToolRegistry.run(name:)` against
/// the injected registry, so `ConversationEngine` passing `tools: []` when the user had turned
/// web search off still let an emitted `web_search` call reach the network: a setting the
/// interface presents as "off" did not stop an outbound request.
///
/// The registry remains the place a provider instance is injected — the CLI builds one with
/// `WebToolbox.makeRegistry()` and hands it to the engine — but it can only decide *which*
/// instance answers a name the caller offered. It can never widen the set.
///
/// `Sendable` because `byName` is built once in `init` and never mutated. The dictionary crosses
/// into `generateExclusively` and is read there while the model streams, but every value is a
/// `ToolProvider`, which refines `Sendable`, so no lock is needed.
struct TurnToolSet: Sendable {
    private let byName: [String: any ToolProvider]

    init(offered tools: [any ToolProvider], registry: ToolRegistry) {
        var resolved: [String: any ToolProvider] = [:]
        for tool in tools {
            // An offered tool runs even if the registry has never heard of it: the caller's
            // array is what makes it available. When the registry does know the name, its
            // instance is preferred, which is the injection point the CLI relies on.
            resolved[tool.name] = registry.tool(named: tool.name) ?? tool
        }
        self.byName = resolved
    }

    /// True when the caller offered no tools, which is how a seat with web search turned off
    /// arrives here.
    var isEmpty: Bool { byName.isEmpty }

    /// The names this turn may run, for the refusal message.
    var names: [String] { byName.keys.sorted() }

    /// Never throws: a refused or failed tool is reported back to the model as text so it can
    /// adapt, instead of killing the turn.
    func run(name: String, argument: String) async -> ToolOutcome {
        guard let tool = byName[name] else {
            let available = names.isEmpty ? "none" : names.joined(separator: ", ")
            return ToolOutcome(
                text: "Error: \(name) is not available in this turn. Available tools: \(available).",
                summary: "refused \(name) (not offered this turn)"
            )
        }
        do {
            return try await tool.run(argument: argument)
        } catch {
            return ToolOutcome(
                text: "Error from \(name): \(error.localizedDescription)",
                summary: "\(name) failed"
            )
        }
    }
}
