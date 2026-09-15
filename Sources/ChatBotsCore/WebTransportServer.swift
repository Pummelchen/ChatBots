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
        /// How many client connections may be in flight at once.
        ///
        /// A real concurrency limit now, which it was not before. This library passed the value
        /// to `NetworkListener.newConnectionLimit`, and on macOS 26 that is a budget for the
        /// listener's whole life: a connection that ended never returned its slot, so a fresh
        /// engine served exactly sixteen connects and then none, permanently, while still
        /// answering on its other channel. This project carried 4096 here as headroom, and the
        /// comment said plainly that it was a workaround rather than a load figure.
        ///
        /// WebTransport 1.3.7 fixed it — the listener runs without that framework limit and the
        /// runtime counts in-flight connections itself, returning the slot when a session ends or
        /// an accept fails. So the number can be what it always claimed to be. Sixteen is the
        /// library's default and is far above anything this app holds: the desktop app keeps one
        /// connection for its lifetime, plus one more while the supervisor probes for an engine.
        /// It is a ceiling against a runaway client, not a figure anything should approach.
        public var maximumConnections = 16

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
    /// The live sessions and the tasks serving them, by session id.
    ///
    /// A session's serve task used to be untracked. `stop()` cancelled only the accept loop, so
    /// a connected client kept its receive loop, kept driving the shared `EngineService` and
    /// kept its admission slot; and the library documents `shutdown()` as severing nothing
    /// cleanly, so stopping the listener was not stopping the session either. Tracking them is
    /// what lets `stop()` end them.
    private var sessions: [UUID: WebTransportSession] = [:]
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    /// Bumped by every `stop()`, and captured by each accept loop.
    ///
    /// The loop spends most of its life suspended inside `acceptSession()`, so cancelling it does not
    /// stop an accept that is already in flight: the call can return a session after `stop()` has
    /// cleared the tables and is awaiting `session.close()` further down. That session would be
    /// registered with nothing left to cancel or close it — it would keep its admission slot and keep
    /// driving the engine after the server was stopped (A198). Comparing the generation this loop was
    /// started with against the current one is what tells it that its server went away, including the
    /// case where `start()` has since run again and a *new* listener owns the tables.
    private var generation = 0

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
        let generation = self.generation
        acceptTask = Task { [weak self] in
            await self?.acceptLoop(generation: generation)
        }
    }

    public func stop() async {
        // Before anything suspends. The close below does suspend, and every accept that is already
        // in flight has to see this server as gone from the moment `stop()` begins, not from the
        // moment it finishes.
        generation &+= 1
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

        // End the live sessions before the listener goes. Each serve task is a sibling of the
        // accept loop, not a child of it, so cancelling the accept task does nothing to them;
        // and `listener.shutdown()` severs nothing cleanly. Closing the session is what ends
        // the client's receive loop, releases its admission slot and stops it driving the
        // engine.
        //
        // Removing the entries here, synchronously and before the first close, is also how the
        // session gets exactly one closer: a serve task that ends on its own removes its own
        // entry first and closes the session only if it still owned it, so `stop()` and the
        // serve defer can never both close the same session. The library's `close()` sends a
        // final capsule on a stream it has already finished, which is not something to do
        // twice.
        let liveTasks = Array(sessionTasks.values)
        let liveSessions = Array(sessions.values)
        sessions.removeAll()
        sessionTasks.removeAll()
        for task in liveTasks { task.cancel() }
        for session in liveSessions { try? await session.close() }

        if let listener {
            listener.shutdown()
        }
        listener = nil
    }

    /// Accept sessions until cancelled, or until the server this loop belongs to is stopped.
    private func acceptLoop(generation: Int) async {
        guard let listener else { return }
        while !Task.isCancelled, generation == self.generation {
            do {
                let session = try await listener.acceptSession()
                // `stop()` may have run while this accept was suspended. It clears both tables
                // before it closes anything, so a session registered now would be owned by nobody:
                // never cancelled, never closed, still holding its admission slot and still driving
                // the engine (A198). This loop is then the only thing that knows the session exists,
                // so it is the one that closes it.
                guard !Task.isCancelled, generation == self.generation else {
                    try? await session.close()
                    return
                }
                // Serving a session is not awaited: one client must not hold up the next. The
                // task is tracked under the session's id so `stop()` can cancel and close it.
                let id = UUID()
                sessions[id] = session
                sessionTasks[id] = Task { [weak self] in
                    await self?.serve(session, id: id)
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

    private func serve(_ session: WebTransportSession, id: UUID) async {
        // Every exit from this method deregisters the session, and closes it only if this task
        // still owns it. That ownership test is what gives the session exactly one closer:
        // `stop()` removes the entries before it closes anything, so a task ending during or
        // after a stop finds its entry gone and leaves the close to `stop()`; a task ending on
        // its own removes the entry itself and is the one that closes. Without it both would
        // close, sending the final capsule twice.
        defer {
            subscribers[id] = nil
            let stillOwned = sessions.removeValue(forKey: id) != nil
            sessionTasks[id] = nil
            if stillOwned {
                Task { try? await session.close() }
            }
        }

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
                let result: LengthFraming.ReadResult
                do {
                    result = try LengthFraming.read(from: buffer)
                } catch let error as ProtocolError {
                    // A frame the framing refuses cannot be skipped: the length prefix is the
                    // only thing that says where the next frame begins, so every later frame is
                    // unreachable. Say why and close, rather than leaving a session that
                    // answers nothing for the rest of its life. This was `try?`, which
                    // discarded the error and did exactly that — and the cap was low enough
                    // that a legitimate large attachment reached it.
                    let reason = error.errorDescription ?? "the frame was refused"
                    lastSessionError = reason
                    await send(.reply(.failed(reason)), on: stream)
                    try? await session.close(reason: reason)
                    return
                } catch {
                    lastSessionError = error.localizedDescription
                    try? await session.close(reason: error.localizedDescription)
                    return
                }
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
    ///
    /// A frame the receiver would refuse is not put on the wire at all: framing it would put a
    /// length prefix before bytes that will never be read as a message, and the error names the
    /// size where it was made instead. `lastSessionError` carries the reason.
    private func send(_ frame: EngineFrame, on stream: WebTransportBidirectionalStream) async {
        let encoded: Data
        do {
            encoded = try ProtocolCodec.encode(frame)
        } catch {
            lastSessionError = "could not encode a frame: \(error.localizedDescription)"
            return
        }
        let framed: Data
        do {
            framed = try LengthFraming.frameChecked(encoded)
        } catch {
            lastSessionError = error.localizedDescription
            return
        }
        do {
            try await stream.send(framed)
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

    /// Sessions the server still owns. Used by the stop-race test (A198): after `stop()` returns this
    /// must be zero, whatever arrived while it was closing.
    var liveSessionCount: Int { sessions.count }
}
