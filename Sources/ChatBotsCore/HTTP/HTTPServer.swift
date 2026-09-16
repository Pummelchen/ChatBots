// ChatBotsCore — a small HTTP server, so the engine can serve both front ends
//
// The point of this is that there is exactly one conversation engine. The SwiftUI app and
// the web page are two front ends onto the same core, reached over HTTP on localhost, and
// neither of them owns the conversation. That is worth a hand-written server here rather
// than a framework: the surface is a dozen routes on a loopback interface, and adding a
// dependency for that would mean every front end's build carries it.
//
// Built on Network.framework and deliberately small. HTTP/1.1 only, no TLS (the traffic
// never leaves the machine), no keep-alive pipelining beyond what URLSession needs, and one
// connection per task. Everything is parsed by hand because everything is under our control
// — this is not a general-purpose server and does not pretend to be.

import Foundation
import Network

// MARK: - Messages

/// A parsed request. Only what this app needs: no chunked bodies, no multipart.
public final class HTTPServer: @unchecked Sendable {

    /// A route handler. Handlers are called on the main actor, so a `@MainActor` engine can
    /// be used from them without further synchronisation — which is exactly what keeps the
    /// conversation single-threaded while the network side is concurrent.
    public typealias Handler = @MainActor @Sendable (HTTPRequest) async -> HTTPResponse

    /// Something that attaches an event feed to a connected client.
    ///
    /// The server owns the connection, so it creates the stream and hands it over; the
    /// handler decides whether this request wants one at all and returns false if not.
    /// Attaches an event feed, and returns the events to send immediately — *after* the
    /// response head. Returning them rather than writing them is what guarantees the order:
    /// a browser reads the first line as a status line, so an event queued ahead of the head
    /// makes the whole response invalid.
    public typealias Streamer = @MainActor @Sendable (HTTPRequest, EventStream) -> [String]

    // The state the split-out halves of this type share with it. `private` is file-scoped in Swift, so
    // these members are internal rather than private: `HTTPServer+Connections.swift` runs the per-socket
    // lifecycle and `HTTPServer+Diagnostics.swift` answers the health endpoint out of the failure ring,
    // and both touch the fields below. Nothing outside this module can see them.
    private let port: UInt16
    let handler: Handler
    let streamer: Streamer?
    let queue = DispatchQueue(label: "chatbots.http", attributes: .concurrent)
    private var listener: NWListener?
    var connections: [ObjectIdentifier: NWConnection] = [:]
    let stateLock = NSLock()
    /// Streams that are still open, so they can be closed when the server stops.
    var streams: [EventStream] = []

    /// How long a connection may go without sending anything before it is dropped.
    ///
    /// A peer that opens a connection, sends a partial head and then stalls used to hold the
    /// connection, its buffer and its table entry until `stop()` — there was no deadline at
    /// all, so nothing reported it either. This is an *idle* deadline, re-armed on every chunk,
    /// rather than a wall-clock one from accept: a client genuinely uploading a large
    /// attachment must not be cut off for being slow, while one that has gone quiet is.
    public let requestTimeout: TimeInterval

    /// The most connections the server will hold at once.
    ///
    /// A cap has to be sized against what one connection can buffer, and that answer changed
    /// under this finding: `HTTPParser.maximumBodyBytes` is the base64 form of the
    /// documented 64 MB attachment limit — about 85.4 MB — so each accepted connection can now
    /// buffer roughly ten times the 8 MB it could when the missing cap was recorded. 32 is far
    /// above what this loopback-only server holds legitimately (the app's URLSession pool is a
    /// handful, and a browser keeps at most six connections per host plus one event stream per
    /// open page), and it bounds the worst case where every connection is simultaneously
    /// holding a maximum body to roughly 2.7 GB. The number is not larger because of that
    /// product, not because of what the app actually does.
    public let maximumConnections: Int

    /// The current idle deadline token for each connection, under `stateLock`.
    ///
    /// A token rather than the work item itself: re-arming replaces the token, and a deadline
    /// that has already fired for a previous token is a no-op rather than a cancellation of
    /// the connection it was armed for.
    var idleDeadlines: [ObjectIdentifier: UUID] = [:]

    /// Its own lock rather than `stateLock`, so that recording a failure is safe on every path —
    /// including the ones that already hold `stateLock` — without nesting one lock inside another.
    let failureLock = NSLock()
    var failures: [ConnectionFailure] = []

    /// How many connections have been refused for being over `maximumConnections`, under `stateLock`.
    var refusals = 0

    /// Whether the listener is actually accepting connections.
    ///
    /// Driven by the listener's own state rather than set when `start()` returns. `NWListener`
    /// reports a port it cannot take asynchronously, so the previous version marked itself
    /// running before it had bound anything: a second process on the same port looked like a
    /// server that was up, and the only sign otherwise was a line on stderr. Callers that need
    /// to know should `waitUntilReady()`.
    ///
    /// **Read under `stateLock`.** These two flags used to be plain properties written by the
    /// listener's state handler — which runs on the network queue — and read from
    /// `waitUntilReady` on whichever thread called it. On arm64 a single byte does not tear, so
    /// the suite passed; ThreadSanitizer still reported the race, and a compiler free to
    /// hoist the read out of the poll loop would leave a healthy server reporting itself as not
    /// ready on the startup path.
    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    /// Why the listener stopped, when it did. Guarded like `isRunning`.
    public var lastError: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return failure
    }

    /// The two flags, behind `stateLock`. Private so every access goes through the accessors
    /// above or the two writers below, and the invariant cannot be broken by accident.
    private var running = false
    private var failure: String?

    /// The listener reported itself ready.
    private func markRunning() {
        stateLock.lock()
        running = true
        stateLock.unlock()
    }

    /// The listener reported itself stopped, with the reason when there is one.
    ///
    /// `failure` is only overwritten when a reason is given, which preserves the original
    /// behaviour: a clean `cancelled` clears `isRunning` and leaves the last error readable.
    private func markStopped(failure reason: String? = nil) {
        stateLock.lock()
        running = false
        if let reason { failure = reason }
        stateLock.unlock()
    }

    /// Take ownership of an open event stream.
    ///
    /// Every read and write of `streams` goes through `stateLock` — here, in `stop()` and in
    /// `finish()` — because the last of those runs on the network queue while the other can run on
    /// the main actor.
    func addStream(_ stream: EventStream) {
        stateLock.lock()
        streams.append(stream)
        stateLock.unlock()
    }

    public init(
        port: UInt16,
        handler: @escaping Handler,
        streamer: Streamer? = nil,
        maximumConnections: Int = 32,
        requestTimeout: TimeInterval = 30
    ) {
        self.port = port
        self.handler = handler
        self.streamer = streamer
        // Clamped rather than trapped: a nonsensical cap is a caller's mistake, and the safe
        // reading of both of these is the strict one.
        self.maximumConnections = max(1, maximumConnections)
        self.requestTimeout = max(0.1, requestTimeout)
    }

    /// Start listening. Throws if the port cannot be taken, which the caller must report
    /// rather than silently serving nothing.
    public func start() throws {
        // Asked before binding, because a second process *can* take the same port:
        // `allowLocalEndpointReuse` below is set so a restart is not blocked by a socket in
        // TIME_WAIT, and BSD's SO_REUSEADDR also permits two live listeners on one address. The
        // second engine then binds happily and the two split incoming connections between them,
        // so the browser and the app quietly talk to different conversations. Checking first
        // turns that back into a failure the caller can report.
        if HTTPServer.isSomethingListening(on: port) {
            throw HTTPError.portInUse(port)
        }

        let parameters = NWParameters.tcp
        // Loopback only: this server drives a local chat app and has no business being
        // reachable from the network. The Caddy front end is the one that faces outwards.
        //
        // `integerLiteral` rather than the failable `init?(rawValue:)`: `port` is already the
        // raw value, and the literal initialiser cannot fail, so there is nothing to unwrap.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: port))
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.markRunning()
            case .failed(let error):
                self?.markStopped(failure: "\(error)")
                FileHandle.standardError.write(
                    Data("[ChatBots] http listener failed: \(error)\n".utf8))
            case .cancelled:
                self?.markStopped()
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Wait for the listener to bind, or for the attempt to fail.
    ///
    /// Returns false when the port could not be taken. Exists because "start() returned" and
    /// "the server is answering" are different facts, and code that treats them as one reports
    /// success on a port somebody else holds.
    public func waitUntilReady(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if isRunning { return true }
            if lastError != nil { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return isRunning
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        stateLock.lock()
        let open = streams
        streams.removeAll()
        let active = Array(connections.values)
        connections.removeAll()
        idleDeadlines.removeAll()
        stateLock.unlock()
        for stream in open { stream.close() }
        for connection in active { connection.cancel() }
        markStopped()
    }

    /// How many event streams the server is still holding open.
    ///
    /// An accessor rather than a comment because there was no way to observe the leak this
    /// describes: a stream whose client has gone but whose `open` is still true is exactly what
    /// `finish` prunes, and counting it is what the reaping test asserts. Read under
    /// `stateLock`, like every other access to `streams`.
    public var openStreamCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return streams.filter(\.isOpen).count
    }

    /// How many connections the server is still holding. Guarded like `openStreamCount`.
    public var connectionCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connections.count
    }

}
