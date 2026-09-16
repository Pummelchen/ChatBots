// ChatBotsCoreTests — a turn can only run the tools its caller offered
//
// `generate` accepts a `tools` array and `ConversationEngine` passes `tools: []` when the user
// has turned web search off — but dispatch called `ToolRegistry.run(name:)` against the injected
// registry instead of against the passed array. A model that emitted a `web_search` call
// (hallucinated, or injected through the prompt) therefore reached the network even though the
// setting the interface presents as "off" said it should not. It is a privacy boundary, not a
// correctness detail.
//
// `TurnToolSet` is the type dispatch now goes through, so these tests exercise the real decision:
// the caller's array decides what may run, and the registry can only choose which instance
// answers an offered name. The MLX `generate` path itself needs model weights and is not driven
// here; the dispatch it delegates to is.

import Foundation
import Synchronization
import Testing

@testable import ChatBotsCore

/// A tool that records every call it receives, so "it never ran" is a fact rather than an
/// inference from the returned text.
///
/// `Mutex` rather than `NSLock`: `lock()`/`unlock()` are unavailable from an async context, and
/// the scoped form is what Swift 6 asks for here.
private final class RecordingTool: ToolProvider {
    let name: String
    let description = "a tool used by the dispatch tests"
    let argumentName = "query"
    let argumentDescription = "what to look up"

    private let received = Mutex<[String]>([])
    private let shouldFail: Bool

    init(name: String, shouldFail: Bool = false) {
        self.name = name
        self.shouldFail = shouldFail
    }

    var calls: [String] { received.withLock { $0 } }

    func run(argument: String) async throws -> ToolOutcome {
        received.withLock { $0.append(argument) }
        if shouldFail { throw ChatBotsError.toolFailed("\(name) could not run") }
        return ToolOutcome(text: "\(name) looked up \(argument)", summary: "\(name) ran")
    }
}

/// A registry holding `tools`, the way `WebToolbox.makeRegistry()` builds one.
private func registry(of tools: [any ToolProvider]) -> ToolRegistry {
    let registry = ToolRegistry()
    for tool in tools { registry.register(tool) }
    return registry
}

@Suite("A turn runs only the tools its caller offered")
struct ClientsToolDispatchTests {

    /// The ordinary case, so the rest of the file is measured against it.
    @Test("An offered tool runs")
    func offeredToolRuns() async {
        let search = RecordingTool(name: "web_search")
        let turn = TurnToolSet(offered: [search], registry: registry(of: [search]))

        let outcome = await turn.run(name: "web_search", argument: "eggs")

        #expect(search.calls == ["eggs"])
        #expect(outcome.text.contains("looked up eggs"))
    }

    /// The finding, precisely: web search is off, so `ConversationEngine` offers `tools: []`,
    /// while the engine's injected registry still holds `web_search`. A call for it must be
    /// refused and must not reach the tool.
    @Test("A tool the caller did not offer is refused, even when the registry holds it")
    func unofferedToolIsRefused() async {
        let search = RecordingTool(name: "web_search")
        let turn = TurnToolSet(offered: [], registry: registry(of: [search]))
        #expect(turn.isEmpty)

        let outcome = await turn.run(name: "web_search", argument: "a private question")

        #expect(search.calls.isEmpty, "an unoffered call must never reach the tool")
        #expect(outcome.summary.contains("refused"))
        #expect(outcome.text.contains("not available in this turn"))
        #expect(outcome.text.contains("none"), "the refusal should say no tools were available")
    }

    /// Offering one tool does not make its neighbour reachable, even though the same registry
    /// holds both. The offered set is the gate; the registry is not.
    @Test("Offering one tool does not make another reachable")
    func onlyTheOfferedNamesAreReachable() async {
        let search = RecordingTool(name: "web_search")
        let fetch = RecordingTool(name: "fetch_page")
        let turn = TurnToolSet(offered: [search], registry: registry(of: [search, fetch]))

        let refused = await turn.run(name: "fetch_page", argument: "https://example.test")

        #expect(fetch.calls.isEmpty)
        #expect(refused.summary.contains("refused"))
        #expect(refused.text.contains("fetch_page"), "the refusal should name the refused tool")
        #expect(refused.text.contains("web_search"), "the refusal should name what was offered")

        // The offered one still runs, so the gate is not simply refusing everything.
        _ = await turn.run(name: "web_search", argument: "eggs")
        #expect(search.calls == ["eggs"])
    }

    /// A caller that hands the engine its own provider is not required to have registered it.
    @Test("A caller-supplied tool runs even when the registry has never heard of it")
    func callerSuppliedToolRuns() async {
        let custom = RecordingTool(name: "custom_lookup")
        let turn = TurnToolSet(offered: [custom], registry: ToolRegistry())

        _ = await turn.run(name: "custom_lookup", argument: "x")

        #expect(custom.calls == ["x"])
    }

    /// The injection point the CLI relies on still works: for a name the caller offered, the
    /// registry's instance answers. It may replace a provider, never add one.
    @Test("The registry chooses the instance for an offered name")
    func registryOverridesTheInstance() async {
        let offeredInstance = RecordingTool(name: "web_search")
        let registeredInstance = RecordingTool(name: "web_search")
        let turn = TurnToolSet(
            offered: [offeredInstance], registry: registry(of: [registeredInstance]))

        _ = await turn.run(name: "web_search", argument: "query")

        #expect(registeredInstance.calls == ["query"])
        #expect(offeredInstance.calls.isEmpty)
    }

    @Test("A failing offered tool is reported to the model rather than thrown")
    func failureIsReported() async {
        let broken = RecordingTool(name: "web_search", shouldFail: true)
        let turn = TurnToolSet(offered: [broken], registry: registry(of: [broken]))

        let outcome = await turn.run(name: "web_search", argument: "eggs")

        #expect(broken.calls == ["eggs"])
        #expect(outcome.text.contains("Error from web_search"))
        #expect(outcome.summary.contains("failed"))
    }

    @Test("An empty offer is empty, which is what suppresses the tool specs")
    func emptyOfferIsEmpty() {
        #expect(TurnToolSet(offered: [], registry: ToolRegistry()).isEmpty)
        #expect(!TurnToolSet(offered: [RecordingTool(name: "web_search")], registry: ToolRegistry()).isEmpty)
        #expect(TurnToolSet(offered: [], registry: ToolRegistry()).names.isEmpty)
    }
}
