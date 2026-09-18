// ChatBotsCore — the incremental parser, and the limits it enforces
//
// Split out of `HTTPServer.swift`, which held the request and response types, the parser, the errors
// and the server in one 1100-line file. Nothing changed but which file each one lives in.

import Foundation

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
    /// quadratic in the head. 16 KB is generous for a head and small enough that the worst case
    /// per connection is not worth attacking.
    public static let maximumHeadBytes = 16 * 1_024

    public struct Incomplete: Error {}

    /// The versions this server speaks, checked against the request line.
    ///
    /// Only HTTP/1.1: every response declares 1.1 framing, the clients are the page, the CLI, the app
    /// and Caddy's upstream, and a version this server does not speak is the case 505 exists for. The
    /// version used to go unread entirely, so `GET / HTTP/9.9` parsed as if it had said 1.1.
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
    /// request line no parser upstream would agree with was read as if it were ordinary. The
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
            // RFC 9112 §5.1: a recipient MUST reject a field value with a bare CR or LF. The head is
            // split on CRLF, so a lone CR or LF survives the split and used to be accepted — the
            // shape a request-smuggling payload needs to make two parsers disagree about where the
            // head ends. (A CR followed by an LF cannot be here: that pair is the split.)
            guard !value.contains("\r"), !value.contains("\n") else {
                throw HTTPError.malformed("a header field value contained a bare CR or LF")
            }
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
    /// than accumulated, which is what kept thirty-two connections from pinning gigabytes.
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
    /// `Transfer-Encoding` appeared nowhere in this file, so a chunked request — what a proxy
    /// forwards when the client did not know the length, and what `curl --data-binary @-` sends from a
    /// pipe — arrived with no `Content-Length`, which `declaredBodyLength` reads as zero. The request
    /// then parsed successfully with an empty body and its route ran on it. Every route here reads an
    /// empty body as "the field was not sent" and `/api/topic` answers that by clearing the
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
    /// client asked for, and a kept conversation whose id contained a plus could not be opened at all.
    /// A malformed escape is left alone rather than dropped.
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
