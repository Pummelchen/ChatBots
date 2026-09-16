// ChatBotsCore — what the server reports when a request cannot be read
//
// Split out of `HTTPServer.swift`, which held the request and response types, the parser, the errors
// and the server in one 1100-line file. Nothing changed but which file each one lives in.

import Foundation

public enum HTTPError: LocalizedError {
    case malformed(String)
    case tooLarge
    case headTooLarge
    case portInUse(UInt16)
    /// A body the server cannot frame because it does not implement the coding asked for.
    case unsupportedTransferEncoding(String)
    /// An HTTP version this server does not speak.
    case unsupportedVersion(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let reason): "Malformed request: \(reason)"
        case .tooLarge: "Request body is too large"
        case .headTooLarge: "Request headers are too large"
        case .portInUse(let port): "Port \(port) is already in use"
        case .unsupportedTransferEncoding(let coding):
            "Transfer-Encoding is not supported: \(coding). Send a Content-Length instead."
        case .unsupportedVersion(let version):
            "HTTP version is not supported: \(version). This server speaks HTTP/1.1."
        }
    }

    /// The status a client is answered with. 431 for a head that cannot fit is the code that exists
    /// for it; 413 is the body's; 501 is what RFC 9112 §6.1 asks for when the recipient does not
    /// implement the transfer coding it was sent.
    public var statusCode: Int {
        switch self {
        case .headTooLarge: 431
        case .tooLarge: 413
        case .unsupportedTransferEncoding: 501
        case .unsupportedVersion: 505
        case .malformed, .portInUse: 400
        }
    }
}

// MARK: - Server

/// Serves a routing closure over HTTP on a port, on the loopback interface only.
///
/// `@unchecked Sendable` with the parts written down, because the compiler cannot check them:
/// `connections`, `streams`, `idleDeadlines`, `refusals`, `running` and `failure` are read and
/// written under `stateLock`, and no lock is held across a call that could re-enter this type.
/// `listener` is only touched by `start()` and `stop()`, which the owning actor calls.
///
/// ThreadSanitizer is what verifies the claim rather than the comment: it reported a data race on
/// `isRunning` while every one of 555 tests passed, and inspection alongside it found `streams`
/// being appended without the lock that every other access to it takes.
