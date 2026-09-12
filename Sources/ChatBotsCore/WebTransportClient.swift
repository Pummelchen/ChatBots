// ChatBotsCore — a client for the engine's WebTransport endpoint
//
// Used by the desktop app, and by the transport smoke test the installer runs. The website
// does not use this: Caddy serves browsers over HTTP.
//
// **On trust.** The transport is configured with the library's `localDevelopmentSelfSigned`
// policy, which is a loopback-only bypass of platform certificate validation — it does not
// verify our fingerprint. So the security of this channel rests on the socket being bound to
// loopback and on the operating system keeping other users out, not on the pin.
//
// That is a real limitation and worth stating rather than implying more: a malicious process
// running as the same user on this machine could present its own certificate and be accepted.
// It is accepted here because the alternative is no encrypted local channel at all, and
// because a process that can already run as this user can read the engine's files directly.
// The fingerprint is still exposed, reported and logged, so a mismatch is visible even though
// it is not enforced.
//
// If that trade is ever wrong, the fix is a trust callback that checks the certificate's
// SHA-256 against the stored fingerprint — which the library would need to expose.

import Foundation
import WebTransport
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
        public var timeoutMilliseconds: Int32 = 10_000

        public init() {}
    }

    public let configuration: Configuration
    private var session: WebTransportSession?
    private var stream: WebTransportBidirectionalStream?
    /// Replies waiting for their reader. A request is one writer and one reader, so a single
    /// pending reply is all there can be at a time.
    private var pendingReplies: [AsyncStream<EngineReply>.Continuation] = []
    private var readerTask: Task<Void, Never>?

    /// Events and states, in order, for as long as the connection lasts.
    private var eventContinuation: AsyncStream<EngineEvent>.Continuation?
    public private(set) var events: AsyncStream<EngineEvent>?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public var isConnected: Bool { session != nil }

    /// The engine's state as it was when this client connected.
    ///
    /// Collected by the first frame `connect` sends, which exists to put the stream prefix on
    /// the wire before the engine reads it. Exposed because it is the freshest thing the client
    /// has at that moment, and because a connection that never produced one did not really
    /// arrive: a client can be attached and still be told nothing.
    public private(set) var greeting: APISnapshot?

    // MARK: - Connecting

    public func connect() async throws {
        let clientConfiguration = WebTransportClientConfiguration(
            authority: "localhost",
            path: configuration.path,
            // Loopback only, and the identity is self-signed, so the platform trust path
            // cannot be used. See the note at the top of this file.
            trustPolicy: .localDevelopmentSelfSigned,
            settingsValidation: .draft16Strict,
            timeoutMilliseconds: configuration.timeoutMilliseconds)

        do {
            let client = WebTransportClient(configuration: clientConfiguration)
            let session = try await client.connect(
                to: WebTransportEndpoint(host: configuration.host, port: configuration.port))
            self.session = session
            // One stream. See EngineProtocol for why two deadlocked and the second would not
            // open at all.
            self.stream = try await session.openBidirectionalStream()

            let (events, continuation) = AsyncStream<EngineEvent>.makeStream(
                bufferingPolicy: .unbounded)
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

            // Then speak first, before anyone asks. This is not politeness, and it is not
            // optional.
            //
            // The transport writes the WebTransport stream prefix lazily, as part of the first
            // `send` on the stream: opening a stream puts no byte on the wire. The engine
            // accepts the stream and reads it exactly once, to consume that prefix. If nothing
            // has been written yet, that read finds zero bytes and fails the session outright —
            // "truncated: needed 1 bytes, available 0" — the engine's serve loop returns, and
            // the client is left holding a connection that will never carry anything.
            //
            // So a client that connects and then waits to be spoken to kills its own session,
            // and waiting is the natural thing to do. This looked intermittent because it was a
            // race: any frame sent in the same instant as connecting won it. That is why the
            // app sometimes drew a conversation and usually drew nothing.
            //
            // Asking for the state is the cheapest possible first frame, and its answer is
            // worth keeping: it is the same snapshot every front end draws when it opens.
            do {
                greeting = try await send(.fetchState).snapshot
            } catch {
                // Fail the connect rather than hand back a client whose channel is already
                // dead. A caller can retry a connection; it cannot retry a silent connection.
                readerTask?.cancel()
                readerTask = nil
                eventContinuation?.finish()
                eventContinuation = nil
                for reply in pendingReplies { reply.finish() }
                pendingReplies.removeAll()
                try? await session.close()
                self.session = nil
                self.stream = nil
                throw error
            }
        } catch {
            throw ClientError.cannotConnect(error.localizedDescription)
        }
    }

    public func disconnect() async {
        readerTask?.cancel()
        readerTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        for reply in pendingReplies { reply.finish() }
        pendingReplies.removeAll()
        if let session {
            try? await session.close()
        }
        session = nil
        stream = nil
    }

    // MARK: - Requests

    /// Send one request and wait for its reply.
    ///
    /// Replies and events share the stream, so the reader sorts them out and hands the reply
    /// to whoever is waiting for it. A reply arriving while nobody waits is dropped rather
    /// than queued: the protocol is one request at a time, so that can only be a stray from a
    /// request that already timed out.
    public func send(_ request: EngineRequest) async throws -> EngineReply {
        guard let stream, readerTask != nil else {
            throw ClientError.cannotConnect("not connected")
        }
        let (replies, continuation) = AsyncStream<EngineReply>.makeStream(
            bufferingPolicy: .bufferingNewest(4))
        pendingReplies.append(continuation)
        defer {
            continuation.finish()
            // One request is outstanding at a time, so removing the first is exact rather than
            // a best guess — and a continuation is a struct, so it cannot be compared by
            // identity anyway.
            if !pendingReplies.isEmpty { pendingReplies.removeFirst() }
        }

        do {
            try await stream.send(LengthFraming.frame(try ProtocolCodec.encode(request)))
        } catch {
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

        if let reply { return reply }
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
    public private(set) var readerError: String?

    /// Read frames until the stream ends, routing each to its destination.
    private func read(from stream: WebTransportBidirectionalStream) async {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await stream.receive()
            } catch {
                readerError = error.localizedDescription
                break
            }
            if chunk.isEmpty {
                readerError = readerError ?? "the engine closed the stream"
                break
            }
            buffer.append(chunk)

            while true {
                guard case .message(let payload, let remainder) = try? LengthFraming.read(
                    from: buffer)
                else { break }
                buffer = remainder
                guard let frame = try? ProtocolCodec.decodeFrame(payload) else { continue }
                switch frame {
                case .reply(let reply):
                    // The oldest waiting request gets it.
                    pendingReplies.first?.yield(reply)
                case .event(let event):
                    eventContinuation?.yield(event)
                case .request:
                    // Only the engine answers requests; a client receiving one is a
                    // misdirected frame.
                    continue
                }
            }
        }
        eventContinuation?.finish()
    }
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
