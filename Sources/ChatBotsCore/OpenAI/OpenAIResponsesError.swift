// ChatBotsCore — what a failed response reports
//
// Split out of `OpenAIResponsesClient.swift`, which held the client, its endpoint configuration, the
// compatibility and naming tables and its session wrapper in one 860-line file. Nothing changed but
// which file each one lives in.

import Foundation

public enum OpenAIResponsesError: LocalizedError, Sendable {
    case badURL(String)
    /// An endpoint this client will not send to, and the rule that refused it.
    case refusedEndpoint(String, reason: String)
    case http(status: Int, body: String)
    case streamFailed(String)
    case noOutput
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .badURL(let value):
            "Not a usable base URL: \(value)"
        case .refusedEndpoint(let value, let reason):
            "The endpoint \(value) is not used: \(reason)."
        case .http(let status, let body):
            "Server returned HTTP \(status): \(UTF8Text.prefix(body, 300))"
        case .streamFailed(let message):
            "The response failed: \(message)"
        case .noOutput:
            "The server completed the response without producing any text."
        case .cancelled:
            "Cancelled."
        }
    }
}

/// Which parameters an endpoint will accept.
///
/// The Responses API's schema is fixed but not every implementation tolerates unknown
