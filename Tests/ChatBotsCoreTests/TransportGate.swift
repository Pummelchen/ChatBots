// ChatBotsCoreTests — one QUIC runtime at a time.
//
// `.serialized` orders the tests *within* a suite. It does nothing about two suites running at the
// same time, and five suites in this target drive a real WebTransport listener or client. When two of
// them overlap, Network.framework aborts the entire test process:
//
//     Network/Connection.swift:5833: Fatal error: Neither nw nor nwGroup is initialized
//
// which reads as a catastrophic product failure rather than as a test-runtime collision, and which
// Phase E would have reported as a crash (A102, and one of A108's two sources of flakiness).
// Serialising the suites was the recorded next step, and this is that, applied across suites rather
// than within each of them. `.serialized` stays on each suite because the tests that bind a fixed
// port also need their own ordering.
//
// A note on what this is not: it does not make the transport *libraries* safe to use concurrently,
// and nothing here claims they are. It constrains the tests that exercise them, which is the part
// this repository controls.

import Testing

/// Admits one holder at a time, and releases them in the order they arrived.
///
/// A `CheckedContinuation` queue rather than a semaphore because the wait has to be `async`:
/// blocking a cooperative thread while another test needs it to make progress is a deadlock, and
/// under a bounded thread pool it is a reliable one.
actor TransportGate {
    static let shared = TransportGate()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the gate to the next waiter, or frees it when there is none.
    ///
    /// The waiter resumes holding the gate — `busy` stays true — so a test cannot slip in between
    /// the handover and the resumption.
    func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Serialises every suite that drives a real QUIC listener or client.
///
/// Applied as a suite trait, so a suite cannot be added to this file's list and then forgotten: the
/// gate is taken for each of its tests whether or not the author of a new transport suite remembers
/// to think about concurrency.
struct TransportSerialized: SuiteTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await TransportGate.shared.acquire()
        do {
            try await function()
        } catch {
            // Released on the throwing path too; a leaked gate would deadlock every later transport
            // test, which is a worse failure than the one this trait exists to prevent.
            await TransportGate.shared.release()
            throw error
        }
        await TransportGate.shared.release()
    }
}
