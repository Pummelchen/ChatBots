// ChatBotsCore — the live event feed one HTTP connection carries
//
// Split out of `HTTPServer.swift`, which held the server, its request intake, its response writing and
// the server-sent-event stream a client keeps open in one file. `EventStream` is the whole of the wire
// format for that one connection and needs none of the server's state, so it is the seam with the least
// coupling. The type did not change.

import Foundation
import Network

extension HTTPServer {

    /// A live event feed for one connection.
    ///
    /// `@unchecked Sendable` because its mutable state — `open` and the in-flight frame count —
    /// is confined to `lock`: `send`, `close`, `isOpen` and `markClosed` each take `lock` before
    /// reading or writing it, and the send completion takes it too, so no access site can see a
    /// torn or stale value. `connection` is a `let` and every call on it is handed to the
    /// Network framework, which serialises the work on the queue the connection was started on.
    public final class EventStream: @unchecked Sendable {
        private let connection: NWConnection
        private let lock = NSLock()
        private var open = true

        /// Frames handed to the transport whose completion has not fired yet.
        ///
        /// `NWConnection.send`'s completion is gated by the peer's receive window, so a client
        /// that opens `/api/events` and stops reading leaves one frame per model token in flight
        /// with nothing draining them — and the API broadcasts on every token. Past
        /// `maximumPendingFrames` the stream is closed: a client that cannot keep up with a live
        /// conversation is not one this server can keep feeding, and the alternative is
        /// unbounded memory inside Network.framework.
        private var pending = 0

        /// The most frames that may be in flight before the client is treated as gone.
        static let maximumPendingFrames = 256

        init(connection: NWConnection) {
            self.connection = connection
        }

        /// Write one server-sent event. Silently ignored once the client has gone.
        public func send(_ payload: String, event: String? = nil) {
            lock.lock()
            defer { lock.unlock() }
            guard open else { return }
            guard pending < Self.maximumPendingFrames else {
                // Too far behind to catch up: stop rather than queue without bound.
                open = false
                connection.cancel()
                return
            }
            var frame = ""
            if let event { frame += "event: \(event)\n" }
            // A data field cannot contain a bare newline, so a multi-line payload is split
            // across several `data:` lines as the format requires.
            for line in payload.split(separator: "\n", omittingEmptySubsequences: false) {
                frame += "data: \(line)\n"
            }
            frame += "\n"
            pending += 1
            connection.send(
                content: Data(frame.utf8),
                completion: .contentProcessed { [weak self] _ in
                    guard let self else { return }
                    self.lock.lock()
                    self.pending -= 1
                    self.lock.unlock()
                })
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
}
