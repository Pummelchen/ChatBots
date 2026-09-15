// ChatBotsCoreTests — the request head is read strictly, because leniency here is a disagreement with the
// other parser in the path (A154).
//
// Four leniencies, one class: the parser accepted shapes that RFC 9112 requires a server to reject, and
// each one is a place where this server and a proxy in front of it (Caddy, here) can read the same bytes
// differently — which is what request smuggling is made of, even when nothing downstream is exploitable.
//
//   * a field name was trimmed before the colon, so `Host : x` was read as `Host` (§5.1 says reject);
//   * a line with no colon was skipped, which is exactly how an obs-fold continuation arrives, so a
//     folded field was dropped rather than rejected (§5.2);
//   * the version went unread and the request line only had to have two parts, so `GET /x` and
//     `GET /x HTTP/9.9` both parsed as if they had said `HTTP/1.1` (§2.3, §3);
//   * `+` was decoded as a space in the *path*, which is a form rule, not a URI rule (§4.2.3 of RFC
//     3986): `/s/a+b` addressed `/s/a b`.
//
// Each is asserted with its counterweight, because a parser that refuses everything is not strict, it is
// broken — and the last suite proves the status codes reach a real client rather than only an error value.

import Foundation
import Testing

@testable import ChatBotsCore

private func parse(_ text: String) throws -> HTTPRequest {
    try HTTPParser.parse(Data(text.utf8))
}

/// Parse and hand back the refusal, so a test can assert on the case rather than on a string.
private func refusal(_ text: String) -> HTTPError? {
    do {
        _ = try parse(text)
        return nil
    } catch let error as HTTPError {
        return error
    } catch {
        return nil
    }
}

@Suite("The request head is read strictly (A154)")
struct HeadParsingTests {

    @Test("Whitespace before the colon in a field name is refused, not trimmed away")
    func whitespaceBeforeTheColon() throws {
        // RFC 9112 §5.1: "A server MUST reject, with a response status code of 400, any received request
        // message that contains whitespace between a header field name and colon." A proxy that trims
        // and one that does not disagree about where the name ends, which is the smuggling shape.
        for line in ["Host : example.com", "Host\t: example.com", ": example.com"] {
            guard case .malformed? = refusal("GET / HTTP/1.1\r\n\(line)\r\n\r\n") else {
                Issue.record("\"\(line)\" was accepted as a field")
                return
            }
        }

        // The counterweight: the ordinary spelling still parses, and the value keeps its own spaces.
        let request = try parse("GET / HTTP/1.1\r\nHost: example.com\r\nX-Note: a  b\r\n\r\n")
        #expect(request.headers["host"] == "example.com")
        #expect(request.headers["x-note"] == "a  b", "inner whitespace is the value's, not the parser's")
    }

    @Test("A folded header is refused rather than silently dropped")
    func foldedHeader() throws {
        // An obs-fold line begins with SP or HTAB. The old loop looked for a colon, did not find one, and
        // `continue`d — so the continuation vanished and the field kept only its first line. RFC 9112
        // §5.2 asks a server to reject the message instead, because whether it is folded is exactly what
        // two parsers disagree about.
        guard case .malformed? = refusal("GET / HTTP/1.1\r\nX-A: one\r\n  two\r\n\r\n") else {
            Issue.record("a folded header line was accepted")
            return
        }
        // A line that is not a field at all is refused for the same reason: it used to be dropped.
        guard case .malformed? = refusal("GET / HTTP/1.1\r\nX-A: one\r\nnot a header\r\n\r\n") else {
            Issue.record("a line with no field name was accepted")
            return
        }

        // The counterweight: two ordinary lines both arrive, and a repeated field is still joined.
        let request = try parse("GET / HTTP/1.1\r\nX-A: one\r\nX-B: two\r\nX-A: three\r\n\r\n")
        #expect(request.headers["x-a"] == "one, three")
        #expect(request.headers["x-b"] == "two")
    }

    @Test("The HTTP version must be one this server speaks")
    func versionIsChecked() throws {
        // The version was never read: `split(omittingEmptySubsequences: true)` plus `count >= 2` meant a
        // request line with two parts parsed with no version at all, and `HTTP/9.9` parsed as if it had
        // said 1.1. A version the server does not speak is what 505 is for (RFC 9112 §2.3).
        for line in ["GET / HTTP/9.9", "GET / HTTP/1.0", "GET / http/1.1", "GET / HTTP/2"] {
            let refused = refusal("\(line)\r\nHost: x\r\n\r\n")
            guard case .unsupportedVersion? = refused else {
                Issue.record("\"\(line)\" was not refused as an unsupported version")
                return
            }
            #expect(refused?.statusCode == 505, "a version this server does not speak is Not Supported")
        }

        // A request line with the wrong number of parts is malformed rather than version-less.
        for line in ["GET /", "GET", "GET / HTTP/1.1 extra"] {
            guard case .malformed? = refusal("\(line)\r\nHost: x\r\n\r\n") else {
                Issue.record("\"\(line)\" was accepted as a request line")
                return
            }
        }

        // The counterweight, which also pins that a lone space still separates the parts.
        let request = try parse("GET /api/state HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(request.method == "GET")
        #expect(request.path == "/api/state")
    }

    @Test("The method must be a token, and keeps the case normalisation the router relies on")
    func methodIsChecked() throws {
        // `G@T` is not a token, so no parser upstream and this one agree about what was asked for. The
        // upper-casing itself is deliberate and older than this fix — `HTTPTests` pins it — so it stays,
        // and what is new is that the method has to be a method at all.
        for method in ["G@T", "GE T", "(GET)"] {
            guard case .malformed? = refusal("\(method) / HTTP/1.1\r\nHost: x\r\n\r\n") else {
                Issue.record("\"\(method)\" was accepted as a method")
                return
            }
        }
        #expect(try parse("get / HTTP/1.1\r\n\r\n").method == "GET")
        #expect(try parse("M-SEARCH / HTTP/1.1\r\n\r\n").method == "M-SEARCH")
    }

    @Test("A plus in the path is a plus, and a plus in the query is a space")
    func plusIsOnlyASpaceInAQuery() throws {
        // A URI path is not a form. Decoding it with the query's rule meant a share link whose id held a
        // plus addressed a different path — `/s/a b` — and the kept conversation could not be opened.
        #expect(try parse("GET /s/a+b HTTP/1.1\r\n\r\n").path == "/s/a+b")
        #expect(try parse("GET /s/a%2Bb HTTP/1.1\r\n\r\n").path == "/s/a+b")
        #expect(try parse("GET /api/state+x HTTP/1.1\r\n\r\n").path == "/api/state+x")

        // The counterweight, so the fix is "only in the query" rather than "never": a browser form and
        // `URLSearchParams` both send a space as `+`, and an encoded plus must survive as a plus.
        let request = try parse("GET /api/x?t=a+b&p=a%2Bb HTTP/1.1\r\n\r\n")
        #expect(request.string("t") == "a b")
        #expect(request.string("p") == "a+b")
    }

    @Test("A request line that is not separated by single spaces is refused")
    func whitespaceInTheRequestLine() {
        // RFC 9112 §3 requires each part to be separated by a single SP, and warns that a lenient parser
        // is what a smuggling pair exploits. This server has no reason to be lenient: every client it has
        // writes single spaces.
        for line in ["GET  / HTTP/1.1", "GET /  HTTP/1.1", "GET\t/ HTTP/1.1"] {
            guard case .malformed? = refusal("\(line)\r\nHost: x\r\n\r\n") else {
                Issue.record("\"\(line)\" was accepted despite its whitespace")
                return
            }
        }
    }
}

@MainActor
@Suite("A strict head reaches the client as a status, not only as an error (A154)")
struct HeadParsingWireTests {

    private func exchange(_ fixture: APIServerFixture, _ text: String) async throws -> String {
        let client = try RawConnection(port: fixture.port)
        defer { client.cancel() }
        #expect(await client.connect())
        client.send(text)
        guard let reply = await client.receiveOnce(timeout: .seconds(5)) else {
            Issue.record("the server answered nothing")
            return ""
        }
        return String(bytes: reply, encoding: .utf8) ?? ""
    }

    @Test("An unsupported version is answered 505 and a bad field name 400")
    func statusesReachTheClient() async throws {
        let fixture = try await makeAPIServerFixture()
        defer { fixture.server.stop() }

        let version = try await exchange(fixture, "GET /api/state HTTP/9.9\r\nHost: x\r\n\r\n")
        #expect(
            version.hasPrefix("HTTP/1.1 505"),
            "was \(version.prefix(60))")

        let name = try await exchange(fixture, "GET /api/state HTTP/1.1\r\nHost : x\r\n\r\n")
        #expect(
            name.hasPrefix("HTTP/1.1 400"),
            "was \(name.prefix(60))")

        // The counterweight: an ordinary GET is still answered, on the same server, in the same test.
        let url = try #require(URL(string: "\(fixture.base)/api/state"))
        let (_, response) = try await fixture.session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}
