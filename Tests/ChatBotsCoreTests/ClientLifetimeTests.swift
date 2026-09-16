// ChatBotsCoreTests — one client per engine, and a session that closes itself
//
// `OpenAIResponsesEngine.generate` built a client inside the turn, and the client's `init` builds a
// `URLSession`. So every turn of a conversation paid a fresh connection and TLS handshake, and left a
// session behind — the opposite of `MLXEngine`, which caches its container — in a product whose whole
// cloud feature is a conversation of many turns against one endpoint.
//
// `URLSession` is not released when the last reference to it goes: it stays alive, with its delegate
// and its pool, until it is invalidated. Two tests here: one counts the clients an engine builds across
// two turns, and one holds a weak reference to a client's session to see that the session lets go of
// itself when the client does.

import Foundation
import Synchronization
import Testing

@testable import ChatBotsCore

@MainActor
@Suite("The cloud client's lifetime", .serialized)
struct OpenAIResponsesClientLifetimeTests {

    private static let completedStream = sse([
        sseTextDelta("Hello"), sseCompleted(inputTokens: 3, outputTokens: 1), "[DONE]",
    ])

    @Test("Two turns through one engine build one client, so one session and one pool")
    func twoTurnsShareOneClient() async throws {
        let server = try await ScriptedOpenAIServer(responsesBody: Self.completedStream)
        defer { server.stop() }

        let built = Mutex(0)
        let engine = OpenAIResponsesEngine(
            spec: scriptedSpec(port: server.port),
            makeClient: { endpoint in
                built.withLock { $0 += 1 }
                return OpenAIResponsesClient(endpoint: endpoint)
            })

        for turn in 1...2 {
            let answer = try await engine.generate(
                messages: [.init(role: .user, content: "Say hello. Turn \(turn)")],
                tools: [],
                onToolCall: { _, _ in }, onEvent: { _ in })
            #expect(answer == "Hello")
        }

        #expect(built.withLock { $0 } == 1, "a second turn must not build a second client")
        #expect(server.responsesRequests == 2, "both turns reached the endpoint")
    }

    @Test("A client lets go of its session, and the session lets go of itself")
    func theSessionIsInvalidatedWhenTheClientGoes() async throws {
        weak var weakSession: URLSession?
        do {
            let client = OpenAIResponsesClient(endpoint: scriptedEndpoint(port: 1))
            weakSession = client.responseSession.session
            #expect(weakSession != nil, "the session is alive while its client is")
        }

        // `finishTasksAndInvalidate` runs in the owner's `deinit`; a session that is merely released
        // without being invalidated stays alive, which is what the evidence log measures side by side.
        try await Task.sleep(for: .milliseconds(300))
        #expect(weakSession == nil, "a released client must not leave its session alive")
    }

    @Test("The engine's client is made once even when a turn fails")
    func aFailedTurnStillLeavesOneClient() async throws {
        // A failing turn is the case a per-turn client was most obviously wrong for: the retry, or the
        // next turn after a transient error, built another session rather than reusing the connection
        // it already had.
        let server = try await ScriptedOpenAIServer(
            responsesBody: Self.completedStream, responsesStatus: 500)
        defer { server.stop() }

        let built = Mutex(0)
        let engine = OpenAIResponsesEngine(
            spec: scriptedSpec(port: server.port),
            makeClient: { endpoint in
                built.withLock { $0 += 1 }
                return OpenAIResponsesClient(endpoint: endpoint)
            })

        for _ in 1...2 {
            _ = try? await engine.generate(
                messages: [.init(role: .user, content: "Say hello.")],
                tools: [],
                onToolCall: { _, _ in }, onEvent: { _ in })
        }

        #expect(built.withLock { $0 } == 1)
    }
}
