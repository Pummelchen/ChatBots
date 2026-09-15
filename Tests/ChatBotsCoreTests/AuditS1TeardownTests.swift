// ChatBotsCoreTests — the gate waits for a test's teardown (A169).
//
// The five transport suites each ended with `defer { Task { await running.stop() } }`, which returns
// immediately: the gate was released while the listener was still closing, so the next transport
// suite acquired it into the overlap the gate exists to prevent. A `defer` cannot await, so teardown
// is registered and drained before the release.
//
// The first test below is the one that discriminates the fix. It drives `TransportSerialized.withGate`
// — the exact function `provideScope` delegates to — with a gate of its own, so the sequence is
// observed rather than assumed, and it needs no ordering assumption between tests. The other three are
// unit tests of the registry's ordering and clearing rules and pass either way; they are here because
// those rules are what the first test relies on.

import Testing

@MainActor
@Suite("The gate waits for a registered teardown (A169)", .serialized, TransportSerialized())
struct AuditS1TeardownTests {

    @Test("A registered teardown is awaited while the gate is still held")
    func teardownIsAwaitedBeforeRelease() async throws {
        // A gate of its own: this test is already inside the suite's scope, which holds the shared one,
        // so using that here would deadlock. Everything else about the sequence is the real one.
        let gate = TransportGate()
        var finished = false
        var heldDuringTeardown: Bool?

        try await TransportSerialized.withGate(gate: gate) {
            TransportTeardown.register {
                try? await Task.sleep(for: .milliseconds(50))
                finished = true
                heldDuringTeardown = await gate.isHeld
            }
            #expect(finished == false, "the teardown has not run while the body is running")
        }

        // Back here `withGate` has returned, which means it drained and then released. It cannot have
        // released before the teardown finished, or the sleep above would not have completed yet.
        #expect(finished, "the registered teardown must have run before the gate was released")
        #expect(heldDuringTeardown == true, "and while the gate was still held")
        let free = await gate.isHeld
        #expect(!free, "and the gate must be released once the teardown is done")
    }

    @Test("The body's failure path still drains and releases")
    func throwingBodyStillDrains() async throws {
        let gate = TransportGate()
        var finished = false
        struct BodyFailed: Error {}

        await #expect(throws: BodyFailed.self) {
            try await TransportSerialized.withGate(gate: gate) {
                TransportTeardown.register {
                    try? await Task.sleep(for: .milliseconds(50))
                    finished = true
                }
                throw BodyFailed()
            }
        }

        #expect(finished, "a test that threw still started a listener, so its teardown still runs")
        let free = await gate.isHeld
        #expect(!free, "and the gate is not leaked by the throwing path")
    }

    @Test("Registered work runs in the order it was registered, and is cleared")
    func drainOrderAndClearing() async throws {
        var order: [Int] = []
        TransportTeardown.register { order.append(1) }
        TransportTeardown.register { order.append(2) }
        await TransportTeardown.drain()
        #expect(order == [1, 2], "the queue is FIFO, which is the order a test arranged its resources in")
        #expect(TransportTeardown.pendingCount == 0)
        await TransportTeardown.drain()
        #expect(order == [1, 2], "a second drain has nothing left to run")
    }

    @Test("A teardown that registers more work does not extend the drain it is in")
    func drainDoesNotRunWorkRegisteredDuringIt() async throws {
        // Otherwise a teardown could keep a drain alive indefinitely, and the gate would be held for as
        // long as the work it is draining keeps adding to itself.
        var ranLate = false
        TransportTeardown.register { TransportTeardown.register { ranLate = true } }
        await TransportTeardown.drain()
        #expect(ranLate == false, "the drain runs what was registered when it started")
        #expect(TransportTeardown.pendingCount == 1, "and leaves the rest for the next drain")
        await TransportTeardown.drain()
        #expect(ranLate)
    }
}
