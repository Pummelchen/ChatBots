// ChatBotsCoreTests — a body the server never decoded must not run its route (A153).
//
// `Transfer-Encoding` appeared nowhere in this server. `parse` read `Content-Length` and nothing else, so
// a chunked request — what a proxy forwards when the client did not know the length, and what
// `curl --data-binary @-` sends from a pipe — arrived with no length, which reads as zero. The request
// parsed with an empty body and **the route ran on it**, which every route in `APIServer` reads as "the
// field was not sent" (A142). Measured against the committed version, a chunked `POST /api/topic` is
// answered **409 "a topic is required"** — the caller's topic was dropped and the answer blames them for
// not sending one — and a chunked `POST /api/attachments` falls through its guards far enough to be
// answered **404 "no route for POST /api/attachments"**, for a route that exists. Nothing in either
// answer names the framing, which is the defect: the body vanished and the server said something else.
//
// The fix reads the header and refuses what it cannot frame: a coding this server does not implement is
// 501, which is what RFC 9112 §6.1 asks for, and a message declaring both framings is 400 — the one shape
// there that is a request-smuggling signal rather than a client mistake. The route is never reached.
//
// The counterweight matters as much as the refusal: the same bytes with a `Content-Length` must still be
// accepted and acted on, or refusing the framing would be indistinguishable from refusing POSTs.

import Foundation
import Testing

@testable import ChatBotsCore

/// A request head from `lines`, terminated the way the parser looks for.
private func head(to path: String = "/api/topic", _ lines: String...) -> Data {
    Data(("POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n" + lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
}

/// A chunked request carrying `json`, written the way a client sends one: a hex size line, the bytes, then
/// a zero-size chunk and the terminator.
private func chunkedRequest(_ json: String, to path: String = "/api/topic") -> Data {
    var request = head(to: path, "Content-Type: application/json", "Transfer-Encoding: chunked")
    request.append(Data("\(String(json.utf8.count, radix: 16))\r\n\(json)\r\n0\r\n\r\n".utf8))
    return request
}

/// A request carrying `json` under a `Content-Length`: the same bytes, framed the way this server reads.
private func framedRequest(_ json: String, to path: String = "/api/topic") -> Data {
    var request = head(to: path, "Content-Type: application/json", "Content-Length: \(json.utf8.count)")
    request.append(Data(json.utf8))
    return request
}

/// Parse a request and hand back the refusal, so a test can assert on the case rather than on a string.
private func refusal(_ data: Data) -> HTTPError? {
    do {
        _ = try HTTPParser.parse(data)
        return nil
    } catch let error as HTTPError {
        return error
    } catch {
        return nil
    }
}

@Suite("A body the server cannot frame is refused, not read as empty (A153)")
struct TransferEncodingParserTests {

    @Test("A chunked body is refused as unsupported rather than parsed as empty")
    func chunkedIsUnsupported() {
        let refused = refusal(chunkedRequest(#"{"topic": "a chunked topic"}"#))
        guard case .unsupportedTransferEncoding(let coding)? = refused else {
            Issue.record("expected the transfer coding to be refused, got \(String(describing: refused))")
            return
        }
        #expect(coding == "chunked")
        #expect(refused?.statusCode == 501, "a coding this server does not implement is Not Implemented")
    }

    @Test("The header name and its value are matched however they are spelled")
    func casingDoesNotMatter() {
        // Field names are case-insensitive and a client may spell the coding in any case. Both of these
        // used to be invisible, because the header was never read at all.
        for spelling in ["transfer-encoding: chunked", "TRANSFER-ENCODING: Chunked"] {
            guard case .unsupportedTransferEncoding? = refusal(head("Content-Type: application/json", spelling))
            else {
                Issue.record("\"\(spelling)\" was not refused")
                return
            }
        }
    }

    @Test("A coding other than chunked is refused too, not ignored")
    func unknownCodingIsRefused() {
        // `gzip` is a coding this server does not implement either. Ignoring the header would read the
        // compressed bytes as the body, which is the same silent misread in a different costume.
        guard case .unsupportedTransferEncoding(let coding)? = refusal(head("Transfer-Encoding: gzip"))
        else {
            Issue.record("an unimplemented coding was not refused")
            return
        }
        #expect(coding == "gzip")
    }

    @Test("Both framings at once is a 400, the smuggling shape")
    func bothFramingsAreRefused() {
        var request = head(
            "Content-Type: application/json", "Content-Length: 5", "Transfer-Encoding: chunked")
        request.append(Data("hello".utf8))

        let refused = refusal(request)
        guard case .malformed(let reason)? = refused else {
            Issue.record("expected a malformed-request refusal, got \(String(describing: refused))")
            return
        }
        #expect(reason.contains("Transfer-Encoding"), "the answer should name what it objected to")
        #expect(refused?.statusCode == 400)
    }

    @Test("A declared coding with no value is malformed, not unsupported")
    func emptyCodingIsMalformed() {
        guard case .malformed? = refusal(head("Transfer-Encoding:")) else {
            Issue.record("an empty Transfer-Encoding was not refused as malformed")
            return
        }
    }

    @Test("A request with the same body and a Content-Length still parses, body included")
    func theCounterweightStillParses() throws {
        // The fix must refuse the framing, not the request.
        let json = #"{"topic": "a chunked topic"}"#
        let parsed = try HTTPParser.parse(framedRequest(json))
        #expect(parsed.method == "POST")
        #expect(parsed.path == "/api/topic")
        #expect(String(bytes: parsed.body, encoding: .utf8) == json)
    }
}

@MainActor
@Suite("A chunked request does not change the room (A153)")
struct TransferEncodingWireTests {

    /// Send raw bytes and read the first response, so the request can be framed by hand — `URLSession`
    /// always writes a `Content-Length` and cannot produce the request this is about.
    private func exchange(_ fixture: APIServerFixture, _ bytes: Data) async throws -> String {
        let client = try RawConnection(port: fixture.port)
        defer { client.cancel() }
        #expect(await client.connect())
        client.send(bytes)
        guard let reply = await client.receiveOnce(timeout: .seconds(5)) else {
            Issue.record("the server answered nothing")
            return ""
        }
        return String(bytes: reply, encoding: .utf8) ?? ""
    }

    private func setTopic(_ fixture: APIServerFixture, _ topic: String) async throws -> Int {
        let url = try #require(URL(string: "\(fixture.base)/api/topic"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"topic": "\#(topic)"}"#.utf8)
        let (_, response) = try await fixture.session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    @Test("A chunked topic change is answered 501 and leaves the topic alone")
    func chunkedTopicIsRefused() async throws {
        let fixture = try await makeAPIServerFixture()
        defer { fixture.server.stop() }

        // A topic the chunked request must not disturb.
        let set = try await setTopic(fixture, "the first topic")
        #expect(set == 200)
        #expect(try await stateField(fixture.session, fixture.base, "topic") == "the first topic")

        let reply = try await exchange(fixture, chunkedRequest(#"{"topic": "a chunked topic"}"#))
        #expect(
            reply.hasPrefix("HTTP/1.1 501"),
            "a chunked request should be refused as Not Implemented, was \(reply.prefix(60))")

        let topic = try await stateField(fixture.session, fixture.base, "topic")
        #expect(
            topic == "the first topic",
            "the route ran on a body that was never decoded: \(topic ?? "nil")")
    }

    @Test("A chunked upload is refused, not answered as a missing route")
    func chunkedUploadIsRefused() async throws {
        // The upload is the largest body this server takes and the one a proxy is most likely to forward
        // chunked, and its route reads the body through the same `command(from:)`. With the body dropped
        // it fell through every guard and answered 404 for a route that exists.
        let fixture = try await makeAPIServerFixture()
        defer { fixture.server.stop() }

        let payload = Data("a small document".utf8).base64EncodedString()
        let json = #"{"filename": "note.txt", "content": "\#(payload)"}"#
        let reply = try await exchange(fixture, chunkedRequest(json, to: "/api/attachments"))
        #expect(
            reply.hasPrefix("HTTP/1.1 501"),
            "a chunked upload should be refused as Not Implemented, was \(reply.prefix(60))")
    }

    @Test("The same request with a Content-Length is accepted and changes the topic")
    func theCounterweightIsAccepted() async throws {
        // Without this, "refuses chunked requests" and "refuses POSTs" look the same from outside.
        let fixture = try await makeAPIServerFixture()
        defer { fixture.server.stop() }

        let reply = try await exchange(fixture, framedRequest(#"{"topic": "a framed topic"}"#))
        #expect(reply.hasPrefix("HTTP/1.1 200"), "was \(reply.prefix(60))")
        #expect(try await stateField(fixture.session, fixture.base, "topic") == "a framed topic")
    }

    @Test("A chunked request that also declares a length is answered 400")
    func bothFramingsOverTheWire() async throws {
        let fixture = try await makeAPIServerFixture()
        defer { fixture.server.stop() }

        let json = #"{"topic": "smuggled"}"#
        var request = head(
            "Content-Type: application/json", "Content-Length: \(json.utf8.count)",
            "Transfer-Encoding: chunked")
        request.append(Data("\(String(json.utf8.count, radix: 16))\r\n\(json)\r\n0\r\n\r\n".utf8))

        let reply = try await exchange(fixture, request)
        #expect(reply.hasPrefix("HTTP/1.1 400"), "was \(reply.prefix(60))")
        let topic = try await stateField(fixture.session, fixture.base, "topic")
        #expect(topic != "smuggled", "the smuggling request was acted on")
    }
}
