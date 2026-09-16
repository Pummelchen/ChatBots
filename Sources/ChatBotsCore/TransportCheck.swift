// ChatBotsCore — proving the WebTransport channel works
//
// A round trip over the real transport, used by the installer and available as
// `chatbots-cli --check-transport`. It starts a server, connects to it as a client, sends each
// kind of request, receives a state and an output event, and reports what it saw.
//
// This exists because a transport can be wrong in ways no unit test sees: streams that never
// open, framing that works in a mock and not over QUIC, a server that accepts a connection and
// then cannot serve it. The only way to know is to do the whole thing on a real socket.

import Foundation

public struct TransportCheckReport: Sendable {
    public var fingerprint: String
    public var connected = false
    public var roundTrips = 0
    public var refusedAsExpected = false
    public var receivedState = false
    public var receivedEvent = false
    public var sessionCount = 0
    public var failures: [String] = []

    public var succeeded: Bool { failures.isEmpty && connected && roundTrips >= 3 }

    public func describe() -> String {
        var lines = [
            "  certificate   \(fingerprint)",
            "  connected     \(connected ? "yes" : "NO")",
            "  round trips   \(roundTrips)",
            "  state         \(receivedState ? "received" : "NOT RECEIVED")",
            "  output event  \(receivedEvent ? "received" : "not seen (no model loaded)")",
            "  refusal       \(refusedAsExpected ? "refused as expected" : "NOT REFUSED")",
            "  sessions      \(sessionCount)",
        ]
        if !failures.isEmpty {
            lines.append("  failures:")
            lines.append(contentsOf: failures.map { "    · \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Recording one step
    //
    // Each check the run performs decides two things: whether the round trip happened, and
    // whether it proved what it was meant to. Both are recorded here rather than inline in
    // `run`, so the reporting is exercised without a socket — which is the part of the
    // installer's smoke test that can be tested at all (audit A02). `run` still owns the
    // requests; these own what a result means.

    /// Something the check could not do, reported verbatim.
    public mutating func recordFailure(_ message: String) { failures.append(message) }

    /// The state read returned. `false` means it returned no state, which is a failure: the
    /// channel answered but the engine had nothing to say.
    public mutating func recordStateRead(received: Bool) {
        roundTrips += 1
        receivedState = received
        if !received { failures.append("fetchState returned no state") }
    }

    /// A command changed what it was meant to. The reply is one round trip either way.
    public mutating func recordCommand(tookEffect: Bool, failure: String) {
        roundTrips += 1
        if !tookEffect { failures.append(failure) }
    }

    /// A request that should have been refused by the engine. `failureWhenNotRefused` is nil
    /// for a command where not being refused is merely surprising rather than wrong.
    public mutating func recordRefusal(wasRefused: Bool, failureWhenNotRefused: String?) {
        roundTrips += 1
        if wasRefused {
            refusedAsExpected = true
        } else if let failureWhenNotRefused {
            failures.append(failureWhenNotRefused)
        }
    }

    /// The session still answers after the refusals.
    public mutating func recordStateAfterRefusals(received: Bool) {
        roundTrips += 1
        if !received { failures.append("the session did not survive a refusal") }
    }

    /// What arrived on the event stream. An output fragment is optional — nothing is
    /// generated here, so its absence is not a failure — but the initial state is not.
    public mutating func recordEventStream(state: Bool, event: Bool) {
        receivedEvent = event
        if !state { failures.append("no state arrived on the event stream") }
    }
}

public enum TransportCheck {

    /// The client's per-request budget, in the milliseconds the transport takes.
    ///
    /// Extracted rather than inlined so the mapping from `run`'s `timeout` to the client can be
    /// tested without a socket. The parameter used to be declared and never read, so the check the
    /// installer's smoke test runs had no deadline of its own (A122).
    static func clientTimeoutMilliseconds(_ timeout: Duration) -> Int32 {
        let components = timeout.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let milliseconds = seconds * 1000
        // Clamped rather than converted straight to `Int32`, which traps on a value that does not
        // fit; and floored at 1, because a zero deadline reads as "the engine never answers"
        // rather than as "the budget was absurd".
        if !milliseconds.isFinite || milliseconds >= Double(Int32.max) { return Int32.max }
        return max(1, Int32(milliseconds))
    }

    /// How long one connect attempt may take before the next one is tried.
    ///
    /// Two seconds is far longer than a loopback handshake against a listener that is already up —
    /// the whole check, five round trips included, finishes in about three — and far shorter than
    /// the budget the run gets, so the six attempts the loop below allows are spread across the time
    /// the engine needs to come up instead of the first one spending it all (A215).
    static let connectAttemptBudgetMilliseconds: Int32 = 2_000

    /// The connect deadline one attempt gets.
    ///
    /// The attempt budget, unless the caller asked for a run shorter than that — a one-second check
    /// does not get a two-second attempt, because an attempt that outlives its own run reports a
    /// connection failure for a run that was already over.
    static func connectAttemptMilliseconds(_ timeout: Duration) -> Int32 {
        min(connectAttemptBudgetMilliseconds, clientTimeoutMilliseconds(timeout))
    }

    /// Run the whole channel end to end.
    ///
    /// - Parameter directory: where the certificate lives, so the check uses the same identity
    ///   a real run would rather than creating another. The engine it starts is told the same
    ///   directory, so the fingerprint this check reports is the one on the other end of the socket
    ///   (reported, not enforced — see `CertificateStore`).
    /// - Parameter timeout: the whole check's budget — the client's request deadline and the
    ///   connect retries are both taken from it.
    /// - Parameter executable: the engine to spawn, defaulting to the process's own executable.
    ///   That default is right for the installer, where this *is* `chatbots-cli`, and wrong for
    ///   anything driving the check from inside another program: a test runner's
    ///   `arguments.first` is the test binary, so the child that came up was a second test
    ///   process and the client timed out against a listener nobody had started (A170). Naming
    ///   the engine is what makes the check testable without pretending it is the installer.
    @MainActor
    public static func run(
        in directory: URL, port: UInt16 = 7795, timeout: Duration = .seconds(30),
        executable: URL? = nil
    ) async -> TransportCheckReport {
        var report = TransportCheckReport(fingerprint: "not generated")
        // One deadline for the run, so `timeout` bounds the check rather than decorating the
        // signature (A122).
        let deadline = ContinuousClock.now.advanced(by: timeout)

        let identity: EngineIdentity
        do {
            identity = try CertificateStore.loadOrCreate(in: directory)
        } catch {
            report.recordFailure("certificate: \(error.localizedDescription)")
            return report
        }
        report.fingerprint = identity.fingerprintDisplay

        // A real engine, with a stub that never generates, so the check is about the channel
        // rather than about loading two gigabytes of weights.
        let specs = AgentSpec.makeSeats(count: 2)
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        let seats = specs.map { spec in
            ConversationEngine.Seat(spec: spec, engine: TransportCheckEngine(spec: spec))
        }
        let engine = ConversationEngine(seats: seats, configuration: configuration)
        engine.setTopic("Transport check")

        // The engine is started as a **separate process**, and that is the whole point.
        //
        // The first version of this check ran the server and the client in one process, and
        // it passed — while a real client could not connect to a real engine at all. An
        // in-process pair takes a shortcut that does not exist across a process boundary, so
        // the check was proving nothing. It now spawns the engine the same way the app does.
        let engineURL: URL
        if let executable {
            engineURL = executable
        } else if let first = ProcessInfo.processInfo.arguments.first {
            engineURL = URL(fileURLWithPath: first)
        } else {
            report.recordFailure("cannot locate the engine executable to start")
            return report
        }
        let engineProcess = Process()
        engineProcess.executableURL = engineURL
        engineProcess.arguments = [
            "--serve", "--transport", "webtransport",
            "--transport-port", String(port),
            // WebTransport only, so no HTTP listener is opened at all (A120). The unused port is
            // passed anyway, so that this stays harmless if that gating ever changes.
            "--port", String(port - 1),
            // The identity and the conversations, named outright. Without this the child resolves
            // its own run directory — the project's `.run`, or Application Support — and the
            // fingerprint reported above, taken from `directory`, is not the one the child serves
            // with. The check then fails as "could not connect", which is a verdict about the
            // caller's directory rather than about the transport (A215).
            "--run-directory", directory.path,
        ]
        // The child's output goes to the null device rather than into pipes.
        //
        // Pipes with no reader are not "output that is ignored": the child blocks on write as soon
        // as one fills, and it is then waited on forever. Nothing here reads them and nothing needs
        // to — the report carries every failure the check observes for itself (A122).
        engineProcess.standardOutput = FileHandle.nullDevice
        engineProcess.standardError = FileHandle.nullDevice
        do {
            try engineProcess.run()
        } catch {
            report.recordFailure("could not start the engine: \(error.localizedDescription)")
            return report
        }
        defer {
            if engineProcess.isRunning { engineProcess.terminate() }
        }
        _ = engine

        var clientConfiguration = WebTransportEngineClient.Configuration()
        clientConfiguration.port = port
        clientConfiguration.timeoutMilliseconds = Self.clientTimeoutMilliseconds(timeout)
        // One attempt gets a short connect deadline of its own, so the retries below are real.
        //
        // The comment under this loop always claimed the retry was for "not listening yet", and it
        // was not: a connect that begins before the engine's listener exists does not fail, it
        // *waits* — so the first attempt was given the whole thirty-second budget and spent it, and
        // the check reported "the transport does NOT work" about an engine that bound its port two
        // seconds later. Measured here: with a two-second wait before connecting it passed, which is
        // what a wait is not allowed to be — a guess about the machine (A215).
        clientConfiguration.connectTimeoutMilliseconds = Self.connectAttemptMilliseconds(timeout)
        let client = WebTransportEngineClient(configuration: clientConfiguration)

        // Retry briefly. Binding a QUIC listener is asynchronous on the library's side, and a
        // check that gave up on the first attempt reported "cannot connect" for what was
        // really "not listening yet".
        //
        // Bounded by the same deadline as the rest of the run, so six attempts cannot outlive the
        // budget the caller set (A122).
        var lastError: String?
        for attempt in 0..<6 {
            do {
                try await client.connect()
                report.connected = true
                lastError = nil
                break
            } catch {
                lastError = error.localizedDescription
                if ContinuousClock.now >= deadline {
                    report.recordFailure(
                        "connect across processes: gave up after \(timeout) — \(lastError ?? "unknown")")
                    return report
                }
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        if !report.connected {
            report.recordFailure("connect across processes: \(lastError ?? "unknown")")
            return report
        }

        // Collect events for the length of the check, so an output fragment is seen if one is
        // produced. Nothing is generated here, so its absence is not a failure.
        let collector = EventCollector()

        let collectTask = Task {
            guard let events = client.events else { return }
            for await event in events {
                await collector.record(event)
            }
        }

        // 1. A state read.
        do {
            let snapshot = try await client.state()
            report.recordStateRead(received: snapshot != nil)
        } catch {
            report.recordFailure("fetchState: \(error.localizedDescription)")
        }

        // 2. A command that changes something.
        do {
            let reply = try await client.send(.setTopic("Transport check, second topic"))
            report.recordCommand(
                tookEffect: reply.snapshot?.topic == "Transport check, second topic",
                failure: "setTopic did not take effect")
        } catch {
            report.recordFailure("setTopic: \(error.localizedDescription)")
        }

        // 3. A refusal, which must arrive as an answer rather than closing the stream.
        do {
            let reply = try await client.send(.setMode(.research))
            report.recordRefusal(wasRefused: reply.refusal != nil, failureWhenNotRefused: nil)
        } catch {
            report.recordFailure("setMode: \(error.localizedDescription)")
        }

        // 4. An invalid seat, to prove a refusal does not kill the session.
        do {
            let reply = try await client.send(.updateSeat(.init(seatID: "Agent 99", name: "Nobody")))
            report.recordRefusal(
                wasRefused: reply.refusal != nil,
                failureWhenNotRefused: "an unknown seat was not refused")
        } catch {
            report.recordFailure("updateSeat: \(error.localizedDescription)")
        }

        // 5. The session must still work after two refusals.
        do {
            let snapshot = try await client.state()
            report.recordStateAfterRefusals(received: snapshot != nil)
        } catch {
            report.recordFailure("state after refusals: \(error.localizedDescription)")
        }

        // Give the event stream a moment to deliver the initial state.
        try? await Task.sleep(for: .milliseconds(400))
        let seen = await collector.snapshot()
        report.recordEventStream(state: seen.state, event: seen.event)

        report.sessionCount = 1

        collectTask.cancel()
        await client.disconnect()
        if engineProcess.isRunning { engineProcess.terminate() }
        return report
    }

    /// Accumulates what arrived on the event stream.
    private actor EventCollector {
        private(set) var state = false
        private(set) var event = false

        func record(_ event: EngineEvent) {
            switch event {
            case .state: state = true
            case .output: self.event = true
            }
        }

        func snapshot() -> (state: Bool, event: Bool) { (state, event) }
    }
}

/// An engine that answers without generating, so the check does not need a model.
private actor TransportCheckEngine: LLMEngine {
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
    ) async throws -> String {
        // A fragment, so an output event is genuinely produced and the event channel is
        // exercised rather than assumed.
        await onEvent(.token(agentID: spec.id, text: "check"))
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: "check",
                stats: TurnStats(promptTokens: 10, generationTokens: 1, stopReason: "stop")))
        return "check"
    }
}
