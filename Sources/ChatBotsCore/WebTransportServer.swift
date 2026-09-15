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

        /// How long a new session has to open its stream and say something.
        ///
        /// The HTTP listener answers a connection that has not completed its request within
        /// `requestTimeout` with a 408 and closes it (A37). This is the transport's half of that rule, and
        /// it exists for the same reason: a client that connects and then says nothing holds one of
        /// `maximumConnections` slots, a subscriber and a session for as long as its connection ticks, so
        /// sixteen silent clients are the whole budget and the engine serves nobody else (A157).
        ///
        /// What it deliberately is **not** is an idle timeout for a working session. A client that has
        /// spoken is a conversation, and it is routinely silent for minutes at a time — it is *receiving*
        /// events, which is what the connection is for — so a deadline on quiet would end healthy sessions.
        /// The HTTP path draws the line in the same place: the deadline covers reading the request, not the
        /// conversation the connection is kept for.
        public var sessionStartupTimeout: TimeInterval = 30

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
    /// The sessions that have said something, so the startup deadline knows which ones have not. Main-actor
    /// state like the tables above: the serve loop and the watchdog that reads it are both on this actor.
    private var spokenSessions: Set<UUID> = []
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
        // A second start replaces the first, so the first is stopped rather than overwritten. `listener`
        // and `acceptTask` were assigned without that, so a server started twice could leave the first
        // listener bound with its accept loop still running and writing into the same tables — and nothing
        // could ever shut it down, because the reference that would have was gone (A157). On a fresh server
        // this is a no-op.
        await stop()

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
                keyKind: identity.keyKind.transportKind),
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
            spokenSessions.remove(id)
            let stillOwned = sessions.removeValue(forKey: id) != nil
            sessionTasks[id] = nil
            if stillOwned {
                Task { try? await session.close() }
            }
        }

        // The deadline for a session to become one. It covers the stream being opened *and* the first frame
        // arriving, because a client that does neither has never asked for anything and is holding a slot
        // the engine could be using (A157). `spokenSessions` is what the watchdog reads, and both it and
        // this loop are on the main actor, so there is no lock between them.
        let startupTimeout = Duration.seconds(configuration.sessionStartupTimeout)
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: startupTimeout)
            guard !Task.isCancelled, let self, !self.spokenSessions.contains(id) else { return }
            let seconds = Int(self.configuration.sessionStartupTimeout)
            let reason = "the session did not finish a frame within \(seconds) seconds"
            self.note(reason)
            try? await session.close(reason: reason)
        }
        defer { watchdog.cancel() }

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
                note("the session ended: \(error.localizedDescription)")
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
                } catch {
                    // A frame the framing refuses cannot be skipped, so this ends the session; the reasons
                    // are unwound in `refuseFraming` because this function is at its complexity budget.
                    await refuseFraming(error, on: stream, session: session)
                    return
                }
                guard case .message(let payload, let remainder) = result else { break }
                buffer = remainder
                // A whole frame, so the session is a conversation rather than a client that sent a byte and
                // stopped: the startup deadline no longer applies to it. It is *bytes* that make the server
                // serve a session — measured, one byte is enough to hold an admission slot and receive the
                // state pushes — so the deadline has to cover the frame being finished, not the first byte
                // arriving (A157).
                spokenSessions.insert(id)
                await answer(payload, on: stream)
            }
        }
    }

    /// Answer one decoded payload.
    ///
    /// Extracted from `serve`, which is at its complexity and length budgets: three of its four branches are
    /// about a payload the server cannot read, and they read better together than inside the read loop.
    private func answer(_ payload: Data, on stream: WebTransportBidirectionalStream) async {
        do {
            let request = try ProtocolCodec.decodeRequest(payload)
            let reply = await service.handle(request)
            await send(.reply(reply), on: stream)
        } catch let error as ProtocolError {
            // A client may tag its frames too; accept both spellings so the encoder is not something a caller
            // has to get exactly right.
            if let request = (try? ProtocolCodec.decodeFrame(payload))?.asRequest {
                let reply = await service.handle(request)
                await send(.reply(reply), on: stream)
                return
            }
            // Neither spelling read it. Unlike the framing refusal above, the length prefix is intact, so
            // later frames are still reachable and the session is still usable — but a client waiting for a
            // reply must not be left waiting for one that will never come. This was a `try?` that dropped the
            // payload and said nothing at all (A157).
            let reason = error.errorDescription ?? "the frame could not be read"
            note(reason)
            await send(.reply(.failed(reason)), on: stream)
        } catch {
            // `decodeRequest` reports a refusal as `ProtocolError`; anything else is a defect, and it is named
            // rather than dropped, which is the whole of this branch's reason for existing.
            let reason = "the frame could not be read: \(error.localizedDescription)"
            note(reason)
            await send(.reply(.failed(reason)), on: stream)
        }
    }

    /// Refuse a frame the framing would not read, and end the session.
    ///
    /// The length prefix is the only thing that says where the next frame begins, so every later frame is
    /// unreachable: the session cannot be left running, and it is answered first so the client is told why.
    /// This was a `try?`, which discarded the error and left a session that answered nothing for the rest of
    /// its life — and the cap was low enough that a legitimate large attachment reached it (A151 era, A157).
    private func refuseFraming(
        _ error: Error, on stream: WebTransportBidirectionalStream, session: WebTransportSession
    ) async {
        let reason =
            (error as? ProtocolError)?.errorDescription
            ?? "the frame could not be read: \(error.localizedDescription)"
        note(reason)
        await send(.reply(.failed(reason)), on: stream)
        try? await session.close(reason: reason)
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
            note("could not encode a frame: \(error.localizedDescription)")
            return
        }
        let framed: Data
        do {
            framed = try LengthFraming.frameChecked(encoded)
        } catch {
            note("could not frame a reply: \(error.localizedDescription)")
            return
        }
        do {
            try await stream.send(framed)
        } catch {
            // The client is gone; the reader will notice and end the session.
        }
    }

    /// One thing that ended a session, kept so a client that keeps failing can be diagnosed.
    public struct SessionError: Sendable, Equatable {
        /// What happened, in a sentence: a framing refusal, a session that never spoke, an encode failure.
        public var reason: String
        public var at: Date
    }

    /// Why the most recent session ended, for diagnostics.
    ///
    /// Derived from `recentSessionErrors` rather than kept as its own slot. It *was* a slot, and concurrent
    /// sessions overwrote one another's reasons, so a client that disconnected for two different reasons
    /// left only the second (A157) — and nothing read it at all.
    public var lastSessionError: String? { sessionErrors.first?.reason }

    /// The reasons recent sessions ended, newest first, bounded by `sessionErrorHistoryLimit`.
    ///
    /// A ring rather than a slot, which is what the HTTP listener does with its own failures (A151) and for
    /// the same reason: a diagnostic that remembers only the most recent event cannot describe a pattern,
    /// and "the app keeps disconnecting" is a pattern.
    public var recentSessionErrors: [SessionError] { sessionErrors }

    /// How many session endings are kept. Small: the reasons are a handful of sentences, and a session that
    /// fails in a loop must not grow the list.
    static let sessionErrorHistoryLimit = 8

    private var sessionErrors: [SessionError] = []

    /// Record why a session ended, keeping the newest `sessionErrorHistoryLimit`.
    ///
    /// Internal rather than private so the tests can drive the ring without a socket, which is how the HTTP
    /// listener's ring is tested too.
    func note(_ reason: String) {
        sessionErrors.insert(SessionError(reason: reason, at: .now), at: 0)
        if sessionErrors.count > Self.sessionErrorHistoryLimit {
            sessionErrors.removeLast(sessionErrors.count - Self.sessionErrorHistoryLimit)
        }
    }

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

extension EngineIdentity.KeyKind {
    /// This key kind as the transport spells it.
    ///
    /// The transport was configured with a hardcoded `.rsa(sizeInBits: 2048)` while the identity carried a
    /// key kind of its own that nothing read, so a key of any other size would have been described to
    /// `SecKeyCreateWithData` as 2048 bits — an error that names nothing (A155).
    var transportKind: WebTransportPrivateKeyKind {
        switch self {
        case .rsa(let sizeInBits): .rsa(sizeInBits: sizeInBits)
        }
    }
}
