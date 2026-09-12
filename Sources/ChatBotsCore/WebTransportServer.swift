// ChatBotsCore — the engine as a WebTransport server
//
// The desktop app connects here rather than holding an engine, so the app, the website and a
// phone all see one conversation. The website does not use this: Caddy serves browsers over
// HTTP, which is what browsers speak and what Caddy is for.
//
// **How a session works.** A client opens one bidirectional stream, and everything travels on
// it: length-framed `EngineRequest`s go up, and length-framed `EngineReply` and `EngineEvent`
// frames come back, told apart by the tag each frame carries rather than by which stream it
// arrived on.
//
// It was two streams — one for requests and their replies, one for the event feed — and that
// deadlocked on this transport: the library serialises stream operations on a session, so a
// server waiting to accept its second stream stops serving the first, while a client waiting
// for a reply never opens the second. Opening both up front failed differently: the second
// `openBidirectionalStream` does not open at all. One tagged stream removes that class of
// deadlock. `EngineProtocol.swift` has the full account.
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
        /// How many client connections the listener will accept before it stops accepting any.
        ///
        /// Large on purpose, and the reason is a defect in the transport rather than a load
        /// figure. A WebTransport session is a whole QUIC connection, and this library sets
        /// `newConnectionLimit` on its listener and then never cancels a connection — there is
        /// no cancellation anywhere in the runtime. So the limit is not a concurrency cap that
        /// recovers: it is a lifetime count of how many times clients may ever connect to this
        /// process. Measured: a fresh engine served exactly sixteen connects and then none,
        /// permanently, while still answering on its other channel.
        ///
        /// Sixteen is the library's default (`WebTransportAdmissionPolicy.default`) and it is
        /// far too few when the count never falls — the desktop app alone spends one connection
        /// per launch, plus one per startup probe. Raising it buys headroom; it does not fix the
        /// leak. When the underlying defect is corrected this should come back down to a real
        /// concurrency limit.
        public var maximumConnections = 4_096

        public init() {}
    }

    public let configuration: Configuration
    private let service: EngineService
    private let identity: EngineIdentity

    private var listener: WebTransportListeningServer?
    private var acceptTask: Task<Void, Never>?
    private var eventObserver: UUID?
    private var transcriptObserver: UUID?
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
            // The prompt-free path. A PKCS#12 bundle would be resolved with
            // `SecPKCS12Import`, which reaches into the login keychain and asks for its
            // password on every launch; the certificate-chain form builds the identity with
            // `SecIdentityCreate` from bytes we already hold, and touches nothing.
            identity: .certificateChain(
                chainDER: identity.certificateChainDER,
                privateKeyDER: identity.privateKeyDER,
                keyKind: .rsa(sizeInBits: 2048)),
            admission: WebTransportAdmissionPolicy(
                maxConcurrentConnections: configuration.maximumConnections),
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
        if let eventObserver {
            service.stopObservingEvents(eventObserver)
            self.eventObserver = nil
        }
        if let transcriptObserver {
            service.stopObservingTranscript(transcriptObserver)
            self.transcriptObserver = nil
        }
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
        if let listener {
            listener.shutdown()
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

        // This session is subscribed the moment its stream exists.
        //
        // There was a separate subscription step — the server waited to accept a second
        // stream before sending anything — and it was the reason the desktop app showed a
        // conversation that never updated. Nothing ever opened that second stream, so the
        // server waited forever while the client waited for events, and the only thing that
        // eventually moved the window was the polling safety net. Since replies and events are
        // told apart by their frame tag, no negotiation is needed at all.
        let (events, continuation) = AsyncStream<EngineEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256))
        subscribers[id] = continuation
        let writer = Task { [weak self] in
            guard let self else { return }
            for await event in events {
                if Task.isCancelled { return }
                await self.send(.event(event), on: stream)
            }
        }
        defer {
            writer.cancel()
            continuation.finish()
            subscribers[id] = nil
        }

        // The current state first, so a client that has just connected can draw something
        // without waiting for a change.
        await send(.event(.state(service.snapshot())), on: stream)

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

    /// Forward the engine's events to every subscribed session.
    private func startEventPump() {
        // An observer rather than a stream: the API server forwards these to the website at the
        // same time, and an `AsyncStream` would hand the whole sequence to whichever of them
        // asked first.
        eventObserver = service.observeEvents { [weak self] event in
            guard let self, let forwarded = Self.translate(event) else { return }
            for continuation in self.subscribers.values {
                continuation.yield(forwarded)
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
        transcriptObserver = service.observeTranscript { [weak self] _ in
            // Called on the main actor by the engine, so the broadcast is safe to do here.
            self?.broadcastState()
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
