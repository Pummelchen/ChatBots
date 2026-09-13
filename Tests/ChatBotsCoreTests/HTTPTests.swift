// ChatBotsCoreTests — the HTTP layer
//
// The parser and the response writer are hand-written, which is exactly the sort of code
// that needs asserting rather than assuming. A request arriving in pieces is the normal
// case on a network, and getting the framing wrong produces a server that works in testing
// and fails in a browser.

import ChatBotsCore
import Foundation
import Testing

@Suite("HTTP parsing")
struct HTTPParserTests {

    private func parse(_ text: String) throws -> HTTPRequest {
        try HTTPParser.parse(Data(text.utf8))
    }

    @Test("A minimal request is parsed")
    func minimalRequest() throws {
        let request = try parse("GET /api/health HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(request.method == "GET")
        #expect(request.path == "/api/health")
        #expect(request.body.isEmpty)
        #expect(request.headers["host"] == "localhost")
    }

    @Test("The method is normalised to upper case")
    func methodCase() throws {
        #expect(try parse("get / HTTP/1.1\r\n\r\n").method == "GET")
        #expect(try parse("Post / HTTP/1.1\r\n\r\n").method == "POST")
    }

    @Test("A query string is split and decoded")
    func queryString() throws {
        let request = try parse("GET /api/x?topic=hello%20world&n=5&flag HTTP/1.1\r\n\r\n")
        #expect(request.path == "/api/x")
        #expect(request.string("topic") == "hello world")
        #expect(request.int("n") == 5)
        #expect(request.string("flag") == "", "a key with no value is still present")
        #expect(request.string("missing") == nil)
    }

    @Test("Non-ASCII and emoji survive percent-decoding in a URL")
    func unicodeInQuery() throws {
        // The topic is the one piece of user text that travels in a URL.
        let encoded = "Gr%C3%BC%C3%9Fe%20%F0%9F%A5%9A%20%E6%97%A5%E6%9C%AC%E8%AA%9E"
        let request = try parse("GET /api/x?t=\(encoded) HTTP/1.1\r\n\r\n")
        #expect(request.string("t") == "Grüße 🥚 日本語")
    }

    @Test("A body is read up to its content length, and no further")
    func bodyReading() throws {
        let body = #"{"topic":"eggs"}"#
        let request = try parse(
            "POST /api/topic HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        #expect(request.body.count == body.utf8.count)
        #expect(request.json(APICommand.self)?.topic == "eggs")
    }

    @Test("A body with a multi-byte character counts bytes, not characters")
    func bodyLengthIsBytes() throws {
        // Content-Length is bytes: using the character count here would truncate the body.
        let body = #"{"topic":"Grüße 🥚"}"#
        let request = try parse(
            "POST /api/topic HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        #expect(request.json(APICommand.self)?.topic == "Grüße 🥚")
    }

    @Test("A request that has not fully arrived reports that it is incomplete")
    func incompleteRequests() {
        // No header terminator yet.
        #expect(throws: HTTPParser.Incomplete.self) {
            try HTTPParser.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8))
        }
        // Headers complete but the body has not arrived.
        #expect(throws: HTTPParser.Incomplete.self) {
            try HTTPParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8))
        }
    }

    @Test("Repeated headers are joined rather than overwriting each other")
    func repeatedHeaders() throws {
        let request = try parse("GET / HTTP/1.1\r\nX-A: 1\r\nX-A: 2\r\n\r\n")
        #expect(request.headers["x-a"] == "1, 2")
    }

    @Test("An oversized body is refused before it is read")
    func oversizedBody() {
        let declared = HTTPParser.maximumBodyBytes + 1
        #expect(throws: HTTPError.self) {
            try HTTPParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: \(declared)\r\n\r\n".utf8))
        }
    }

    @Test("A negative Content-Length is refused rather than used as a slice offset")
    func negativeContentLength() {
        // `Int.init` read "-1" happily, both guards passed, and the value then indexed before
        // the start of the buffer — a trap, not a 400, which took the process with it.
        #expect(throws: HTTPError.self) {
            try HTTPParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8))
        }
    }

    @Test("A Content-Length too large to be an Int is refused, not crashed on")
    func enormousContentLength() {
        // A run of digits is well-formed but does not fit an Int; the conversion must not trap.
        #expect(throws: HTTPError.self) {
            try HTTPParser.parse(
                Data("POST / HTTP/1.1\r\nContent-Length: 99999999999999999999999999\r\n\r\n".utf8))
        }
    }

    @Test("A non-numeric Content-Length is refused")
    func nonNumericContentLength() {
        // Including the signed and spaced spellings `Int.init` would have accepted.
        for value in ["abc", "1 2", "+5", "5.0", "0x10", ""] {
            #expect(throws: HTTPError.self) {
                try HTTPParser.parse(
                    Data("POST / HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n".utf8))
            }
        }
    }

    @Test("A duplicated Content-Length is refused, not joined and misread as zero")
    func duplicatedContentLength() {
        // The header parser joins duplicates with ", ", which `Int.init` could not read — so
        // this used to become 0 and the body silently vanished. One integer or nothing.
        #expect(throws: HTTPError.self) {
            try HTTPParser.parse(
                Data(
                    "POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello"
                        .utf8))
        }
    }

    @Test("A malformed request line is rejected, not guessed at")
    func malformedRequestLine() {
        #expect(throws: HTTPError.self) { try HTTPParser.parse(Data("GARBAGE\r\n\r\n".utf8)) }
    }
}

@Suite("HTTP responses")
struct HTTPResponseTests {

    private func head(_ response: HTTPResponse) -> String {
        let data = response.serialised(keepAlive: true)
        guard let text = String(data: data, encoding: .utf8),
            let end = text.range(of: "\r\n\r\n")
        else { return "" }
        return String(text[..<end.lowerBound])
    }

    @Test("The status line and length are correct")
    func statusLine() {
        let response = HTTPResponse.text("hello")
        let head = head(response)
        #expect(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(head.contains("Content-Length: 5"))
    }

    @Test("Content-Length counts bytes for multi-byte text")
    func byteLength() {
        // A character count here would cut the response short in the browser.
        let response = HTTPResponse.text("Grüße 🥚")
        let bytes = "Grüße 🥚".utf8.count
        #expect(head(response).contains("Content-Length: \(bytes)"))
        #expect(response.body.count == bytes)
    }

    @Test("Error responses carry a status and a message a client can show")
    func errorResponse() throws {
        let response = HTTPResponse.error("no route", status: 404)
        #expect(head(response).hasPrefix("HTTP/1.1 404 Not Found"))
        let decoded = try JSONSerialization.jsonObject(with: response.body) as? [String: String]
        #expect(decoded?["error"] == "no route")
    }

    @Test("The body is appended after the blank line, with nothing lost")
    func framing() {
        let response = HTTPResponse.json(["status": "ok"])
        let text = String(decoding: response.serialised(keepAlive: false), as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        #expect(parts.count == 2, "exactly one blank line separates head from body")
        #expect(parts[1].contains("\"status\""))
    }

    @Test("Every status the server uses has a reason phrase")
    func reasonPhrases() {
        for status in [200, 201, 204, 400, 404, 405, 409, 413, 500] {
            let response = HTTPResponse(status: status)
            #expect(!response.reason.isEmpty)
            #expect(head(response).contains(" \(status) "))
        }
    }
}

@Suite("Web assets")
struct WebAssetTests {

    @Test("The page and its assets are served, at the paths the page asks for")
    func assetsExist() {
        // These are the paths index.html references; a mismatch is a blank page.
        #expect(WebAssets.asset(for: "/")?.contentType.contains("text/html") == true)
        #expect(WebAssets.asset(for: "/index.html")?.contentType.contains("text/html") == true)
        #expect(WebAssets.asset(for: "/style.css")?.contentType.contains("text/css") == true)
        #expect(WebAssets.asset(for: "/app.js")?.contentType.contains("javascript") == true)
    }

    @Test("The page references only assets that exist")
    func pageReferencesRealAssets() throws {
        let html = try #require(WebAssets.asset(for: "/")?.body)
        let text = String(decoding: html, as: UTF8.self)
        for name in ["style.css", "app.js"] {
            #expect(text.contains("/\(name)"), "the page should reference \(name)")
            #expect(WebAssets.asset(for: "/\(name)") != nil, "\(name) should be served")
        }
    }

    @Test("An unknown path is not served as an asset")
    func unknownPath() {
        #expect(WebAssets.asset(for: "/secrets.txt") == nil)
        #expect(WebAssets.asset(for: "/../Caddyfile") == nil)
    }

    @Test("The page is UTF-8 and declares it")
    func encoding() throws {
        let body = try #require(WebAssets.asset(for: "/")?.body)
        #expect(String(data: body, encoding: .utf8) != nil)
        #expect(String(decoding: body, as: UTF8.self).contains("charset=\"utf-8\""))
    }
}
