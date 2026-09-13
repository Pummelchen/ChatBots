// ChatBotsCoreTests — a real local OpenAI-compatible server, for the client and engine tests
//
// The OpenAI client and engine talk HTTP, so a stub that replaces the transport would prove
// nothing about the parts under test: the client builds its own `URLSession` from a private
// configuration, and `URLSession`'s own line splitting, response framing and connection
// teardown are exactly where a truncated stream is decided. A stubbed `URLProtocol` cannot
// reach a session that was not configured with it, so these tests start a real `HTTPServer` on
// a loopback port of its own and script the bodies it answers with.
//
// The bodies are raw SSE so a test can end a stream wherever it likes — after a delta, after
// `[DONE]`, after an explicit failure — which is the whole point of the truncation tests.

import ChatBotsCore
import Foundation
import Testing

/// A loopback server that answers `/v1/models` and `/v1/responses` with scripted bytes, and
/// counts how many requests reached each.
///
/// `@MainActor` because `HTTPServer.Handler` is: the closures are called on the main actor, so
/// the counters need no lock and a test reads them from the same isolation.
@MainActor
final class ScriptedOpenAIServer {

    /// State shared with the handler, which the server calls after `init` has returned.
    @MainActor
    private final class State {
        var modelsRequests = 0
        var responsesRequests = 0
        var modelsStatus = 200
        var modelsBody = ScriptedOpenAIServer.defaultModelsBody
        var responsesStatus = 200
        var responsesBody = Data()
    }

    /// A valid `/v1/models` body, so a turn reaches the streaming request. The id deliberately
    /// matches the spec these tests build, so `load()` does not have to warn.
    static let defaultModelsBody = Data(
        #"{"object":"list","data":[{"id":"test-model","object":"model"}]}"#.utf8)

    private let state: State
    private let server: HTTPServer
    let port: UInt16

    /// Requests that reached each endpoint, counted by the handler.
    var modelsRequests: Int { state.modelsRequests }
    var responsesRequests: Int { state.responsesRequests }

    /// Change what `/v1/models` answers, so a test can make a later probe fail after a first
    /// turn has already succeeded.
    func respondToModels(with body: Data, status: Int) {
        state.modelsBody = body
        state.modelsStatus = status
    }

    init(
        modelsBody: Data = ScriptedOpenAIServer.defaultModelsBody,
        modelsStatus: Int = 200,
        responsesBody: Data,
        responsesStatus: Int = 200
    ) async throws {
        // The handler captures this instance, so it must be the one the accessors read: a
        // separate default-valued property would leave the counts permanently at zero.
        let state = State()
        state.modelsBody = modelsBody
        state.modelsStatus = modelsStatus
        state.responsesBody = responsesBody
        state.responsesStatus = responsesStatus

        // A taken port is reported asynchronously by the listener, so `start()` returning is not
        // evidence that anything is listening; the retry is the same shape the HTTP server tests
        // use for the same reason.
        var started: HTTPServer?
        var chosenPort: UInt16 = 0
        for _ in 0..<8 {
            let candidate = allocateTestPort()
            let server = HTTPServer(
                port: candidate,
                handler: { request in
                    if request.path.hasPrefix("/v1/models") {
                        state.modelsRequests += 1
                        return HTTPResponse(status: state.modelsStatus, body: state.modelsBody)
                    }
                    state.responsesRequests += 1
                    return HTTPResponse(
                        status: state.responsesStatus,
                        contentType: "text/event-stream",
                        body: state.responsesBody)
                })
            try server.start()
            if await server.waitUntilReady() {
                started = server
                chosenPort = candidate
                break
            }
            server.stop()
        }
        guard let started else { throw ScriptedServerError.noPort }
        self.state = state
        self.server = started
        self.port = chosenPort
    }

    func stop() { server.stop() }
}

enum ScriptedServerError: Error {
    case noPort
}

/// The endpoint for a scripted server. `.extended` matches what a local server is inferred as.
func scriptedEndpoint(port: UInt16) -> OpenAIEndpoint {
    OpenAIEndpoint(
        baseURL: "http://127.0.0.1:\(port)", model: "test-model", compatibility: .extended)
}

/// A seat on a scripted server, for the engine-level tests.
func scriptedSpec(port: UInt16) -> AgentSpec {
    AgentSpec(
        id: "Agent A",
        displayName: "Agent A",
        backend: .openAIResponses,
        openAI: scriptedEndpoint(port: port),
        maxTokens: 64)
}

/// SSE bytes from already-formed `data:` payloads.
func sse(_ payloads: [String]) -> Data {
    Data(payloads.map { "data: \($0)\n\n" }.joined().utf8)
}

/// A `response.output_text.delta` event.
func sseTextDelta(_ text: String) -> String {
    #"{"type":"response.output_text.delta","delta":"\#(text)"}"#
}

/// A `response.completed` event carrying usage.
func sseCompleted(inputTokens: Int = 0, outputTokens: Int = 0) -> String {
    #"{"type":"response.completed","response":{"usage":{"input_tokens":\#(inputTokens),"output_tokens":\#(outputTokens)}}}"#
}
