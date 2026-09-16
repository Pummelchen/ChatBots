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
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 505: "HTTP Version Not Supported"
        case 503: "Service Unavailable"
        default: "OK"
        }
    }

    /// The bytes to put on the wire, headers included.
    public func serialised(keepAlive: Bool) -> Data {
        var data = head(keepAlive: keepAlive, contentLength: body.count)
        data.append(body)
        return data
    }

    /// The head for a response whose body is not known when the head is written.
    ///
    /// Server-sent events are the one response this server leaves open, so it has no `Content-Length` and
    /// nothing is appended to the head. It is built by the same code as every other head, which is the
    /// point: assembling it by hand is how the stream path came to carry none of the security headers
    /// every other response carries, for a whole class of response (A150).
    public func streamingHead(keepAlive: Bool = true) -> Data {
        head(keepAlive: keepAlive, contentLength: nil)
    }

    /// The head, with a length only when the whole body is in hand.
    private func head(keepAlive: Bool, contentLength: Int?) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        if let contentLength { head += "Content-Length: \(contentLength)\r\n" }
        head += "Cache-Control: no-store\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        // The security headers first, then anything the response set itself, so a page that
        // genuinely needs inline script or style can replace the policy in its own `headers`.
        var allHeaders = Self.securityHeaders(for: contentType)
        for (name, value) in headers { allHeaders[name] = value }
        for (name, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }

    /// The response that opens a server-sent event stream.
    ///
    /// No body and no length: the head is written on its own and the socket stays open, which is what
    /// makes server-sent events work. It is an `HTTPResponse` so that the stream path is not a second,
    /// hand-written header assembler — that is the whole of A150 — and `X-Accel-Buffering` is set here
    /// rather than in the head so that it takes the same route as every other response's own headers.
    public static func eventStream() -> HTTPResponse {
        HTTPResponse(
            contentType: "text/event-stream; charset=utf-8",
            headers: ["X-Accel-Buffering": "no"])
    }

    /// The headers every response carries, with the policy chosen from its content type.
    ///
    /// `nosniff` stops a browser treating a JSON error or a stylesheet as HTML, and the referrer
    /// policy stops this local address leaking to anything a rendered link reaches. Neither can
    /// break a page that serves its own assets, so both are unconditional. `X-Frame-Options` and
    /// `frame-ancestors` stop any page the user visits framing this interface and overlaying it.
    ///
    /// The content type decides the CSP because the interface and the kept-conversation page
    /// need different things: the interface is separate files with no inline script or style,
    /// while the share page carries both in the document.
    static func securityHeaders(for contentType: String) -> [String: String] {
        [
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
            "X-Frame-Options": "DENY",
            "Content-Security-Policy":
                contentType.hasPrefix("text/html") ? interfacePolicy : documentPolicy,
        ]
    }

    /// The policy for a response that renders no document: API JSON, an asset, an error.
    ///
    /// Nothing should load from it and nothing should be able to frame it.
    static let documentPolicy =
        "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'; "
        + "object-src 'none'"

    /// The policy for the interface.
    ///
    /// The page loads `/app.js` and `/style.css` from this same origin, has no inline script, no
    /// inline event handler and no inline style, and reaches the engine only through relative
    /// `/api` paths with `fetch` and `EventSource`. That is what lets the policy keep
    /// `script-src 'self'` with no `'unsafe-inline'` — the grant an injected `<script>`,
    /// `onerror=` attribute or `javascript:` URL would need in order to run. The page renders
    /// model and document text, so that grant is the point of the policy rather than a detail.
    static let interfacePolicy =
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        + "connect-src 'self'; font-src 'self'; frame-ancestors 'none'; base-uri 'none'; "
        + "form-action 'none'; object-src 'none'"

    /// The policy for a page that carries its own inline stylesheet and replay script.
    ///
    /// The kept-conversation page renders the transcript with `textContent` and travels its data
    /// as escaped JSON, but its script and stylesheet are part of the document, so it needs
    /// `'unsafe-inline'` for both. There is no nonce to give it: the page generator does not
    /// emit one and is outside this change. The grant is confined to this one response rather
    /// than given to the interface and the API with it, and the page has no network access to
    /// give away.
    static let inlinePagePolicy =
        "default-src 'none'; script-src 'self' 'unsafe-inline'; "
        + "style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'; "
        + "frame-ancestors 'none'; base-uri 'none'; form-action 'none'; object-src 'none'"

    /// The policy for the "no conversation with that link" page, which carries an inline `style`
    /// attribute on its body and no script at all.
    static let inlineStylePagePolicy =
        "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; "
        + "base-uri 'none'; form-action 'none'; object-src 'none'"
}

// MARK: - Parsing

/// Request parsing, kept separate from the socket so it can be tested directly.
public enum HTTPParser {

    /// The largest request this server will accept.
    ///
    /// The same wire budget as the WebTransport protocol, because an attachment upload is the
    /// largest request either transport carries — the body is JSON with the file base64-encoded
    /// — and two caps that disagree mean one transport refuses what the other documents as
    /// supported. It was 8 MB against a documented 64 MB attachment, so the limit was
    /// unreachable here as well as being unreachable over WebTransport. Derived from
    /// `ProtocolLimits`, which is in turn derived from `AttachmentLimits`, so the three cannot
    /// drift apart again.
    public static let maximumBodyBytes = ProtocolLimits.maximumMessageBytes

    /// How large a request head may be before it is refused.
    ///
    /// A head is a request line and a handful of fields — a few hundred bytes for everything this
    /// server does, and no browser sends kilobytes. It had no bound of its own: a client could stream
    /// the full 85 MB body allowance as "headers", kept in memory per connection and rescanned from
    /// the start on every 64 KB read, so thirty-two connections pinned gigabytes and the scan was
    /// quadratic in the head (A145). 16 KB is generous for a head and small enough that the worst case
    /// per connection is not worth attacking.
    public static let maximumHeadBytes = 16 * 1_024

    public struct Incomplete: Error {}

    /// The versions this server speaks, checked against the request line.
    ///
    /// Only HTTP/1.1: every response declares 1.1 framing, the clients are the page, the CLI, the app
    /// and Caddy's upstream, and a version this server does not speak is the case 505 exists for. The
    /// version used to go unread entirely, so `GET / HTTP/9.9` parsed as if it had said 1.1 (A154).
    static let supportedVersions: Set<String> = ["HTTP/1.1"]

    /// Whether every character of `text` is a token character (RFC 9110 §5.6.2), which is what a method
    /// and a field name must be.
    ///
    /// ASCII on purpose: `CharacterSet.alphanumerics` is the whole of Unicode, so it would accept a
    /// field name with a letter in it that no parser on the other side of a proxy would agree with.
    static func isToken(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { tokenCharacters.contains($0) }
    }

    private static let tokenCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return set
    }()

    /// The method and target from a request line, which must have exactly three parts.
    ///
    /// `split(omittingEmptySubsequences: true)` and a `count >= 2` guard accepted a line with no version
    /// — it went unread — and a line with four parts, and collapsed runs of spaces with them, so a
    /// request line no parser upstream would agree with was read as if it were ordinary (A154). The
    /// method keeps the upper-casing the router compares against, which is pinned by `HTTPTests`; what
    /// is new is that it has to be a token at all.
    static func requestParts(_ line: String) throws -> (method: String, target: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw HTTPError.malformed("the request line must be a method, a target and a version")
        }
        guard isToken(parts[0]) else {
            throw HTTPError.malformed("the method was not a token")
        }
        guard supportedVersions.contains(String(parts[2])) else {
            throw HTTPError.unsupportedVersion(String(parts[2]))
        }
        return (String(parts[0]).uppercased(), String(parts[1]))
    }

    /// The header fields, refusing the two shapes RFC 9112 requires a server to reject.
    ///
    /// A field name was trimmed before the colon, so `Host : x` — the whitespace §5.1 says a server MUST
    /// reject — was read as `Host`; and a line with no colon was skipped, which is exactly how an
    /// obs-fold continuation line arrives, so a folded field was dropped rather than rejected (§5.2).
    /// The value keeps the optional whitespace the standard allows around it.
    static func headerFields(_ lines: [String]) throws -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard line.first != " ", line.first != "\t" else {
                throw HTTPError.malformed("a header line was a continuation of the previous one")
            }
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPError.malformed("a header line had no field name")
            }
            let name = line[line.startIndex..<colon]
            guard isToken(name) else {
                throw HTTPError.malformed("a header field name was not a token: \"\(name)\"")
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let key = name.lowercased()
            // Repeated headers are joined, which is harmless for the ones we read.
            headers[key] = headers[key].map { "\($0), \(value)" } ?? value
        }
        return headers
    }

    /// Where the request head ends, or why there is not one yet.
    ///
    /// Only the first `maximumHeadBytes` are searched, so the work per read is bounded by the cap
    /// rather than by how much has arrived — the whole buffer used to be rescanned on every 64 KB, so
    /// the scan was quadratic in the head — and a request whose head cannot fit is refused here rather
    /// than accumulated, which is what kept thirty-two connections from pinning gigabytes (A145).
    ///
    /// Its own function as well as its own rule: `parse` is at its cyclomatic-complexity budget, and
    /// the two ways this can end without a head are worth reading together.
    private static func headEnd(in data: Data) throws -> Data.Index {
        let searchable = data.prefix(maximumHeadBytes + 4)
        guard let end = searchable.range(of: Data("\r\n\r\n".utf8))?.lowerBound else {
            if data.count > maximumHeadBytes { throw HTTPError.headTooLarge }
            throw Incomplete()
        }
        return end
    }

    /// Parse a complete request head plus whatever body has arrived.
    ///
    /// Throws `Incomplete` when more bytes are needed, which is the normal case for a
    /// request arriving in pieces.
    public static func parse(_ data: Data) throws -> HTTPRequest {
        let headerEnd = try headEnd(in: data)
        let headData = data[data.startIndex..<headerEnd]
        guard let head = String(data: headData, encoding: .utf8) else {
            throw HTTPError.malformed("the request head was not valid UTF-8")
        }

        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPError.malformed("empty request") }
        lines.removeFirst()
        let (method, target) = try requestParts(requestLine)
        let headers = try headerFields(lines)

        try refuseUnframedBody(headers)

        let declaredLength = try declaredBodyLength(headers["content-length"])
        guard declaredLength <= maximumBodyBytes else {
            throw HTTPError.tooLarge
        }
        // Past the blank line that ends the head: the terminator is four bytes.
        let bodyStart = headerEnd + 4
        let available = data.count - data.distance(from: data.startIndex, to: bodyStart)
        guard available >= declaredLength else { throw Incomplete() }
        let body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: declaredLength)])

        // Split the path from the query, and decode percent escapes so a topic with
        // spaces or non-ASCII can travel in a URL.
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = pathDecoded(String(parts.first ?? ""))
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                query[formDecoded(String(kv.first ?? ""))] =
                    kv.count > 1 ? formDecoded(String(kv[1])) : ""
            }
        }

        return HTTPRequest(
            method: method, path: path, query: query, headers: headers, body: body)
    }

    /// Refuse a body whose framing this server cannot read, rather than reading it as empty.
    ///
    /// `Transfer-Encoding` appeared nowhere in this file (A153), so a chunked request — what a proxy
    /// forwards when the client did not know the length, and what `curl --data-binary @-` sends from a
    /// pipe — arrived with no `Content-Length`, which `declaredBodyLength` reads as zero. The request
    /// then parsed successfully with an empty body and its route ran on it. Every route here reads an
    /// empty body as "the field was not sent" (A142) and `/api/topic` answers that by clearing the
    /// topic, so the failure was silent and in the direction of changing state.
    ///
    /// Both framings at once is the one shape here that is a request-smuggling signal rather than a
    /// client mistake, so it is a 400 (RFC 9112 §6.1); a coding this server does not implement — it
    /// implements none — is the 501 that same section asks for. Nothing downstream sees either: the
    /// read loop answers and closes before a route is reached.
    private static func refuseUnframedBody(_ headers: [String: String]) throws {
        guard let declared = headers["transfer-encoding"] else { return }
        guard headers["content-length"] == nil else {
            throw HTTPError.malformed("both Transfer-Encoding and Content-Length were declared")
        }
        guard !declared.isEmpty else {
            throw HTTPError.malformed("Transfer-Encoding declared no coding")
        }
        throw HTTPError.unsupportedTransferEncoding(declared)
    }

    /// The body length a `Content-Length` header declares, or zero when it is absent.
    ///
    /// Parsed strictly on purpose. `Int.init` accepts a leading `-`, and a negative length used
    /// to pass both guards that followed — `declaredLength <= maximumBodyBytes` and
    /// `available >= declaredLength` — and then became a slice offset that indexed before
    /// `startIndex` and trapped, killing the process and the running conversation with it. The
    /// header parser also joins duplicate headers with `", "`, so a repeated `Content-Length: 5`
    /// arrives here as `"5, 5"`; requiring a single run of digits closes both holes at once.
    /// A malformed value throws, which the read loop answers with 400 and closes the
    /// connection; a value too large to be an `Int` is reported as too large rather than
    /// trapping on the conversion.
    static func declaredBodyLength(_ raw: String?) throws -> Int {
        guard let raw else { return 0 }
        guard !raw.isEmpty,
            raw.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") })
        else {
            throw HTTPError.malformed(
                "Content-Length must be a single non-negative integer")
        }
        guard let value = Int(raw) else { throw HTTPError.tooLarge }
        return value
    }

    /// Percent-decoding for a path, where `+` is a plus.
    ///
    /// A URL path is not a form: RFC 3986 gives `+` no special meaning there, and this used to decode a
    /// path with the query's rule, so `/s/a+b` became `/s/a b` — a different resource from the one the
    /// client asked for, and a kept conversation whose id contained a plus could not be opened at all
    /// (A154). A malformed escape is left alone rather than dropped.
    static func pathDecoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    /// Percent-decoding for a query, where `+` is a space.
    ///
    /// `application/x-www-form-urlencoded` is what a browser form and `URLSearchParams` send, and this
    /// is the one place that convention applies. The replacement comes before the percent-decoding so
    /// that an encoded plus (`%2B`) survives as a plus while a literal one becomes a space.
    static func formDecoded(_ value: String) -> String {
        pathDecoded(value.replacingOccurrences(of: "+", with: " "))
    }
}

public enum HTTPError: LocalizedError {
    case malformed(String)
    case tooLarge
    case headTooLarge
    case portInUse(UInt16)
    /// A body the server cannot frame because it does not implement the coding asked for (A153).
    case unsupportedTransferEncoding(String)
    /// An HTTP version this server does not speak (A154).
    case unsupportedVersion(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let reason): "Malformed request: \(reason)"
        case .tooLarge: "Request body is too large"
        case .headTooLarge: "Request headers are too large"
        case .portInUse(let port): "Port \(port) is already in use"
        case .unsupportedTransferEncoding(let coding):
            "Transfer-Encoding is not supported: \(coding). Send a Content-Length instead."
        case .unsupportedVersion(let version):
            "HTTP version is not supported: \(version). This server speaks HTTP/1.1."
        }
    }

    /// The status a client is answered with. 431 for a head that cannot fit is the code that exists
    /// for it; 413 is the body's; 501 is what RFC 9112 §6.1 asks for when the recipient does not
    /// implement the transfer coding it was sent.
    public var statusCode: Int {
        switch self {
        case .headTooLarge: 431
        case .tooLarge: 413
        case .unsupportedTransferEncoding: 501
        case .unsupportedVersion: 505
        case .malformed, .portInUse: 400
        }
    }
}

// MARK: - Server

/// Serves a routing closure over HTTP on a port, on the loopback interface only.
///
/// `@unchecked Sendable` with the parts written down, because the compiler cannot check them:
/// `connections`, `streams`, `idleDeadlines`, `refusals`, `running` and `failure` are read and
/// written under `stateLock`, and no lock is held across a call that could re-enter this type.
/// `listener` is only touched by `start()` and `stop()`, which the owning actor calls.
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
    /// under this finding: A32 made `HTTPParser.maximumBodyBytes` the base64 form of the
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
    private var idleDeadlines: [ObjectIdentifier: UUID] = [:]

    /// One thing that went wrong on this listener, kept so a live engine can be diagnosed.
    public struct ConnectionFailure: Sendable, Equatable, Codable {
        /// What happened, in a sentence: a connection error, a request the parser refused, a connection
        /// refused for being over the limit.
        public var reason: String
        public var at: Date
    }

    /// How many failures are kept.
    ///
    /// Bounded, because anyone who can reach the port can produce one: an unbounded log of a server that
    /// listens on every interface is a memory leak wearing a diagnostics label (A151).
    public static let failureHistoryLimit = 20

    /// The most recent failures, newest first.
    ///
    /// This is the other half of A151: the counters below existed and were reachable from no endpoint, and
    /// a client that walked away mid-request was `_ = error`'d out of existence, so diagnosing a running
    /// engine meant reading source. `APIServer` serves this on `/api/health`.
    public var recentFailures: [ConnectionFailure] {
        failureLock.lock()
        defer { failureLock.unlock() }
        return failures
    }
    /// Its own lock rather than `stateLock`, so that recording a failure is safe on every path —
    /// including the ones that already hold `stateLock` — without nesting one lock inside another.
    private let failureLock = NSLock()
    private var failures: [ConnectionFailure] = []

    /// Record one failure, keeping the newest `failureHistoryLimit`.
    ///
    /// Internal rather than private so the tests can drive the ring without a socket, and because the
    /// network queue and the main actor both call it: the lock is the whole of the synchronisation.
    func note(_ reason: String) {
        failureLock.lock()
        defer { failureLock.unlock() }
        failures.insert(ConnectionFailure(reason: reason, at: .now), at: 0)
        if failures.count > Self.failureHistoryLimit {
            failures.removeLast(failures.count - Self.failureHistoryLimit)
        }
    }

    /// How many connections have been refused for being over `maximumConnections`.
    ///
    /// Counted and answerable because the finding's other half was that nothing reported this
    /// at all. Read under `stateLock`, like every other access to the connection tables.
    public var refusedConnectionCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return refusals
    }
    private var refusals = 0

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
    /// Every read and write of `streams` goes through `stateLock` — here, in `stop()` and in
    /// `finish()` — because the last of those runs on the network queue while the other can run on
    /// the main actor.
    private func addStream(_ stream: EventStream) {
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

    private func accept(_ connection: NWConnection) {
        stateLock.lock()
        let atCapacity = connections.count >= maximumConnections
        if atCapacity {
            refusals += 1
        } else {
            connections[ObjectIdentifier(connection)] = connection
        }
        stateLock.unlock()

        connection.start(queue: queue)
        guard !atCapacity else {
            note("refused: \(maximumConnections) connections already open")
            // Refused rather than queued, and refused with an answer rather than silence: a
            // peer over the cap is told, and the connection is not entered in the table.
            write(
                .error("the server is at its connection limit", status: 503), to: connection,
                thenClose: true)
            return
        }
        armIdleDeadline(for: connection)
        receive(on: connection, buffer: Data())
    }

    /// Start, or restart, the idle deadline for a connection whose request is not complete.
    ///
    /// The token replaces any previous one, so the earlier deadline — if it has not fired
    /// already — finds itself stale and does nothing. It is not cancelled, because a dispatch
    /// work item cannot be cancelled once it is executing anyway and a stale one costs a UUID
    /// comparison.
    private func armIdleDeadline(for connection: NWConnection) {
        let token = UUID()
        stateLock.lock()
        idleDeadlines[ObjectIdentifier(connection)] = token
        stateLock.unlock()

        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            self?.idleDeadlineFired(for: connection, token: token)
        }
    }

    /// The connection's request has been read in full; it is no longer idle.
    private func disarmIdleDeadline(for connection: NWConnection) {
        stateLock.lock()
        idleDeadlines[ObjectIdentifier(connection)] = nil
        stateLock.unlock()
    }

    /// Drop a connection whose request did not arrive in time.
    private func idleDeadlineFired(for connection: NWConnection, token: UUID) {
        stateLock.lock()
        let isCurrent = idleDeadlines[ObjectIdentifier(connection)] == token
        let isLive = connections[ObjectIdentifier(connection)] != nil
        if isCurrent { idleDeadlines[ObjectIdentifier(connection)] = nil }
        stateLock.unlock()

        // Stale token, or the connection has already been answered or reaped: nothing to do.
        guard isCurrent, isLive else { return }
        note("request: not completed in time")
        write(
            .error("the request was not completed in time", status: 408), to: connection,
            thenClose: true)
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
                // The request is complete, so the connection is no longer idle. This is what
                // lets an event stream stay open past `requestTimeout`: the deadline covers
                // reading the request, not the conversation the connection is kept for.
                self.disarmIdleDeadline(for: connection)
                self.respond(to: request, on: connection)
            } catch is HTTPParser.Incomplete {
                if isComplete {
                    // The peer closed mid-request; nothing useful to send.
                    self.note("request: the peer closed before the request was complete")
                    self.finish(connection, error: nil)
                } else if accumulated.count > HTTPParser.maximumHeadBytes
                    + HTTPParser.maximumBodyBytes
                {
                    // Head plus body, because a head that has not terminated is counted here too and the
                    // head has its own cap inside `parse` (A145).
                    self.note("request: larger than the head and body limits")
                    self.write(
                        .error("Request body is too large", status: 413), to: connection,
                        thenClose: true)
                } else {
                    // Progress restarts the idle clock; a client that sends nothing does not.
                    if chunk != nil { self.armIdleDeadline(for: connection) }
                    self.receive(on: connection, buffer: accumulated)
                }
            } catch let error as HTTPError {
                // The parser refused it: a malformed head, a head or body past its cap, a request line it
                // cannot read. Answered with its own status and, now, remembered (A151).
                self.note("request: \(error.localizedDescription)")
                self.write(
                    .error(error.localizedDescription, status: error.statusCode), to: connection,
                    thenClose: true)
            } catch {
                // Anything else, which the caller sees as a 400. Recorded too: the failures worth reading are
                // the ones nobody wrote a status code for.
                self.note("request: \(error.localizedDescription)")
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
                    // that was never true: `stop()` and `finish()` mutate the same array under the
                    // lock, and `finish()` runs on the network queue. Appending here without it is a
                    // concurrent mutation of a Swift array — the kind that corrupts or crashes
                    // rather than merely reporting a stale value.
                    self.addStream(stream)
                    // Head first, then the opening events, then the socket is left open —
                    // which is what makes server-sent events work. The head comes from the same
                    // response type every other route answers with, so it carries the same security
                    // headers; it used to be assembled here by hand, without any of them (A150).
                    connection.send(
                        content: HTTPResponse.eventStream().streamingHead(),
                        completion: .contentProcessed { _ in })
                    for payload in initial { stream.send(payload, event: "snapshot") }
                    // The connection stays open, so it still has to be watched: this is the
                    // only place that learns the client has gone, and `finish` is the only code
                    // that prunes the stream and the connection. This used to return here, so
                    // `finish` could never run for a streaming connection, `isOpen` stayed true,
                    // `removeAll { !$0.isOpen }` never removed anything, and every page reload
                    // or dropped client left an `EventStream` and an `NWConnection` retained for
                    // the life of the process while the server kept broadcasting to a dead
                    // socket.
                    self.awaitClose(on: connection)
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

    /// Wait for a client the server is streaming to, to go away.
    ///
    /// The request has already been answered, so anything the client sends is ignored: this
    /// exists only so the closure is observed and `finish` — the sole pruning path — can run.
    /// `finish` cancels the connection, which ends this read too, so it is not re-armed after
    /// it fires; a keep-alive byte from a client that has nothing to say re-arms the wait rather
    /// than ending the stream.
    private func awaitClose(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 * 1024) {
            [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.finish(connection, error: error)
            } else {
                self.awaitClose(on: connection)
            }
        }
    }

    private func finish(_ connection: NWConnection, error: NWError?) {
        if let error {
            // Not worth *showing* anyone — a client that walks away mid-request is routine — but worth
            // recording once, because "the connection keeps dropping" is not diagnosable otherwise. The
            // ring is bounded, so routine noise cannot grow (A151).
            note("connection: \(error)")
        }
        stateLock.lock()
        connections[ObjectIdentifier(connection)] = nil
        idleDeadlines[ObjectIdentifier(connection)] = nil
        for stream in streams where stream.matches(connection) { stream.markClosed() }
        streams.removeAll { !$0.isOpen }
        stateLock.unlock()
        connection.cancel()
    }
}
