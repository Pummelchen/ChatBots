// ChatBotsCoreTests — a raw loopback connection, for tests that need to write HTTP by hand
//
// Extracted from `AuditHTTPLimitTests` (A37) when a second suite needed it (A151). A malformed request
// cannot be produced by `URLSession`, and the server's own reaction to one is what those tests are about,
// so the bytes are written directly.

import ChatBotsCore
import Dispatch
import Foundation
import Network
import Synchronization
import Testing

/// A raw loopback connection a test drives byte by byte.
@MainActor
final class RawConnection {
    let connection: NWConnection
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

enum HTTPLimitTestError: Error {
    case noPort
    case badPort(UInt16)
}
