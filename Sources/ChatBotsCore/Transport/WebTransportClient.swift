// ChatBotsCore — a client for the engine's WebTransport endpoint
//
// Used by the desktop app, and by the transport smoke test the installer runs. The website
// does not use this: Caddy serves browsers over HTTP.
//
// **On trust.** The transport is configured with the library's `localDevelopmentSelfSigned`
// policy, which is a loopback-only bypass of platform certificate validation — it does not
// verify our fingerprint. So the security of this channel rests on the socket being bound to
// loopback and on the operating system keeping other users out, not on the fingerprint.
//
// That is a real limitation and worth stating rather than implying more: a malicious process
// running as the same user on this machine could present its own certificate and be accepted.
// It is accepted here because the alternative is no encrypted local channel at all, and
// because a process that can already run as this user can read the engine's files directly.
// The fingerprint is still exposed, reported and logged *by the engine*, but the client has no
// way to observe the peer certificate — the transport library exposes no accessor for it — so a
// mismatch is not detectable from here. What is reported is the engine's claim about the file it
// loaded, not a check the client made, and an impersonating loopback process would not be
// revealed by it.
//
// If that trade is ever wrong, the fix is a trust callback that checks the certificate's
// SHA-256 against the stored fingerprint — which the library would need to expose.

import Foundation
import WebTransportNetworkRuntime

@MainActor
public final class WebTransportEngineClient {

    public enum ClientError: LocalizedError {
        case cannotConnect(String)
        case streamFailed(String)
        /// The engine understood the request and declined it. Distinct from a transport
        /// failure, because the reason is something to show a user rather than retry.
        case refused(String)

        public var errorDescription: String? {
            switch self {
            case .cannotConnect(let detail):
                "Could not connect to the conversation engine: \(detail)"
            case .streamFailed(let detail):
                "The connection to the conversation engine failed: \(detail)"
            case .refused(let reason): reason
            }
        }
    }

    public struct Configuration: Sendable {
        public var host = "127.0.0.1"
        public var port: UInt16 = 7790
        public var path = "/chatbots"
        /// How long one request waits for its reply.
        ///
        /// This is a *request* deadline: it bounds a command the user is waiting on. It used
        /// to double as the reader's idle receive timeout as well, which is a different thing
        /// — see `idleTimeoutMilliseconds`.
        public var timeoutMilliseconds: Int32 = 10_000
        /// How long the reader may go without a frame before it calls the stream dead.
        ///
        /// Its own value, not the request deadline. The transport exposes one timeout per
        /// session and applies it to connect, send and receive alike; passing the request
        /// deadline here meant a stream that was merely *quiet* for longer than one request
        /// killed the reader. Document conversion now runs off the main actor, so a
        /// conversion can legitimately exceed ten seconds, and the command then reported a
        /// connection failure while `isConnected` stayed true.
        ///
        /// It is a backstop, not the only liveness check: a genuinely dead peer is still
        /// detected — the QUIC connection closes on its own idle timeout, and any receive
        /// error or closed stream fails the reader immediately. Nothing legitimate is silent
        /// for this long, so choosing a value well beyond any single request does not hide a
        /// dead channel.
        public var idleTimeoutMilliseconds: Int32 = 120_000

        /// How long one *connect* may take, when that should differ from the request deadline.
        ///
        /// A connect that begins before the engine's listener exists does not fail — it waits, for
        /// as long as it is allowed to. So an attempt given the whole request deadline spends the
        /// whole deadline, and a caller that retries gets exactly one attempt instead of the several
        /// it asked for. That is how the installer's smoke test reported "the transport does NOT
        /// work" on a machine whose engine bound its port two seconds later: the retry loop
        /// was there, and the first attempt ate the budget.
        ///
        /// `nil` keeps the request deadline, which is right for a caller that connects once and is
        /// content to wait. It is only a caller that retries that needs a shorter one.
        public var connectTimeoutMilliseconds: Int32?

        public init() {}
    }

    public let configuration: Configuration
    /// The session and its one stream, at the transport runtime layer.
    ///
    /// The runtime rather than the convenience wrapper, because only the runtime's
    /// `openBidirectionalStream(timeoutMilliseconds:)` lets one session carry two different
    /// deadlines: the connect gets the request deadline, and the stream gets the idle one.
    /// The wrapper's `openBidirectionalStream()` has no override, so the stream would inherit
    /// the connect deadline again — which is the borrowed timeout this fixes.
    private var session: WebTransportNetworkSession?
    private var stream: WebTransportNetworkBidirectionalStream?
    /// The requests waiting for their replies, oldest first.
    ///
    /// There is at most one *live* entry: `send` takes the request slot before it registers, so
    /// the queue position is the request identity. An entry whose sender has given up stays in
    /// the queue marked abandoned, so the reply still owed to it is consumed and discarded
    /// rather than handed to the next request.
    var pendingReplies: [PendingRequest] = []
    private var readerTask: Task<Void, Never>?

    /// One request waiting for its reply.
    ///
    /// A class rather than a bare continuation because a send that gives up waiting has to be
    /// told apart from its reply: a continuation is a struct and cannot be compared or marked.
    final class PendingRequest {
        let request: EngineRequest
        let continuation: AsyncStream<EngineReply>.Continuation
        /// The sender stopped waiting. Its reply is still owed and will be consumed and dropped.
        var abandoned = false

        init(request: EngineRequest, continuation: AsyncStream<EngineReply>.Continuation) {
            self.request = request
            self.continuation = continuation
        }
    }

    /// The one-request-wide channel, and the sends waiting for it. See `RequestSlot`.
    private let requestSlot = RequestSlot()

    /// Events and states, in order, for as long as the connection lasts.
    var eventContinuation: AsyncStream<EngineEvent>.Continuation?
    public private(set) var events: AsyncStream<EngineEvent>?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public var isConnected: Bool { session != nil }

    /// The engine's state as it was when this client connected.
    ///
    /// The reply to the first frame `connect` sends. That frame is not there to work around a
    /// transport defect — see the comment in `connect()`, and WebTransport#24 — it is there
    /// because the engine does not serve the stream, and so pushes nothing, until a byte arrives.
    /// Its answer is the snapshot every front end draws when it opens.
    public private(set) var greeting: APISnapshot?

    // MARK: - Connecting

    public func connect() async throws {
        // A client that already holds a session must not begin a second one: the first would be
        // left live on the server, holding an admission slot with nothing reading it. This is
        // the same invariant as the failed-connect cleanup below, applied to a retry — the app
        // reconnects on failure, and every attempt that leaked a session cost the next one.
        if session != nil {
            await teardown()
        }
        // A fresh attempt has no confirmed greeting and no reason to carry the last channel's
        // failure: a stale `readerError` would make `send` report a dead reader on a session
        // that is perfectly alive.
        greeting = nil
        readerError = nil

        do {
            // Loopback only, and the identity is self-signed, so the platform trust path
            // cannot be used. See the note at the top of this file.
            let client = WebTransportQUICClient(trustPolicy: .localDevelopmentSelfSigned)
            // The connect gets the request deadline unless the caller asked for a separate one.
            // This is the same handshake the convenience wrapper performs, with the one difference
            // that matters here: the session timeout is not the reader's idle deadline, because the
            // stream below overrides it. A caller that retries sets
            // `connectTimeoutMilliseconds`, so one attempt cannot spend the whole budget before the
            // engine has bound its listener.
            let session = try await client.connectSession(
                to: WebTransportNetworkEndpoint(
                    host: configuration.host, port: configuration.port),
                authority: "localhost",
                path: configuration.path,
                origin: nil,
                protocols: [],
                optimisticCapsules: [],
                settingsValidation: .draft16Strict,
                timeoutMilliseconds: configuration.connectTimeoutMilliseconds
                    ?? configuration.timeoutMilliseconds)

            do {
                self.session = session
                // One stream. See EngineProtocol for why two deadlocked and the second would not
                // open at all.
                //
                // The override is the whole point: this stream's receive and
                // send use the idle deadline, so a silent-but-alive engine — a document
                // conversion that takes longer than one request — no longer kills the reader.
                self.stream = try await session.openBidirectionalStream(
                    timeoutMilliseconds: configuration.idleTimeoutMilliseconds)

                // The same depth the server keeps, from the shared constant: this was `.unbounded`, which
                // made the bounding one-sided — the server dropped its oldest 256 while the client retained
                // every event it was sent, so a consumer that stopped draining (a stalled interface, a
                // paused window) grew the client without limit.
                let (events, continuation) = AsyncStream<EngineEvent>.makeStream(
                    bufferingPolicy: .bufferingNewest(ProtocolLimits.eventBufferDepth))
                self.events = events
                self.eventContinuation = continuation

                // Reading starts immediately: the engine sends the current state as soon as the
                // stream exists, and a client that waited to be told it could read would never
                // see it.
                if let stream = self.stream {
                    readerTask = Task { [weak self] in
                        await self?.read(from: stream)
                    }
                }

                // Then speak first — but not for the reason this used to give.
                //
                // The old justification was a race that does not exist: the theory was that the
                // transport writes the stream prefix lazily, the engine reads it exactly once, and a
                // read of zero bytes fails the session with "truncated: needed 1 bytes, available 0".
                // WebTransport#24 settled it by measurement — an inbound stream is not even delivered
                // to the handler until its first byte arrives, and the read waits for at least one
                // byte by default, so an *open* stream with nothing on the wire cannot produce that
                // error. The message came from a peer that *ended* a stream without writing to it,
                // which the library now names instead.
                //
                // The frame stays for the reason that survived: the engine does not see this stream —
                // and so does not serve the session or push the state a front end draws — until a
                // byte arrives. Saying something is how a client subscribes. `.fetchState` is the
                // cheapest thing to say, and its reply is the greeting every front end opens with.
                //
                // That is also the one thing to remember if this line is ever re-examined: removing it
                // does not break the transport, it silently stops the pushes, which is what the
                // "a change is pushed to an attached client" test is there to catch.
                greeting = try await send(.fetchState).snapshot
            } catch {
                // `self.session` may already be assigned here — `openBidirectionalStream()` can
                // throw after the handshake succeeded, and a greeting can fail — so the session
                // is closed and cleared on *both* failures. Without this the client reported
                // `isConnected` (`session != nil`) while it had no stream and no reader, every
                // command threw "not connected", and the server kept an admission slot for a
                // session nothing would read. A caller can retry a failed connection; it cannot
                // retry a silent one.
                await teardown()
                throw error
            }
        } catch {
            throw ClientError.cannotConnect(ErrorText.describe(error))
        }
    }

    public func disconnect() async {
        await teardown()
    }

    /// Drop the session, its reader and every waiter, and close the transport session.
    ///
    /// The one path that stops using a session, so a failed connect, a disconnect and a
    /// reconnect all leave the client in the same state: `session` nil, which is what
    /// `isConnected` reports, and no server-side session to serve or hold a slot for.
    private func teardown() async {
        readerTask?.cancel()
        readerTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        for reply in pendingReplies { reply.continuation.finish() }
        pendingReplies.removeAll()
        if let session {
            // Bounded by the request deadline, not the idle one: closing is a command, and a
            // client tearing down should not sit in it for two minutes.
            try? await session.close(
                applicationErrorCode: 0,
                timeoutMilliseconds: configuration.timeoutMilliseconds)
        }
        session = nil
        stream = nil
    }

    // MARK: - Requests

    /// Send one request and wait for its reply.
    ///
    /// Replies and events share the stream, so the reader sorts them out and hands each reply
    /// to the request it answers. Replies are matched to requests, not to queue position: the
    /// request slot below makes the registering order the wire order, and the entry holds the
    /// request so a reply can be checked against it. A reply that matches nothing is a reader
    /// failure with that reason, not a wait that runs out.
    public func send(_ request: EngineRequest) async throws -> EngineReply {
        await requestSlot.acquire()
        defer { requestSlot.release() }
        guard let stream = self.stream, readerTask != nil else {
            throw ClientError.cannotConnect("not connected")
        }

        let (replies, continuation) = AsyncStream<EngineReply>.makeStream(
            bufferingPolicy: .bufferingNewest(4))
        let pending = PendingRequest(request: request, continuation: continuation)
        pendingReplies.append(pending)
        defer {
            continuation.finish()
            // A reply the reader has already delivered removed this entry, so marking it here
            // is then harmless. If the reader has *not* delivered it, the reply is still owed
            // and the entry deliberately stays in the queue: consuming and discarding that
            // reply is what keeps the next request's reply next. Removing the first entry, as
            // this used to, let a late reply be handed to whichever send happened to be
            // waiting when it arrived.
            pending.abandoned = true
        }

        do {
            try await stream.send(LengthFraming.frameChecked(try ProtocolCodec.encode(request)))
        } catch {
            // A message over the cap fails here, with its size named, rather than being framed
            // for a receiver that would refuse it and leave the session unreadable. Nothing
            // reached the wire, so no reply is owed: remove the entry rather than leave a
            // phantom at the head that would swallow the next real reply.
            pendingReplies.removeAll { $0 === pending }
            throw ClientError.streamFailed(error.localizedDescription)
        }

        // The wait is bounded, and that is not a nicety.
        //
        // A request whose reply never arrives used to wait forever, and the cost of that is not
        // a slow request — it is an interface that stops responding with nothing to show for
        // it. A command is the only thing that can move the engine, so a `send` that never
        // returns means every control in the app is silently dead: pressing Start changes
        // nothing, no error appears, and the only symptom is a window that looks fine. A
        // timeout turns that into a sentence the user can read.
        //
        // A reply also has to lose the race when the reader has already stopped, because the
        // engine could not answer a channel it is no longer reading.
        let reply: EngineReply?
        do {
            reply = try await withTimeout(.milliseconds(Int64(configuration.timeoutMilliseconds))) {
                for await reply in replies { return reply }
                return nil
            }
        } catch {
            if let readerError {
                throw ClientError.streamFailed("live updates stopped: \(readerError)")
            }
            throw ClientError.streamFailed(
                "the engine did not answer within \(configuration.timeoutMilliseconds)ms")
        }

        if let reply {
            // `.failed` is the engine saying why it could not answer, and the session is
            // closing. Raised as the same typed failure as a dropped reader so a caller cannot
            // mistake it for a normal reply and carry on.
            if case .failed(let reason) = reply {
                throw ClientError.streamFailed(reason)
            }
            return reply
        }
        if let readerError {
            throw ClientError.streamFailed("live updates stopped: \(readerError)")
        }
        throw ClientError.streamFailed("the engine closed the connection")
    }

    /// Send a file to the engine, which extracts it and holds it as source material.
    ///
    /// The bytes go over the request channel rather than the event channel: it is a one-shot
    /// command with a reply, and it can be large. The engine writes them to a temporary file
    /// and reads that, so there is one implementation of what a document contains — the
    /// engine's — instead of one on each side that could disagree.
    ///
    /// Throws when the engine refuses, which it does for an unsupported type, an image no seat
    /// can see, or too many attachments. The reason is what should be shown to the user.
    public func addAttachment(filename: String, contents: Data) async throws {
        let reply = try await send(.addAttachment(filename: filename, contents: contents))
        if case .refused(let reason) = reply {
            throw ClientError.refused(reason)
        }
    }

    /// Ask for the current state, which is also how a client confirms it is connected.
    @discardableResult
    public func state() async throws -> APISnapshot? {
        try await send(.fetchState).snapshot
    }

    // MARK: - Events

    /// Why the reader stopped, if it stopped rather than being cancelled. A reader that exits
    /// silently leaves a connected-looking client that never updates, which is the hardest
    /// kind of failure to notice.
    public internal(set) var readerError: String?

    /// How many frames the engine sent that this build could not read, and why the last one could not be.
    ///
    /// Not fatal, deliberately: the framing is intact, so the stream stays aligned and the reader carries
    /// on — and an app may be attached to an engine of another build, where a frame it does not know is a
    /// version difference rather than a broken connection. This was `try?` and `continue`, which dropped
    /// the payload with no trace at all: the same class of silent drop, and the same shape the server
    /// fixed once already.
    public internal(set) var unreadableFrames = 0
    public internal(set) var lastUnreadableFrame: String?

}

/// Run `operation`, giving up after `timeout`.
///
/// A timeout is a failure and not a result, so the operation is cancelled and the caller is told
/// it ran out of time. The operation has to be cancellation-aware for its resources to be
/// released promptly, which the one caller here is: it is iterating an `AsyncStream`, and those
/// end on cancellation.
///
/// Written by hand rather than taken from the transport, whose equivalent is internal — and this
/// deliberately does not swallow the operation's own error, so a failure that arrives before the
/// deadline is reported as itself.
func withTimeout<T: Sendable>(
    _ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError(seconds: timeout)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw TimeoutError(seconds: timeout)
        }
        return first
    }
}

struct TimeoutError: Error {
    let seconds: Duration
}
