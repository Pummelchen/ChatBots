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

        public var errorDescription: String? {
            switch self {
            case .cannotConnect(let detail):
                "Could not connect to the conversation engine: \(detail)"
            case .streamFailed(let detail):
                "The connection to the conversation engine failed: \(detail)"
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

        for await reply in replies {
            return reply
        }
        throw ClientError.streamFailed("the engine closed the connection")
    }

    /// Ask for the current state, which is also how a client confirms it is connected.
    @discardableResult
    public func state() async throws -> APISnapshot? {
        try await send(.fetchState).snapshot
    }

    // MARK: - Events

    /// Read frames until the stream ends, routing each to its destination.
    private func read(from stream: WebTransportBidirectionalStream) async {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await stream.receive()
            } catch {
                break
            }
            if chunk.isEmpty { break }
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
