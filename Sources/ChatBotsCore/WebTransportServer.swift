// ChatBotsCore — the engine as a WebTransport server
//
// The desktop app connects here rather than holding an engine, so the app, the website and a
// phone all see one conversation. The website does not use this: Caddy serves browsers over
// HTTP, which is what browsers speak and what Caddy is for.
//
// **How a session works.** A client opens two bidirectional streams.
//
//   1. The *request* stream, first. It sends one length-framed `EngineRequest` and reads back
//      one length-framed `EngineReply`, repeatedly, for the life of the session.
//   2. The *event* stream, which sends a single subscribe marker and then reads
//      newline-delimited `EngineEvent` until it closes. State after every change, and output
//      fragments as the models produce them.
//
// Two streams rather than one, because they carry different shapes: a request is a
// conversation with replies, an event feed is a push with none. Multiplexing them onto one
// stream would mean inventing a way to tell them apart, and would let a slow reply block an
// event.
//
// **A slow client cannot stall the engine.** Events are broadcast from the engine's own stream
// through a per-session continuation with a bounded buffer. A session that stops reading fills
// its buffer, is dropped, and reconnects; the model never waits on a socket. Without that, one
// stalled browser tab could freeze a conversation for everyone.

import Foundation
import WebTransport
import WebTransportNetworkRuntime

public enum WebTransportEngineError: LocalizedError {
    case cannotStart(String)

    public var errorDescription: String? {
        switch self {
        case .cannotStart(let detail):
            "The WebTransport engine could not start: \(detail)"
        }
    }
}

@MainActor
public final class WebTransportEngineServer {

    public struct Configuration: Sendable {
        /// Loopback only. The channel is between two processes on this machine.
        public var host = "127.0.0.1"
        /// The QUIC port. Distinct from the HTTP port, because they are different protocols.
        public var port: UInt16 = 7790
        public var path = "/chatbots"
        /// How many clients may be attached at once. More than a handful is a mistake rather
        /// than a load: this is one machine's interface talking to its own engine.
        public var maximumSessions = 8

        public init() {}
    }

    public let configuration: Configuration
    private let service: EngineService
    private let identity: EngineIdentity

    private var listener: WebTransportListeningServer?
    private var acceptTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    /// One continuation per subscribed session, so each has its own buffer and a stalled
    /// client costs only its own events.
    private var subscribers: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    public init(
        service: EngineService, identity: EngineIdentity, configuration: Configuration = .init()
    ) {
        self.service = service
        self.identity = identity
        self.configuration = configuration
    }

    /// The fingerprint a client must pin.
    public var fingerprintSHA256: Data { identity.fingerprintSHA256 }

    // MARK: - Lifecycle

    public func start() async throws {
        let serverConfiguration = WebTransportServerConfiguration(
            authority: "localhost",
            path: configuration.path,
            settingsValidation: .draft16Strict,
            // Loopback only, which is also what the self-signed identity requires. A
            // certificate nobody can verify must not be reachable from the network.
            localOnly: true,
            identity: .pkcs12(data: identity.pkcs12, passphrase: identity.passphrase),
            admission: .default,
            transportLimits: .default)

        do {
            listener = try await WebTransportServer(configuration: serverConfiguration)
                .listen(
                    on: WebTransportEndpoint(host: configuration.host, port: configuration.port))
        } catch {
            throw WebTransportEngineError.cannotStart(error.localizedDescription)
        }

        startEventPump()
        startTranscriptPump()
        acceptTask = Task { [weak self] in
            await self?.acceptLoop()
        }
    }

    public func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        eventTask?.cancel()
        eventTask = nil
        transcriptTask?.cancel()
        transcriptTask = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
        if let listener {
            await listener.shutdown()
        }
        listener = nil
    }

    /// Accept sessions until cancelled.
    private func acceptLoop() async {
        guard let listener else { return }
        while !Task.isCancelled {
            do {
                let session = try await listener.acceptSession()
                // Serving a session is not awaited: one client must not hold up the next.
                Task { [weak self] in
                    await self?.serve(session)
                }
            } catch {
                // A failed accept is not fatal — a client that disconnected mid-handshake
                // arrives here — but a loop that spins on a broken listener would be.
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: - Sessions

    private func serve(_ session: WebTransportSession) async {
        let id = UUID()
        // One stream, and that is not a simplification for its own sake: the transport
        // serialises stream operations on a session, and a second bidirectional stream does
        // not open. A single stream carrying tagged frames avoids both the deadlock and the
        // limitation. See EngineProtocol for the full account.
        guard let stream = try? await session.acceptBidirectionalStream() else { return }

        let (events, continuation) = AsyncStream<EngineEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256))
        subscribers[id] = continuation
        defer {
            continuation.finish()
            subscribers[id] = nil
        }

        // The current state first, so a client that has just connected can draw something
        // without waiting for a change.
        await send(.event(.state(service.snapshot())), on: stream)

        let writer = Task { [weak self] in
            guard let self else { return }
            for await event in events {
                if Task.isCancelled { return }
                await self.send(.event(event), on: stream)
            }
        }
        defer { writer.cancel() }

        var buffer = Data()
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await stream.receive()
            } catch {
                lastSessionError = error.localizedDescription
                return
            }
            if chunk.isEmpty { return }
            buffer.append(chunk)

            // Several frames can arrive together and one can be split across reads; the
            // framing holds partial messages until they are complete.
            while true {
                let result = try? LengthFraming.read(from: buffer)
                guard case .message(let payload, let remainder) = result else { break }
                buffer = remainder
                if let request = try? ProtocolCodec.decodeRequest(payload) {
                    let reply = await service.handle(request)
                    await send(.reply(reply), on: stream)
                } else if let frame = try? ProtocolCodec.decodeFrame(payload) {
                    // A client may tag its frames too; accept both spellings so the encoder is
                    // not something a caller has to get exactly right.
                    if let request = frame.asRequest {
                        let reply = await service.handle(request)
                        await send(.reply(reply), on: stream)
                    }
                }
            }
        }
    }

    /// Write one frame. Every write goes through here so there is one place that serialises
    /// them: replies and events reach the same stream from different tasks, and interleaving
    /// two writes would corrupt the framing.
    private func send(_ frame: EngineFrame, on stream: WebTransportBidirectionalStream) async {
        guard let encoded = try? ProtocolCodec.encode(frame) else { return }
        do {
            try await stream.send(LengthFraming.frame(encoded))
        } catch {
            // The client is gone; the reader will notice and end the session.
        }
    }

    /// Why the most recent session ended, for diagnostics.
    public private(set) var lastSessionError: String?

    // MARK: - Events

    /// Attach a session's event stream, and keep pushing until it goes away.
    ///
    /// Returns when the client stops reading or the stream ends. Cleanup is the caller's, in
    /// one place, so a session cannot leave a continuation behind.
    private func subscribe(id: UUID, to stream: WebTransportBidirectionalStream) async {
        // Bounded, and small. The buffer exists to absorb a burst, not to hold a backlog: a
        // client that falls this far behind is better off dropped and reconnected, because
        // the alternative is an unbounded memory growth in the engine or, worse, back-pressure
        // that reaches the model.
        let (events, continuation) = AsyncStream<EngineEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256))
        subscribers[id] = continuation

        // The current state first, so a client that has just connected can draw something
        // without waiting for the next change.
        if let encoded = try? ProtocolCodec.encode(EngineEvent.state(service.snapshot())) {
            try? await stream.send(LineFraming.frame(encoded))
        }
        for await event in events {
            guard let encoded = try? ProtocolCodec.encode(event) else { continue }
            do {
                try await stream.send(LineFraming.frame(encoded))
            } catch {
                // The client is gone or has stopped reading.
                return
            }
        }
    }

    /// Forward the engine's events to every subscribed session.
    private func startEventPump() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            // The engine hands its events to whoever is reading, and the API server may be
            // reading the same stream for the website. Both are consumers of the same
            // `events` sequence, which is a stored property built once, so neither takes it
            // from the other.
            for await event in self.service.events {
                if Task.isCancelled { return }
                guard let forwarded = Self.translate(event) else { continue }
                for continuation in self.subscribers.values {
                    continuation.yield(forwarded)
                }
            }
        }
    }

    /// Turn an engine event into a protocol event.
    ///
    /// Only the ones an interface can draw are forwarded. Everything else is already reflected
    /// in the state that follows each turn, and sending it would be traffic for nothing.
    private static func translate(_ event: TurnEvent) -> EngineEvent? {
        switch event {
        case .token(let agentID, let text):
            return .output(.init(agentID: agentID, text: text, kind: "token"))
        case .reasoning(let agentID, let text):
            return .output(.init(agentID: agentID, text: text, kind: "reasoning"))
        case .toolCall(let agentID, let name, let query):
            return .output(.init(agentID: agentID, text: "\(name)(\(query))", kind: "tool"))
        case .turnStarted(let agentID, _):
            return .output(.init(agentID: agentID, text: "", kind: "started"))
        case .turnFinished:
            // A turn ending is the moment the transcript changes, so the client is sent a
            // whole new state rather than being left to infer it.
            return nil
        default:
            return nil
        }
    }

    /// Push a whole fresh state whenever the shared log changes.
    ///
    /// The output deltas carry the text as it is written, but they are fragments: a client
    /// cannot rebuild the transcript, the statistics or the notices from them. The log
    /// changing is the moment those are worth re-sending, and it happens once per turn rather
    /// than once per token — so a client gets smooth text between turns and an authoritative
    /// state at each one.
    private func startTranscriptPump() {
        transcriptTask?.cancel()
        transcriptTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.service.transcriptUpdates {
                if Task.isCancelled { return }
                self.broadcastState()
            }
        }
    }

    /// Push a fresh state to every subscriber.
    ///
    /// Called after a turn, so a client's transcript is current rather than waiting for a
    /// change the stream does not carry.
    public func broadcastState() {
        let event = EngineEvent.state(service.snapshot())
        for continuation in subscribers.values { continuation.yield(event) }
    }

    public var sessionCount: Int { subscribers.count }
}
