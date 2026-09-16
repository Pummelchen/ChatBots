// ChatBotsCoreTests — a setter awaited on the *concrete* engine type
//
// `LLMEngine` requires `setThinking`, `setPersona` and `setDisplayName` to be `async`, and a protocol
// extension supplies async no-op defaults for them. `MLXEngine` and `OpenAIResponsesEngine` declared
// all three as *synchronous* instead. A synchronous method can witness an async requirement, so the
// conformance is satisfied and the no-op default is never used through the protocol — but it also
// puts two candidates in scope at a call site that names the concrete actor type, and `await`
// prefers the async one. The async one is the extension's no-op, so the write is silently discarded
// and the control does nothing.
//
// Every shipped call site goes through `any LLMEngine`, which is the only reason this is latent
// rather than live: `ConversationEngine.seatEngine(for:)` returns the existential, so the real
// implementations are reached. The defect is one type annotation away, and it is the same class —
// a control that is presented as working and is not. `TurnLoopModelTests.liveConfiguration`
// already calls through the protocol and carries a comment naming this defect, deliberately, so that
// it does not pin the broken shape.
//
// These tests name the concrete type, which is the shape that breaks.

import Testing

@testable import ChatBotsCore

@Suite("Setters awaited on the concrete engine type")
struct EngineSetterShadowingTests {

    /// A seat that differs from its `spec` in every field these setters touch, so a setter that
    /// silently does nothing is visible rather than coincidentally equal to the starting value.
    private func seat() -> AgentSpec {
        var seat = AgentSpec.makeSeats(count: 1)[0]
        seat.thinking = .off
        seat.personaID = PersonaLibrary.neutral.id
        seat.displayName = "Mira"
        return seat
    }

    @Test("MLXEngine: all three setters take effect when awaited on the concrete type")
    func mlxConcreteSettersApply() async {
        let concrete = MLXEngine(spec: seat())

        await concrete.setThinking(.high)
        await concrete.setPersona(PersonaLibrary.neutral.id)
        await concrete.setDisplayName("Iris")

        #expect(await concrete.thinking == .high, "setThinking reached the actor")
        let live = await concrete.currentSpec
        #expect(live.thinking == .high)
        #expect(live.displayName == "Iris")
        #expect(await concrete.spec.displayName == "Mira", "the protocol's spec is immutable")
    }

    @Test("OpenAIResponsesEngine: all three setters take effect when awaited on the concrete type")
    func openAIConcreteSettersApply() async {
        let concrete = OpenAIResponsesEngine(spec: seat())

        await concrete.setThinking(.high)
        await concrete.setPersona(PersonaLibrary.neutral.id)
        await concrete.setDisplayName("Iris")

        #expect(await concrete.thinking == .high, "setThinking reached the actor")
        let live = await concrete.currentSpec
        #expect(live.thinking == .high)
        #expect(live.displayName == "Iris")
    }

    @Test("A stub that leans on the protocol default still compiles and stays inert")
    func protocolDefaultRemainsAvailable() async {
        // The defaults exist so a test double or read-only proxy need not write empty methods. They
        // are kept, and this pins that they still satisfy the requirement — the fix changes the two
        // real engines to match the requirement, not the requirement's optionality.
        let stub = InertEngine(spec: seat())
        let engine: any LLMEngine = stub
        await engine.setThinking(.high)
        await engine.setDisplayName("Iris")
        #expect(await stub.currentSpec.displayName == "Mira", "the default intentionally does nothing")
    }
}

private actor InertEngine: LLMEngine {
    let spec: AgentSpec
    init(spec: AgentSpec) { self.spec = spec }

    var currentSpec: AgentSpec { spec }
    var isLoaded: Bool { false }
    var contextWindow: Int { 0 }
    func load() async throws {}
    func unload() async {}

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        ""
    }
}
