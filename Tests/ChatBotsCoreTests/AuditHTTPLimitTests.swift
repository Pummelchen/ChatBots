// ChatBotsCoreTests — a stalled or surplus HTTP connection is not held forever (audit A37)
//
// The listener had no read or idle deadline and no connection cap, so a peer could open
// connections, send a partial head and stall, pinning a connection, its buffer and its table
// entry until `stop()`. The arithmetic then changed under the finding: A32 raised
// `HTTPParser.maximumBodyBytes` from 8 MB to the base64 form of the 64 MB attachment limit
// (about 85.4 MB), so a stalled connection can now hold roughly ten times as much.
//
// These tests open real loopback connections and observe the server's own counts, which is the
// only place the difference is visible — a stalled connection leaves no reply to read.

import ChatBotsCore
import Dispatch
import Foundation
import Network
import Synchronization
import Testing

/// A raw loopback connection a test drives byte by byte.
@MainActor
private final class RawConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "chatbots.test.raw-http-limits")

    init(port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw HTTPLimitTestError.badPort(port)
        }
        connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"), port: endpointPort, using: .tcp)
    }

    func connect(timeout: Duration = .seconds(5)) async -> Bool {
        connection.start(queue: queue)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            switch connection.state {
            case .ready: return true
            case .failed, .cancelled: return false
            default: break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func send(_ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    /// The next bytes the server sends, or `nil` if none arrive before `timeout`.
    ///
    /// `NWConnection.receive` has no deadline of its own, so the wait is raced against a timer
    /// on the client's own queue. `resumed` makes the race safe: whichever of the receive and
    /// the timer arrives first wins, and the continuation is resumed exactly once.
    func receiveOnce(timeout: Duration) async -> Data? {
        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1_000_000_000_000_000_000
        return await withCheckedContinuation { continuation in
            let resumed = Atomic<Bool>(false)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, _, _ in
                if !resumed.exchange(true, ordering: .relaxed) {
                    continuation.resume(returning: data)
                }
            }
            queue.asyncAfter(deadline: .now() + seconds) {
                if !resumed.exchange(true, ordering: .relaxed) {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func cancel() { connection.cancel() }
}

private enum HTTPLimitTestError: Error {
    case noPort
    case badPort(UInt16)
}

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
struct AuditHTTPLimitTests {

    /// The finding, made observable: a partial request followed by silence. `connectionCount`
    /// is the assertion because a stalled peer never receives a reply to read.
    @Test("A connection that sends a partial request and stalls is dropped")
    func stalledConnectionIsReaped() async throws {
        let (server, port) = try await startServer(maximumConnections: 8, requestTimeout: 1)
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
