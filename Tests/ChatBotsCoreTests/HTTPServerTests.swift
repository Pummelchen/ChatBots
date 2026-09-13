// ChatBotsCoreTests — what the HTTP server holds on to
//
// The event feed is a server-sent stream: the server answers the request and then leaves the
// socket open. A connection like that never returns to the read loop that notices the client
// has gone, so unless something else watches it the stream and the connection are retained for
// the life of the process — one pair per page reload. These tests open a real streaming
// connection, drop it the way a browser navigating away does, and assert the server's own
// counts come back to where they started.
//
// The counts are observed through `openStreamCount` and `connectionCount`, which were added
// with the fix: `streams` and `connections` are private and there was no way to see the leak
// from outside.

import ChatBotsCore
import Foundation
import Network
import Testing

/// A raw loopback connection, so a test can open a streaming request and then pull the socket
/// out from under it. `URLSession` computes its own headers, waits for a complete body and owns
/// the connection, none of which this needs.
@MainActor
private final class RawHTTPClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "chatbots.test.raw-http")

    init(port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerTestError.badPort(port)
        }
        connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"), port: endpointPort, using: .tcp)
    }

    /// Connect and wait for the socket to be usable.
    ///
    /// Polled rather than driven by `stateUpdateHandler`, which is `@Sendable` and one-shot;
    /// polling also yields to the main actor so the server's own main-actor task can run.
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

    func cancel() { connection.cancel() }
}

private enum ServerTestError: Error {
    case noPort
    case badPort(UInt16)
}

/// A server that answers one event to `/api/events`, on a port of its own.
@MainActor
private func startStreamingServer() async throws -> (HTTPServer, UInt16) {
    for _ in 0..<8 {
        let port = allocateTestPort()
        let server = HTTPServer(
            port: port,
            handler: { _ in .text("ok") },
            streamer: { request, _ in
                request.path == "/api/events" ? [#"{"topic":"a streaming test"}"#] : []
            })
        try server.start()
        // `start()` returning is not evidence that anything is listening; a taken port is
        // reported asynchronously, so the test asks.
        if await server.waitUntilReady() { return (server, port) }
        server.stop()
    }
    throw ServerTestError.noPort
}

@MainActor
@Suite("HTTP server reaping", .serialized)
struct HTTPServerReapingTests {

    @Test("A streaming client that goes away is pruned from the server's books")
    func closedStreamIsReaped() async throws {
        let (server, port) = try await startStreamingServer()
        defer { server.stop() }

        let streamsAtRest = server.openStreamCount
        let connectionsAtRest = server.connectionCount
        #expect(streamsAtRest == 0)
        #expect(connectionsAtRest == 0)

        let client = try RawHTTPClient(port: port)
        #expect(await client.connect())
        client.send(
            "GET /api/events HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n")

        // The stream is registered from a task the server hops onto the main actor, so it is
        // waited for rather than assumed. The wait is bounded, so a server that never registers
        // it fails the test instead of hanging it.
        let opened = ContinuousClock.now.advanced(by: .seconds(5))
        while server.openStreamCount == 0, ContinuousClock.now < opened {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(server.openStreamCount == 1, "the streaming connection should be registered")
        #expect(server.connectionCount == 1)

        // The browser closes the page, or the tab is dropped: the socket goes away and the
        // server has to notice even though it is not reading requests on it any more.
        client.cancel()

        let closed = ContinuousClock.now.advanced(by: .seconds(5))
        while server.openStreamCount > streamsAtRest || server.connectionCount > connectionsAtRest,
            ContinuousClock.now < closed
        {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            server.openStreamCount == streamsAtRest,
            "a closed stream must not be retained for the life of the process")
        #expect(
            server.connectionCount == connectionsAtRest,
            "a closed connection must be released")
    }
}
