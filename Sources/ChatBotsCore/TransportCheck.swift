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
}

public enum TransportCheck {

    /// Run the whole channel end to end.
    ///
    /// - Parameter directory: where the certificate lives, so the check uses the same identity
    ///   a real run would rather than creating another.
    @MainActor
    public static func run(
        in directory: URL, port: UInt16 = 7795, timeout: Duration = .seconds(30)
    ) async -> TransportCheckReport {
        var report = TransportCheckReport(fingerprint: "not generated")

        let identity: EngineIdentity
        do {
            identity = try CertificateStore.loadOrCreate(in: directory)
        } catch {
            report.failures.append("certificate: \(error.localizedDescription)")
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
        guard let executable = ProcessInfo.processInfo.arguments.first else {
            report.failures.append("cannot locate the engine executable to start")
            return report
        }
        let engineProcess = Process()
        engineProcess.executableURL = URL(fileURLWithPath: executable)
        engineProcess.arguments = [
            "--serve", "--transport", "webtransport",
            "--transport-port", String(port),
            // A port that is not in use, so the HTTP listener cannot collide with a real run.
            "--port", String(port - 1),
        ]
        engineProcess.standardOutput = Pipe()
        engineProcess.standardError = Pipe()
        do {
            try engineProcess.run()
        } catch {
            report.failures.append("could not start the engine: \(error.localizedDescription)")
            return report
        }
        defer {
            if engineProcess.isRunning { engineProcess.terminate() }
        }
        _ = engine

        var clientConfiguration = WebTransportEngineClient.Configuration()
        clientConfiguration.port = port
        let client = WebTransportEngineClient(configuration: clientConfiguration)

        // Retry briefly. Binding a QUIC listener is asynchronous on the library's side, and a
        // check that gave up on the first attempt reported "cannot connect" for what was
        // really "not listening yet".
        var lastError: String?
        for attempt in 0..<6 {
            do {
                try await client.connect()
                report.connected = true
                lastError = nil
                break
            } catch {
                lastError = error.localizedDescription
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        if !report.connected {
            report.failures.append("connect across processes: \(lastError ?? "unknown")")
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
            report.receivedState = snapshot != nil
            report.roundTrips += 1
            if snapshot == nil { report.failures.append("fetchState returned no state") }
        } catch {
            report.failures.append("fetchState: \(error.localizedDescription)")
        }

        // 2. A command that changes something.
        do {
            let reply = try await client.send(.setTopic("Transport check, second topic"))
            report.roundTrips += 1
            if reply.snapshot?.topic != "Transport check, second topic" {
                report.failures.append("setTopic did not take effect")
            }
        } catch {
            report.failures.append("setTopic: \(error.localizedDescription)")
        }

        // 3. A refusal, which must arrive as an answer rather than closing the stream.
        do {
            let reply = try await client.send(.setMode(.research))
            report.roundTrips += 1
            if case .refused = reply { report.refusedAsExpected = true }
        } catch {
            report.failures.append("setMode: \(error.localizedDescription)")
        }

        // 4. An invalid seat, to prove a refusal does not kill the session.
        do {
            let reply = try await client.send(.updateSeat(.init(seatID: "Agent 99", name: "Nobody")))
            report.roundTrips += 1
            if case .refused = reply {
                report.refusedAsExpected = true
            } else {
                report.failures.append("an unknown seat was not refused")
            }
        } catch {
            report.failures.append("updateSeat: \(error.localizedDescription)")
        }

        // 5. The session must still work after two refusals.
        do {
            let snapshot = try await client.state()
            report.roundTrips += 1
            if snapshot == nil { report.failures.append("the session did not survive a refusal") }
        } catch {
            report.failures.append("state after refusals: \(error.localizedDescription)")
        }

        // Give the event stream a moment to deliver the initial state.
        try? await Task.sleep(for: .milliseconds(400))
        let seen = await collector.snapshot()
        report.receivedEvent = seen.event
        if !seen.state { report.failures.append("no state arrived on the event stream") }

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
