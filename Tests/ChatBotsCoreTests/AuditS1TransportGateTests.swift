// ChatBotsCoreTests — the transport gate survives cancellation (A168).
//
// `TransportGate` serialises the five suites that drive a real QUIC listener, because two of them
// overlapping aborts the whole test process inside Network.framework (A102). It parked a waiter on a
// `CheckedContinuation` with no cancellation handler, so a test cancelled while queued left its
// continuation in the queue: `release()` then handed the gate to a task that would never resume, and
// every later transport suite waited forever. A hung suite reads as a product hang, not as a harness
// defect, which is why this is a test rather than a note.
//
// Both tests wait for the queue to become observable before cancelling, and each states its
// assertions about the gate before it awaits the cancelled task, so the old implementation records
// failures here instead of only hanging. Both end by taking the gate again — the call that never
// returns under the leak.

import Testing

@Suite("The transport gate survives cancellation (A168)")
struct AuditS1TransportGateTests {
    @Test("A waiter cancelled while queued does not take the gate with it")
    func cancelledWaiterDoesNotTakeTheGate() async throws {
        let gate = TransportGate()
        try await gate.acquire()

        let waiter = Task { try await gate.acquire() }
        #expect(await waitUntil { await gate.waitingCount > 0 }, "the second caller is queued")

        waiter.cancel()
        #expect(
            await waitUntil { await gate.waitingCount == 0 },
            "a cancelled waiter leaves the queue instead of staying in it")

        await gate.release()
        let held = await gate.isHeld
        #expect(!held, "the gate is free, not handed to a task that is gone")

        // Only true once the two assertions above hold; under the leak this never returns.
        await #expect(throws: CancellationError.self) { try await waiter.value }

        try await gate.acquire()
        let heldAgain = await gate.isHeld
        #expect(heldAgain)
        await gate.release()
    }

    @Test("A cancelled waiter does not block the live waiter behind it")
    func theLiveWaiterBehindACancelledOneIsAdmitted() async throws {
        let gate = TransportGate()
        try await gate.acquire()

        let cancelled = Task { try await gate.acquire() }
        #expect(await waitUntil { await gate.waitingCount > 0 })

        cancelled.cancel()
        #expect(
            await waitUntil { await gate.waitingCount == 0 },
            "the cancelled waiter is gone from the queue")
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        let live = Task { try await gate.acquire() }
        #expect(await waitUntil { await gate.waitingCount > 0 }, "the live waiter is queued")

        await gate.release()
        try await live.value
        let held = await gate.isHeld
        #expect(held, "the live waiter holds the gate after the handover")

        await gate.release()
        let free = await gate.isHeld
        #expect(!free)
    }
}

/// Yields until `condition` holds, or the attempt budget runs out; returns whether it held.
///
/// A state observation rather than a sleep, and bounded so that a gate which never reaches the state
/// fails the assertion above it instead of hanging the suite.
private func waitUntil(attempts: Int = 10_000, _ condition: () async -> Bool) async -> Bool {
    var remaining = attempts
    while !(await condition()) {
        if remaining == 0 { return false }
        remaining -= 1
        await Task.yield()
    }
    return true
}
