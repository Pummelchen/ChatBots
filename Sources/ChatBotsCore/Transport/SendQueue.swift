// ChatBotsCore — one writer at a time on a session's stream
//
// Split out of `WebTransportServerSession.swift` so the primitive is named and testable rather
// than implied by a comment.

import Foundation

/// Serialises the writes to one session's stream.
///
/// `send`'s own comment says it is "the one place that serialises them", but `@MainActor`
/// isolation is reentrant at an `await`: the per-session writer task and the reply path both call
/// `send`, and `send` awaits the transport, so two callers could be inside it at once. This is the
/// primitive that makes the claim true — each operation waits for the one queued before it, so a
/// reply and an event can never interleave their bytes.
actor SendQueue {
    private var tail: Task<Void, Never>?

    /// Run `operation` after every operation already queued has finished.
    func run(_ operation: @escaping @Sendable () async -> Void) async {
        let previous = tail
        let task = Task {
            await previous?.value
            await operation()
        }
        tail = task
        await task.value
    }
}
