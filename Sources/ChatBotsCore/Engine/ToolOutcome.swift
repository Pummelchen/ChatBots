// ChatBotsCore — the result of a tool call, and this package's errors
//
// Split out of `ChatModels.swift`, which held the whole shared vocabulary in one 862-line file. The
// types did not change; only the file each one lives in did.

import Foundation

/// Result of a tool invocation.
public struct ToolOutcome: Sendable {
    /// Full text handed to the model.
    public var text: String
    /// One-line summary for the transcript.
    public var summary: String

    public init(text: String, summary: String) {
        self.text = text
        self.summary = summary
    }
}

// MARK: - Errors

public enum ChatBotsError: LocalizedError, Sendable {
    case emptyTopic
    case engineNotLoaded
    case toolFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyTopic: "Please enter a topic before starting."
        case .engineNotLoaded: "The model is not loaded yet."
        case .toolFailed(let message): "Tool failed: \(message)"
        case .cancelled: "Cancelled."
        }
    }
}


extension Array {
    /// Bounds-checked lookup, for optional per-seat configuration lists.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
