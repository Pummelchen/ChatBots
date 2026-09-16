// ChatBotsAppTests — the reason a connection failed is not covered by its symptoms (A175)
//
// `connect` stored the client before it knew whether the client had connected. Everything downstream
// reads `client != nil` as "there is an engine to talk to", so a failed start left the app holding a
// disconnected client: `applyAPIEndpoints` then fired one command per seat into it, each answered
// with a transport failure, and the last of those failures was what the banner showed. The sentence
// that said *why* the engine could not be reached — the thing the user needs — was overwritten by a
// symptom of it before it was ever read.
//
// Two halves, both pinned here: a client that never connected is not stored, and a control that finds
// nothing to send through does not replace a reason that is already on screen.

import ChatBotsCore
import Foundation
import Testing

@testable import ChatBots

@MainActor
@Suite("The reason a connection failed (A175)")
struct ConnectionReasonTests {

    @Test("A connection that failed leaves no client behind")
    func aFailedConnectionStoresNoClient() {
        let controller = ChatController()
        controller.noteConnectionFailed("Could not reach the engine: the engine never answered")

        #expect(controller.client == nil, "`client != nil` must mean there is an engine to talk to")
        #expect(controller.engineConnection == "Could not reach the engine: the engine never answered")
    }

    @Test("The seat endpoints pushed after a failed start do not cover the reason")
    func pushingEndpointsKeepsTheReason() async {
        // This is the sequence the finding describes: `connect` fails, the window's task calls
        // `applyAPIEndpoints`, and one command per seat goes nowhere. The commands are tasks, so the
        // main actor is yielded to them — a version that had a client to send through would have
        // overwritten the reason by the time this returns.
        let controller = ChatController()
        controller.noteConnectionFailed("Could not reach the engine: connection refused")

        var environment: [String: String] = [:]
        environment["CHATBOTS_SEAT_1_BASE_URL"] = "http://127.0.0.1:1234"
        controller.applyAPIEndpoints(APIEndpointStore(environment: environment))
        for _ in 0..<5 { await Task.yield() }

        #expect(controller.engineConnection == "Could not reach the engine: connection refused")
    }

    @Test("Any other control pressed while disconnected does not cover it either")
    func anyControlKeepsTheReason() async {
        let controller = ChatController()
        controller.noteConnectionFailed("Could not reach the engine: timed out")
        controller.setThinking(.high, for: "Agent 1")
        controller.setBackend(.openAIResponses, for: "Agent 1")
        for _ in 0..<5 { await Task.yield() }

        #expect(controller.engineConnection == "Could not reach the engine: timed out")
    }

    @Test("With nothing to explain it, a control says there is no connection")
    func withNoReasonTheControlSaysSo() {
        let controller = ChatController()
        #expect(controller.engineConnection == nil)

        controller.setThinking(.high, for: "Agent 1")

        #expect(controller.engineConnection == "Not connected to the engine.")
    }

    @Test("A reason that is already the fallback is not replaced by a later control")
    func theFallbackIsStable() {
        // The fallback is idempotent rather than accumulating: pressing three controls with no
        // connection must not produce three different sentences.
        let controller = ChatController()
        controller.setThinking(.high, for: "Agent 1")
        let first = controller.engineConnection
        controller.setThinking(.low, for: "Agent 1")

        #expect(controller.engineConnection == first)
    }
}
