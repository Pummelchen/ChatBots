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
}
