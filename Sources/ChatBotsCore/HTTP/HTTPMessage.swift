// ChatBotsCore — the request and response an HTTP transport hands over
//
// Split out of `HTTPServer.swift`, which held the request and response types, the parser, the errors
// and the server in one 1100-line file. Nothing changed but which file each one lives in.

import Foundation

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
    /// every other response carries, for a whole class of response.
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
    /// hand-written header assembler — which is the entire point of this type — and `X-Accel-Buffering` is set here
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
