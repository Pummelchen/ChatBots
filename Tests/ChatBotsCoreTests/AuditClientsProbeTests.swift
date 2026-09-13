// ChatBotsCoreTests — the readiness probe runs when it is needed, and a bad body is not
// reported as a missing model (audit A57)
//
// `generate` called `try await load()` unconditionally, and `ready` was only read by `isLoaded`.
// Every turn therefore paid a `/v1/models` round trip, and a transient probe failure — or a
// server that does not serve `/v1/models` at all — failed an otherwise good turn. Separately,
// `try? JSONSerialization…` swallowed a decode failure into `[]`, which `load` reported as "the
// server has no model loaded — load one in LM Studio": a server that answered was described as
// a server with no model, and the moderator was told to do something that would not help.
//
// The engine tests run against the scripted local server, so "the probe was not repeated" is a
// count on the server rather than an inference.

import Foundation
import Testing

@testable import ChatBotsCore

@MainActor
@Suite("The readiness probe runs when it is needed (audit A57)")
struct AuditClientsProbeTests {

    /// One successful turn: a delta and the terminal event.
    private static let happyStream = sse([
        sseTextDelta("Hello"),
        sseCompleted(inputTokens: 3, outputTokens: 1),
        "[DONE]",
    ])

    private func answer(_ engine: OpenAIResponsesEngine) async throws {
        _ = try await engine.generate(
            messages: [PromptMessage(role: .user, content: "Say hello.")],
            tools: [],
            onToolCall: { _, _ in },
            onEvent: { _ in })
    }

    // MARK: - Parsing

    @Test("A valid model list is read")
    func validList() throws {
        let ids = try OpenAIResponsesEngine.modelIDs(
            fromModelsBody: Data(#"{"object":"list","data":[{"id":"a"},{"id":"b"}]}"#.utf8))
        #expect(ids == ["a", "b"])
    }

    @Test("An entry without an id is dropped rather than faked")
    func entryWithoutID() throws {
        let ids = try OpenAIResponsesEngine.modelIDs(
            fromModelsBody: Data(#"{"data":[{"id":"a"},{"object":"model"}]}"#.utf8))
        #expect(ids == ["a"])
    }

    /// A genuinely empty list is still an empty list: this is the case the "no model loaded"
    /// message is for, and it must not be conflated with a body that could not be read.
    @Test("An empty model list is empty, not an error")
    func emptyList() throws {
        let ids = try OpenAIResponsesEngine.modelIDs(fromModelsBody: Data(#"{"data":[]}"#.utf8))
        #expect(ids.isEmpty)
    }

    @Test("A body that is not JSON is an error, not an empty list")
    func notJSON() {
        do {
            _ = try OpenAIResponsesEngine.modelIDs(
                fromModelsBody: Data("<html>not the API</html>".utf8))
            Issue.record("a non-JSON body must not parse as an empty model list")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("JSON"), "the reason should name the unreadable body")
            #expect(
                !message.contains("no model loaded"),
                "a body that could not be read is not a server with no model")
        }
    }

    @Test("A body of the wrong shape is an error, not an empty list")
    func wrongShape() {
        for body in ["[1,2,3]", #"{"object":"list"}"#, #"{"data":"nope"}"#] {
            do {
                _ = try OpenAIResponsesEngine.modelIDs(fromModelsBody: Data(body.utf8))
                Issue.record("\(body) must not parse as an empty model list")
            } catch {
                #expect(!error.localizedDescription.contains("no model loaded"))
            }
        }
    }

    // MARK: - The probe

    /// The finding's first half. Pre-fix `modelsRequests` is 2 and the second turn throws.
    @Test("Only the first turn probes /v1/models")
    func onlyTheFirstTurnProbes() async throws {
        let server = try await ScriptedOpenAIServer(responsesBody: Self.happyStream)
        defer { server.stop() }
        let engine = OpenAIResponsesEngine(spec: scriptedSpec(port: server.port))

        try await answer(engine)

        // A probe that now fails must not matter: the engine has already reached the server.
        server.respondToModels(with: Data("server exploded".utf8), status: 500)

        try await answer(engine)

        #expect(server.modelsRequests == 1, "the readiness probe ran once, not once per turn")
        #expect(server.responsesRequests == 2, "both turns reached the responses endpoint")
    }

    @Test("A later probe failure cannot fail an otherwise good turn")
    func laterProbeFailureIsIrrelevant() async throws {
        let server = try await ScriptedOpenAIServer(responsesBody: Self.happyStream)
        defer { server.stop() }
        let engine = OpenAIResponsesEngine(spec: scriptedSpec(port: server.port))

        try await answer(engine)
        server.respondToModels(with: Data("{}".utf8), status: 503)

        // Must not throw: the probe is not what the turn depends on.
        try await answer(engine)
        #expect(server.responsesRequests == 2)
    }

    /// The finding's second half, through `load` itself: the failure the moderator sees has to
    /// describe the unreadable body, not a missing model.
    @Test("An unreadable /v1/models body is not reported as a missing model")
    func unreadableBodyIsNotAMissingModel() async throws {
        let server = try await ScriptedOpenAIServer(
            modelsBody: Data("not json at all".utf8), responsesBody: Self.happyStream)
        defer { server.stop() }
        let engine = OpenAIResponsesEngine(spec: scriptedSpec(port: server.port))

        var thrown: (any Error)?
        do {
            try await engine.load()
        } catch {
            thrown = error
        }

        let error = try #require(thrown, "a body that cannot be parsed must fail the load")
        let message = error.localizedDescription
        #expect(!message.contains("no model loaded"), "got: \(message)")
        #expect(message.contains("JSON"), "the reason should say the body could not be read")
        #expect(server.responsesRequests == 0, "no generation is attempted on an unreadable probe")
    }

    /// The other side of the same message: an empty list really is "no model loaded", so the
    /// two cases stay distinguishable.
    @Test("An empty model list is still reported as no model loaded")
    func emptyListIsAMissingModel() async throws {
        let server = try await ScriptedOpenAIServer(
            modelsBody: Data(#"{"data":[]}"#.utf8), responsesBody: Self.happyStream)
        defer { server.stop() }
        let engine = OpenAIResponsesEngine(spec: scriptedSpec(port: server.port))

        var thrown: (any Error)?
        do {
            try await engine.load()
        } catch {
            thrown = error
        }
        #expect(
            thrown?.localizedDescription.contains("no model loaded") == true,
            "an empty list is the case that message is for")
    }

    /// `unload` clears readiness, so a deliberate unload still re-probes on the next turn
    /// rather than generating into a server nobody has checked.
    @Test("An unloaded engine probes again on the next turn")
    func unloadReprobes() async throws {
        let server = try await ScriptedOpenAIServer(responsesBody: Self.happyStream)
        defer { server.stop() }
        let engine = OpenAIResponsesEngine(spec: scriptedSpec(port: server.port))

        try await answer(engine)
        await engine.unload()
        try await answer(engine)

        #expect(server.modelsRequests == 2, "readiness was cleared, so the probe is needed again")
    }
}
