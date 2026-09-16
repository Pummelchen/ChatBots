// ChatBotsCoreTests — a stalled or surplus HTTP connection is not held forever
//
// The listener had no read or idle deadline and no connection cap, so a peer could open
// connections, send a partial head and stall, pinning a connection, its buffer and its table
// entry until `stop()`. The arithmetic then changed under the finding:
// `HTTPParser.maximumBodyBytes` was raised from 8 MB to the base64 form of the 64 MB attachment
// limit (about 85.4 MB), so a stalled connection can now hold roughly ten times as much.
//
// These tests open real loopback connections and observe the server's own counts, which is the
// only place the difference is visible — a stalled connection leaves no reply to read.

import ChatBotsCore
import Dispatch
import Foundation
import Network
import Synchronization
import Testing

/// A server that answers every request with `ok`, on a port of its own.
@MainActor
private func startServer(
    maximumConnections: Int, requestTimeout: TimeInterval
) async throws -> (HTTPServer, UInt16) {
    for _ in 0..<8 {
        let port = allocateTestPort()
        let server = HTTPServer(
            port: port,
            handler: { _ in .text("ok") },
            maximumConnections: maximumConnections,
            requestTimeout: requestTimeout)
        try server.start()
        if await server.waitUntilReady() { return (server, port) }
        server.stop()
    }
    throw HTTPLimitTestError.noPort
}

@MainActor
@Suite("HTTP connections have limits", .serialized)
struct HTTPLimitTests {

    /// The finding, made observable: a partial request followed by silence. `connectionCount`
    /// is the assertion because a stalled peer never receives a reply to read.
    @Test("A connection that sends a partial request and stalls is dropped")
    func stalledConnectionIsReaped() async throws {
        // Three seconds, not one. The idle deadline is what the test is about, but the first assertion has to
        // *see* the registered connection, and this suite shares the main actor with everything else: in a
        // busy instrumented gate the polling loop below can be kept off the actor for longer than a
        // one-second deadline, miss the window entirely, and report a registration that did happen as one
        // that did not. A longer deadline keeps the race out of the test without weakening either assertion.
        let (server, port) = try await startServer(maximumConnections: 8, requestTimeout: 3)
        defer { server.stop() }

        let client = try RawConnection(port: port)
        defer { client.cancel() }
        #expect(await client.connect())
        // A declared body that never arrives: the request is incomplete, and the peer is gone.
        client.send(
            "POST /api/attachments HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 1000\r\n\r\n")

        let registered = ContinuousClock.now.advanced(by: .seconds(5))
        while server.connectionCount == 0, ContinuousClock.now < registered {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(server.connectionCount == 1, "the partial request should have been accepted")

        let reaped = ContinuousClock.now.advanced(by: .seconds(6))
        while server.connectionCount > 0, ContinuousClock.now < reaped {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(
            server.connectionCount == 0,
            "a connection that sent nothing for longer than the idle deadline was held open")

        // And it was told why rather than dropped in silence.
        let response = await client.receiveOnce(timeout: .seconds(4))
        #expect(response.map { String(decoding: $0, as: UTF8.self).contains("408") } == true)
    }

    /// The other half of the finding: `connections` had no maximum at all.
    @Test("The parser refuses a head that cannot fit, and still parses one that does")
    func parserRefusesAnOversizedHead() throws {
        // The head has its own cap now: a request whose head cannot fit is refused rather than
        // accumulated and rescanned.
        let unterminated = Data(repeating: 0x41, count: HTTPParser.maximumHeadBytes + 1)
        do {
            _ = try HTTPParser.parse(unterminated)
            Issue.record("a head past the cap must be refused")
        } catch let error as HTTPError {
            guard case .headTooLarge = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }

        // The counterweight: an ordinary head is unaffected, and the terminator is still found when it
        // arrives in pieces — the search window is a cap on the search, not on what may be parsed.
        let ok = Data("GET /api/state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        let request = try HTTPParser.parse(ok)
        #expect(request.method == "GET")
        #expect(request.path == "/api/state")

        // A head that fits, split across the window boundary, is still found.
        var split = Data(repeating: 0x41, count: HTTPParser.maximumHeadBytes - 2)
        split.append(Data("\r\n\r\n".utf8))
        do {
            _ = try HTTPParser.parse(split)
            Issue.record("this is not a valid request line, so it must be malformed rather than incomplete")
        } catch let error as HTTPError {
            guard case .malformed = error else {
                Issue.record("expected a malformed request, got \(error)")
                return
            }
        }
    }

    @Test("A connection whose head cannot fit is answered 431")
    func oversizedHeadOverTheWireIsRefused() async throws {
        let (server, port) = try await startServer(maximumConnections: 8, requestTimeout: 10)
        defer { server.stop() }
        let client = try RawConnection(port: port)
        #expect(await client.connect())
        defer { client.cancel() }

        // Never terminated, and past the cap: one write, so the size is what the server reacts to.
        var head = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        let line = "X-Pad: " + String(repeating: "a", count: 900) + "\r\n"
        head += String(repeating: line, count: HTTPParser.maximumHeadBytes / line.count + 4)
        client.send(head)

        let response = await client.receiveOnce(timeout: .seconds(5))
        let text = String(data: response ?? Data(), encoding: .utf8) ?? ""
        #expect(
            text.hasPrefix("HTTP/1.1 431"),
            "a head that cannot fit is 431 Request Header Fields Too Large, was \(text.prefix(40))")
    }

    @Test("Connections over the cap are refused rather than entered in the table")
    func connectionsOverTheCapAreRefused() async throws {
        let ceiling = 2
        let (server, port) = try await startServer(
            maximumConnections: ceiling, requestTimeout: 30)
        defer { server.stop() }

        var held: [RawConnection] = []
        for _ in 0..<ceiling {
            let client = try RawConnection(port: port)
            #expect(await client.connect())
            // Incomplete on purpose: each holds its slot for the duration of the test.
            client.send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n")
            held.append(client)
        }
        defer { for client in held { client.cancel() } }

        let settled = ContinuousClock.now.advanced(by: .seconds(5))
        while server.connectionCount < ceiling, ContinuousClock.now < settled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(server.connectionCount == ceiling)

        let surplus = try RawConnection(port: port)
        defer { surplus.cancel() }
        #expect(await surplus.connect())
        surplus.send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

        let reply = await surplus.receiveOnce(timeout: .seconds(4))
        let text = reply.map { String(decoding: $0, as: UTF8.self) }
        #expect(text?.contains("503") == true, "a connection over the cap should be refused")
        #expect(server.refusedConnectionCount == 1)
        #expect(server.connectionCount == ceiling, "the refused connection entered the table")
    }
}
