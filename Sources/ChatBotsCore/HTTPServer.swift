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
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Decode the body as JSON, the only content type this server accepts.
    public func json<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: body)
    }

    public func string(_ name: String) -> String? {
        query[name]
    }

    public func int(_ name: String) -> Int? {
        query[name].flatMap(Int.init)
    }
}

/// A response. Either a complete body or a stream, which is what the event feed needs.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    public var headers: [String: String]

    public init(
        status: Int = 200,
        contentType: String = "application/json; charset=utf-8",
        body: Data = Data(),
        headers: [String: String] = [:]
    ) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.headers = headers
    }

    public static func json(_ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        // Dates as ISO-8601 so the web page can format them itself rather than being handed
        // a number whose epoch only this app knows.
        encoder.dateEncodingStrategy = .iso8601
        do {
            return HTTPResponse(body: try encoder.encode(value))
        } catch {
            return .error("could not encode the response: \(error.localizedDescription)")
        }
    }

    public static func text(_ value: String, contentType: String = "text/plain; charset=utf-8")
        -> HTTPResponse
    {
        HTTPResponse(contentType: contentType, body: Data(value.utf8))
    }

    public static func html(_ value: String) -> HTTPResponse {
        .text(value, contentType: "text/html; charset=utf-8")
    }

    public static func error(_ message: String, status: Int = 500) -> HTTPResponse {
        .json(["error": message], status: status)
    }

    public static func json(_ value: [String: String], status: Int) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONEncoder().encode(value)) ?? Data())
    }

    /// The status line's reason phrase. Kept short; nothing depends on it.
    public var reason: String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        default: "OK"
        }
    }

    /// The bytes to put on the wire, headers included.
    public func serialised(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        // The page is served from the same origin in the Caddy setup, but a browser
        // reload during development sometimes hits the port directly.
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

// MARK: - Parsing

/// Request parsing, kept separate from the socket so it can be tested directly.
public enum HTTPParser {

    /// The largest request this server will accept. A conversation export is small and the
    /// only bodies are commands and attachment lists, so anything larger is a mistake.
    public static let maximumBodyBytes = 8 * 1024 * 1024

    public struct Incomplete: Error {}

    /// Parse a complete request head plus whatever body has arrived.
    ///
    /// Throws `Incomplete` when more bytes are needed, which is the normal case for a
    /// request arriving in pieces.
    public static func parse(_ data: Data) throws -> HTTPRequest {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw Incomplete()
        }
        let headData = data[data.startIndex..<headerEnd.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else {
            throw HTTPError.malformed("the request head was not valid UTF-8")
        }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPError.malformed("empty request") }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else {
            throw HTTPError.malformed("could not read the request line")
        }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Repeated headers are joined, which is harmless for the ones we read.
            headers[name.lowercased()] = headers[name.lowercased()].map { "\($0), \(value)" } ?? value
        }

        let declaredLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard declaredLength <= maximumBodyBytes else {
            throw HTTPError.tooLarge
        }
        let bodyStart = headerEnd.upperBound
        let available = data.count - data.distance(from: data.startIndex, to: bodyStart)
        guard available >= declaredLength else { throw Incomplete() }
        let body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: declaredLength)])

        // Split the path from the query, and decode percent escapes so a topic with
        // spaces or non-ASCII can travel in a URL.
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = percentDecoded(String(parts.first ?? ""))
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                query[percentDecoded(String(kv.first ?? ""))] =
                    kv.count > 1 ? percentDecoded(String(kv[1])) : ""
            }
        }

        return HTTPRequest(
            method: method, path: path, query: query, headers: headers, body: body)
    }

    /// Percent-decoding that leaves a malformed escape alone rather than dropping it.
    static func percentDecoded(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
    }
}

public enum HTTPError: LocalizedError {
    case malformed(String)
    case tooLarge
    case portInUse(UInt16)

    public var errorDescription: String? {
        switch self {
        case .malformed(let reason): "Malformed request: \(reason)"
        case .tooLarge: "Request body is too large"
        case .portInUse(let port): "Port \(port) is already in use"
        }
    }
}

// MARK: - Server

/// Serves a routing closure over HTTP on a port, on the loopback interface only.
///
/// `@unchecked Sendable` with the parts written down, because the compiler cannot check them:
/// `connections`, `streams`, `running` and `failure` are read and written under `stateLock`, and
/// no lock is held across a call that could re-enter this type. `listener` is only touched by
/// `start()` and `stop()`, which the owning actor calls.
///
/// ThreadSanitizer is what verifies the claim rather than the comment: it reported a data race on
/// `isRunning` while every one of 555 tests passed, and inspection alongside it found `streams`
/// being appended without the lock that every other access to it takes.
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

    /// A live event feed for one connection.
    ///
    /// `@unchecked Sendable` because its one piece of mutable state, `open`, is confined to
    /// `lock`: `send`, `close`, `isOpen` and `markClosed` each take `lock` before reading or
    /// writing it, so no access site can see a torn or stale value. `connection` is a `let`
    /// and every call on it is handed to the Network framework, which serialises the work on
    /// the queue the connection was started on. What keeps the confinement true is that `open`
    /// is private and the type has no other `var`, so those four accessors are the only code
    /// that can reach it.
    public final class EventStream: @unchecked Sendable {
        private let connection: NWConnection
        private let lock = NSLock()
        private var open = true

        init(connection: NWConnection) {
            self.connection = connection
        }

        /// Write one server-sent event. Silently ignored once the client has gone.
        public func send(_ payload: String, event: String? = nil) {
            lock.lock()
            defer { lock.unlock() }
            guard open else { return }
            var frame = ""
            if let event { frame += "event: \(event)\n" }
            // A data field cannot contain a bare newline, so a multi-line payload is split
            // across several `data:` lines as the format requires.
            for line in payload.split(separator: "\n", omittingEmptySubsequences: false) {
                frame += "data: \(line)\n"
            }
            frame += "\n"
            connection.send(
                content: Data(frame.utf8), completion: .contentProcessed { _ in })
        }

        public func close() {
            lock.lock()
            defer { lock.unlock() }
            guard open else { return }
            open = false
            connection.cancel()
        }

        var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return open
        }

        /// Called when the socket closes, so nothing is written to a departed client.
        func markClosed() {
            lock.lock()
            defer { lock.unlock() }
            open = false
        }

        /// Whether this stream belongs to a given connection.
        func matches(_ other: NWConnection) -> Bool { connection === other }
    }

    private let port: UInt16
    private let handler: Handler
    private let streamer: Streamer?
    private let queue = DispatchQueue(label: "chatbots.http", attributes: .concurrent)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let stateLock = NSLock()
    /// Streams that are still open, so they can be closed when the server stops.
    private var streams: [EventStream] = []

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
    /// the suite passed; ThreadSanitizer still reported the race (A14), and a compiler free to
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
    /// Every read and write of `streams` goes through `stateLock` — here, in `stop()`, in
    /// `closeStreams()` and in `finish()` — because the last of those runs on the network queue
    /// while the first three can run on the main actor.
    private func addStream(_ stream: EventStream) {
        stateLock.lock()
        streams.append(stream)
        stateLock.unlock()
    }

    public init(port: UInt16, handler: @escaping Handler, streamer: Streamer? = nil) {
        self.port = port
        self.handler = handler
        self.streamer = streamer
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
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
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

    /// Whether anything already accepts a connection on this port.
    ///
    /// A blocking connect to loopback with a short timeout. A listener accepts immediately, and
    /// this needs nothing else to be true for the answer to be useful.
    /// Public because the app has to ask the same question before it decides whether to start
    /// an engine of its own: a port that answers but does not speak the app's transport is a
    /// situation to report, not one to bulldoze with a second engine.
    public static func isSomethingListening(on port: UInt16) -> Bool {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { close(handle) }

        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = setsockopt(
            handle, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        // Darwin's sockaddr_in carries its own length and `connect` rejects the address without
        // it — silently, with EINVAL, which reads here as "nothing is listening" and is exactly
        // the wrong answer. This was the bug in the first version of this check.
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(handle, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        stateLock.lock()
        let open = streams
        streams.removeAll()
        let active = Array(connections.values)
        connections.removeAll()
        stateLock.unlock()
        for stream in open { stream.close() }
        for connection in active { connection.cancel() }
        markStopped()
    }

    /// Close every open event stream. Used when the conversation is reset, so a connected
    /// page re-reads the state rather than waiting on events that will never come.
    public func closeStreams() {
        stateLock.lock()
        let open = streams
        streams.removeAll()
        stateLock.unlock()
        for stream in open { stream.close() }
    }

    private func accept(_ connection: NWConnection) {
        stateLock.lock()
        connections[ObjectIdentifier(connection)] = connection
        stateLock.unlock()

        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Accumulate until a whole request has arrived, then answer it.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.finish(connection, error: error)
                return
            }

            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }

            if accumulated.isEmpty, isComplete {
                self.finish(connection, error: nil)
                return
            }

            do {
                let request = try HTTPParser.parse(accumulated)
                self.respond(to: request, on: connection)
            } catch is HTTPParser.Incomplete {
                if isComplete {
                    // The peer closed mid-request; nothing useful to send.
                    self.finish(connection, error: nil)
                } else if accumulated.count > HTTPParser.maximumBodyBytes {
                    self.write(
                        .error("Request body is too large", status: 413), to: connection,
                        thenClose: true)
                } else {
                    self.receive(on: connection, buffer: accumulated)
                }
            } catch let error as HTTPError {
                self.write(
                    .error(error.localizedDescription, status: 400), to: connection, thenClose: true)
            } catch {
                self.write(
                    .error(error.localizedDescription, status: 400), to: connection, thenClose: true)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        // A stream owns the connection from here: the response head goes out immediately and
        // the socket stays open, which is what makes server-sent events work.
        // Everything below hops to the main actor rather than assuming it: this runs on the
        // network queue, and `assumeIsolated` from there traps. The consequence is that
        // handlers run on the main actor, which is what lets them use a `@MainActor` engine
        // without any locking.
        Task { @MainActor [weak self] in
            guard let self else { return }

            if request.method == "GET", let streamer = self.streamer {
                let stream = EventStream(connection: connection)
                let initial = streamer(request, stream)
                if !initial.isEmpty {
                    // Appended under `stateLock`, like every other access to `streams`.
                    //
                    // This said "no lock: `streams` is only ever touched on the main actor", and
                    // that was never true: `stop()`, `closeStreams()` and `finish()` all mutate
                    // the same array under the lock, and `finish()` runs on the network queue.
                    // Appending here without it is a concurrent mutation of a Swift array — the
                    // kind that corrupts or crashes rather than merely reporting a stale value.
                    self.addStream(stream)
                    // Head first, then the opening events, then the socket is left open —
                    // which is what makes server-sent events work.
                    let head =
                        "HTTP/1.1 200 OK\r\n"
                        + "Content-Type: text/event-stream; charset=utf-8\r\n"
                        + "Cache-Control: no-store\r\n"
                        + "X-Accel-Buffering: no\r\n"
                        + "Access-Control-Allow-Origin: *\r\n"
                        + "Connection: keep-alive\r\n"
                        + "\r\n"
                    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                    for payload in initial { stream.send(payload, event: "snapshot") }
                    return
                }
            }

            let response = await self.handler(request)
            self.write(response, to: connection, thenClose: true)
        }
    }

    private func write(_ response: HTTPResponse, to connection: NWConnection, thenClose: Bool) {
        let data = response.serialised(keepAlive: !thenClose)
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                if thenClose { self.finish(connection, error: nil) }
            })
    }

    private func finish(_ connection: NWConnection, error: NWError?) {
        if let error {
            _ = error  // A client that walks away mid-request is not worth reporting.
        }
        stateLock.lock()
        connections[ObjectIdentifier(connection)] = nil
        for stream in streams where stream.matches(connection) { stream.markClosed() }
        streams.removeAll { !$0.isOpen }
        stateLock.unlock()
        connection.cancel()
    }
}
