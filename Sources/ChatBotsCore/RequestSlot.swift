// ChatBotsCore — one request at a time, and the waiters behind it
//
// Extracted from `WebTransportEngineClient` when that file went past its length budget (A158). It is a
// named thing with an invariant rather than a pair of flags: the wire protocol carries no correlation id —
// `EngineFrame.reply` is the reply and nothing else — so a reply can only be matched while exactly one
// request is outstanding, and the gate that guarantees that is this type.

import Foundation

/// The request channel a client holds while one request is outstanding.
///
/// The client used to *claim* that only one request could be in flight and enforce nothing: every send
/// appended its continuation and the reader gave each reply to the first entry. `ChatController` polls
/// `state()` at 1 Hz beside a user's command, so two sends overlap routinely; the two writes can reach the
/// wire in either order, and a reply was then delivered to the wrong waiter or dropped. The gate is here
/// so the claim is true.
@MainActor
final class RequestSlot {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Take the channel, waiting for it if a send already holds it.
    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Hand the channel to the next waiter, or release it.
    ///
    /// Handed straight over rather than released and re-taken, so two sends can never both believe they
    /// hold it — which is the whole of the invariant this type exists for.
    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
