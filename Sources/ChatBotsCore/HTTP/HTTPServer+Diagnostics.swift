// ChatBotsCore — what went wrong on the listener, and how to observe it
//
// Split out of `HTTPServer.swift`, which held the failure ring the health endpoint answers from next to
// the server that fills it. These are the declarations a live engine is diagnosed with: the bounded
// record of what failed, the counter of connections refused for being over the cap, and the probe the
// app uses to ask whether the port already answers. The code did not change.

import Foundation
import Network

extension HTTPServer {

    /// One thing that went wrong on this listener, kept so a live engine can be diagnosed.
    public struct ConnectionFailure: Sendable, Equatable, Codable {
        /// What happened, in a sentence: a connection error, a request the parser refused, a connection
        /// refused for being over the limit.
        public var reason: String
        public var at: Date
    }

    /// How many failures are kept.
    ///
    /// Bounded, because anyone who can reach the port can produce one: an unbounded log of a server that
    /// listens on every interface is a memory leak wearing a diagnostics label.
    public static let failureHistoryLimit = 20

    /// The most recent failures, newest first.
    ///
    /// Alongside that log: the counters below existed and were reachable from no endpoint, and
    /// a client that walked away mid-request was `_ = error`'d out of existence, so diagnosing a running
    /// engine meant reading source. `APIServer` serves this on `/api/health`.
    public var recentFailures: [ConnectionFailure] {
        failureLock.lock()
        defer { failureLock.unlock() }
        return failures
    }
    /// Record one failure, keeping the newest `failureHistoryLimit`.
    ///
    /// Internal rather than private so the tests can drive the ring without a socket, and because the
    /// network queue and the main actor both call it: the lock is the whole of the synchronisation.
    func note(_ reason: String) {
        failureLock.lock()
        defer { failureLock.unlock() }
        failures.insert(ConnectionFailure(reason: reason, at: .now), at: 0)
        if failures.count > Self.failureHistoryLimit {
            failures.removeLast(failures.count - Self.failureHistoryLimit)
        }
    }
    /// How many connections have been refused for being over `maximumConnections`.
    ///
    /// Counted and answerable because the finding's other half was that nothing reported this
    /// at all. Read under `stateLock`, like every other access to the connection tables.
    public var refusedConnectionCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return refusals
    }
    /// Whether anything already accepts a connection on this port.
    ///
    /// A blocking connect to loopback with a short timeout. A listener accepts immediately, and
    /// this needs nothing else to be true for the answer to be useful.
    /// Public because the app has to ask the same question before it decides whether to start
    /// an engine of its own: a port that answers but does not speak the app's transport is a
    /// situation to report, not one to bulldoze with a second engine.
    public static func isSomethingListening(on port: UInt16) -> Bool {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { close(handle) }

        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = setsockopt(
            handle, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        // Darwin's sockaddr_in carries its own length and `connect` rejects the address without
        // it — silently, with EINVAL, which reads here as "nothing is listening" and is exactly
        // the wrong answer. This was the bug in the first version of this check.
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(handle, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }
}
