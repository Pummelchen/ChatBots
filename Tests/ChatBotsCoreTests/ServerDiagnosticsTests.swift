// ChatBotsCoreTests — a running engine can say what is going wrong
//
// Nothing recorded anything. `_ = error` threw a dropped connection away, a malformed request was
// answered and forgotten, and the counters the listener already kept — refused connections, held
// connections, open streams, the listener's own failure — were reachable from no endpoint. Diagnosing a
// live engine meant reading source.
//
// Now every refusal is recorded once, in a bounded ring, and `/api/health` reports the counters and the
// ring. The bound is at the source rather than at the endpoint because `/api` is unauthenticated and
// reachable from the LAN: a server anyone can poke must not keep an unbounded log of pokes.
//
// The same endpoint also had to answer the *other* question — whether the engine behind the listener can
// serve a conversation at all — and it did not: the status was a hardcoded 200 with a hardcoded "ok", and
// the readiness signal that existed, `seatCount`, was read by nobody. A seat count cannot answer
// it either, because an engine without seats traps. What can answer it is whether the seats' models
// loaded: weights load when a conversation starts, so a seat that failed carries the reason from then on.
// The second suite here is about that, and the endpoint now answers 503 when no seat could load.

import Foundation
import Testing

@testable import ChatBotsCore

private actor DiagnosticsStub: LLMEngine {
    nonisolated let spec: AgentSpec
    init(spec: AgentSpec) { self.spec = spec }
    var isLoaded: Bool { true }
    var contextWindow: Int { spec.contextWindow }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}
    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String { "" }
}

/// A seat whose model cannot be loaded — the state a health check exists to report, and one that used to
/// be indistinguishable from a healthy engine.
private actor UnloadableStub: LLMEngine {
    nonisolated let spec: AgentSpec
    init(spec: AgentSpec) { self.spec = spec }
    var isLoaded: Bool { false }
    var contextWindow: Int { spec.contextWindow }
    var currentSpec: AgentSpec { spec }
    func load() async throws { throw LoadFailure.noCheckpoint }
    func unload() async {}
    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String { "" }
}

private enum LoadFailure: Error {
    case noCheckpoint
}

/// A running API server with the listener it owns, so a test can ask both what the socket recorded and
/// what the endpoint answers. The port travels with it rather than being parsed back out of the base URL.
private struct DiagnosticsFixture {
    let server: APIServer
    let http: HTTPServer
    let session: URLSession
    let base: String
    let port: UInt16
    /// The room behind the endpoint, so a test can start it and see what the health check makes of it.
    let engine: ConversationEngine
}

@MainActor
private func diagnosticsServer(
    engines makeEngine: (AgentSpec) -> any LLMEngine = { DiagnosticsStub(spec: $0) }
) async throws -> DiagnosticsFixture {
    let specs = AgentSpec.makeSeats(count: 2)
    let seats = specs.map { ConversationEngine.Seat(spec: $0, engine: makeEngine($0)) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    // One turn each: these tests are about what the seats say when they are asked to load, not about
    // how long a room of stubs can talk to itself.
    configuration.maxTurns = 1
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    engine.setTopic("A diagnostic test")
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "diagnostics-\(UUID().uuidString)"))
    let session = URLSession(configuration: .ephemeral)
    for _ in 0..<8 {
        let port = allocateTestPort()
        let server = APIServer(engine: engine, store: store, port: port)
        try server.start()
        if await server.waitUntilReady(), let http = server.httpServer {
            return DiagnosticsFixture(
                server: server, http: http, session: session,
                base: "http://127.0.0.1:\(port)", port: port, engine: engine)
        }
        server.stop()
    }
    throw DiagnosticsTestError.noPort
}

/// Fetch and decode `/api/health`, with the status code the client actually received.
@MainActor
private func fetchHealth(_ fixture: DiagnosticsFixture) async throws -> (health: APIHealth, status: Int) {
    let url = try #require(URL(string: "\(fixture.base)/api/health"))
    let (data, response) = try await fixture.session.data(from: url)
    let decoder = JSONDecoder()
    // The same wire shape the interface reads: timestamps travel as ISO 8601 text.
    decoder.dateDecodingStrategy = .iso8601
    return (try decoder.decode(APIHealth.self, from: data), (response as? HTTPURLResponse)?.statusCode ?? 0)
}

/// Ask `/api/health` until it answers what `predicate` is waiting for, or the deadline passes.
///
/// The seats load in a task the room starts, so the first answer after `startOrRestart()` may be the one
/// from before the attempt. Polling the endpoint rather than sleeping a guessed interval keeps the wait
/// tied to the thing under test.
@MainActor
private func healthUntil(
    _ fixture: DiagnosticsFixture,
    within timeout: Duration = .seconds(5),
    _ predicate: (APIHealth) -> Bool
) async throws -> (health: APIHealth, status: Int) {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var answer = try await fetchHealth(fixture)
    while !predicate(answer.health), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
        answer = try await fetchHealth(fixture)
    }
    return answer
}

private enum DiagnosticsTestError: Error {
    case noPort
}

@MainActor
@Suite("A running engine can say what is going wrong")
struct ServerDiagnosticsTests {

    @Test("The failure ring keeps the newest entries and no more than its limit")
    func theRingIsBoundedAndNewestFirst() {
        let server = HTTPServer(port: allocateTestPort(), handler: { _ in .json(["ok": "yes"]) })
        defer { server.stop() }

        #expect(server.recentFailures.isEmpty)
        for index in 1...HTTPServer.failureHistoryLimit * 2 {
            server.note("failure \(index)")
        }

        let failures = server.recentFailures
        #expect(failures.count == HTTPServer.failureHistoryLimit, "the ring grew past its bound")
        #expect(failures.first?.reason == "failure \(HTTPServer.failureHistoryLimit * 2)")
        #expect(failures.last?.reason == "failure \(HTTPServer.failureHistoryLimit + 1)")
        // Newest first, and time moves forward: what a reader wants at the top is what just happened.
        #expect(failures[0].at >= failures[1].at)
    }

    @Test("A malformed request is answered and recorded")
    func aMalformedRequestIsRecorded() async throws {
        let fixture = try await diagnosticsServer()
        defer { fixture.server.stop() }
        let http = fixture.http

        #expect(http.recentFailures.isEmpty, "nothing has gone wrong yet")
        let client = try RawConnection(port: fixture.port)
        defer { client.cancel() }
        #expect(await client.connect())
        // Not a request: one token where a request line of three parts belongs. The parser refuses it and
        // the server answers 400 — and, before this, forgot it.
        client.send("nonsense\r\n\r\n")
        let reply = try #require(await client.receiveOnce(timeout: .seconds(5)))
        #expect((String(bytes: reply, encoding: .utf8) ?? "").hasPrefix("HTTP/1.1 400"))

        let failures = http.recentFailures
        #expect(!failures.isEmpty, "the refused request left no trace")
        #expect(failures.first?.reason.hasPrefix("request:") == true, "got \(failures.first?.reason ?? "nothing")")
    }

    @Test("The health endpoint reports the counters and the recent failures")
    func theHealthEndpointReports() async throws {
        let fixture = try await diagnosticsServer()
        defer { fixture.server.stop() }

        // One real failure first, so the endpoint has something to report besides zeroes.
        fixture.http.note("connection: a client went away")

        let (health, status) = try await fetchHealth(fixture)
        #expect(status == 200)
        #expect(health.status == "ok")
        #expect(health.port == Int(fixture.port))
        #expect(health.openStreams == 0)
        #expect(health.refusedConnections == 0)
        #expect(health.listenerError == nil)
        #expect(health.connections >= 0)
        #expect(health.recentFailures.first?.reason == "connection: a client went away")
    }
}

@MainActor
@Suite("A listener says whether it can serve, not just that it is listening")
struct HealthReadinessTests {

    @Test("An engine whose seats have not been asked to load is ready")
    func silenceIsNotFailure() async throws {
        // Weights load when a conversation starts, not at launch, so a fresh engine has nothing to
        // report. Readiness must not turn that into "unavailable".
        let fixture = try await diagnosticsServer()
        defer { fixture.server.stop() }

        let (health, status) = try await fetchHealth(fixture)
        #expect(status == 200)
        #expect(health.status == "ok")
        #expect(health.ready)
        #expect(health.seats == 2)
        #expect(health.reason == nil)
        #expect(health.failedSeats.isEmpty)
    }

    @Test("An engine whose every seat failed to load is not ready, and answers 503")
    func everySeatFailingIsAnOutage() async throws {
        let fixture = try await diagnosticsServer(engines: { UnloadableStub(spec: $0) })
        defer { fixture.server.stop() }

        // Nothing has been tried yet, so the listener is ready and says so.
        let (before, beforeStatus) = try await fetchHealth(fixture)
        #expect(before.ready)
        #expect(beforeStatus == 200)

        fixture.engine.startOrRestart()
        let (health, status) = try await healthUntil(fixture) { !$0.ready }

        #expect(health.status == "unavailable")
        #expect(health.ready == false, "a listener whose seats cannot load still claimed to be ready")
        #expect(status == 503, "the status code said 200 for an engine that cannot serve")
        #expect(health.seats == 2)
        #expect(health.reason != nil, "not ready with no reason a person can act on")
        #expect(health.failedSeats.count == 2, "got \(health.failedSeats)")
    }

    @Test("One seat failing is degradation, not an outage")
    func oneSeatFailingIsDegradation() async throws {
        // A room that loses one of its two seats can still hold a conversation. Reporting that as an
        // outage would stop a caller from using the seat that works, so the two cases differ.
        let fixture = try await diagnosticsServer { spec in
            // Seat ids are "Agent 1" and "Agent 2"; the first one is the seat that cannot load.
            spec.id.hasSuffix("1") ? UnloadableStub(spec: spec) as any LLMEngine : DiagnosticsStub(spec: spec)
        }
        defer { fixture.server.stop() }
        guard let firstSeat = fixture.engine.allSeats.first else {
            Issue.record("the fixture built no seats")
            return
        }
        let failingSeat = firstSeat.spec.id

        fixture.engine.startOrRestart()
        let (health, status) = try await healthUntil(fixture) { !$0.failedSeats.isEmpty }

        #expect(status == 200)
        #expect(health.ready, "one broken seat stopped the engine from serving at all")
        #expect(health.status == "ok")
        #expect(health.reason == nil)
        #expect(health.failedSeats.count == 1, "got \(health.failedSeats)")
        #expect(
            health.failedSeats.keys.first == failingSeat,
            "the report names the wrong seat: \(health.failedSeats)")
    }
}
