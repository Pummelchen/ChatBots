// ChatBotsCoreTests — one QUIC runtime at a time.
//
// `.serialized` orders the tests *within* a suite. It does nothing about two suites running at the
// same time, and five suites in this target drive a real WebTransport listener or client. When two of
// them overlap, Network.framework aborts the entire test process:
//
//     Network/Connection.swift:5833: Fatal error: Neither nw nor nwGroup is initialized
//
// which reads as a catastrophic product failure rather than as a test-runtime collision, and which
// would have been reported as a crash (one of the two sources of flakiness).
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
///
/// A waiter cancelled while it is queued leaves the queue and never takes the gate. It used to
/// stay queued: the continuation was orphaned, `release()` handed the gate to a task that would never
/// resume, and every later transport suite blocked forever — a hung suite that reads as a product
/// hang rather than as a harness defect. Cancellation throws `CancellationError` instead of returning
/// quietly, so a cancelled transport test is recorded as cancelled rather than passing unrun.
actor TransportGate {
    static let shared = TransportGate()

    private var busy = false
    private var nextWaiter = 0
    private var waiting: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var order: [Int] = []

    /// Take the gate, waiting for the current holder to release it.
    ///
    /// Throws `CancellationError` if this task is cancelled before it is admitted. The gate is left
    /// free or handed on to the next live waiter — never held by a task that has gone away.
    func acquire() async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        let id = nextWaiter
        nextWaiter += 1
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiting[id] = continuation
                order.append(id)
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
        guard admitted else { throw CancellationError() }
        // `abandon` runs in its own task, so it races `release`: if the gate was handed over in the
        // same instant the cancellation was delivered, that admission is real and has to be given
        // back before throwing, or the gate is leaked by exactly the path this exists to close.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    /// Hands the gate to the next waiter, or frees it when there is none.
    ///
    /// The waiter resumes holding the gate — `busy` stays true — so a test cannot slip in between
    /// the handover and the resumption.
    func release() {
        while let id = order.first {
            order.removeFirst()
            if let continuation = waiting.removeValue(forKey: id) {
                continuation.resume(returning: true)
                return
            }
        }
        busy = false
    }

    /// Drops a queued waiter whose task was cancelled, so the gate is not handed to a task that is
    /// gone. A waiter already handed the gate is left alone; `acquire` gives it back itself.
    private func abandon(_ id: Int) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        continuation.resume(returning: false)
    }

    // Read by this file's own tests, which is why they are not private.

    /// Whether a caller currently holds the gate.
    var isHeld: Bool { busy }

    /// How many callers are queued behind the holder.
    var waitingCount: Int { waiting.count }
}

/// Teardown a transport test wants finished before its gate is handed on.
///
/// The five transport suites each ended their tests with `defer { Task { await running.stop() } }`,
/// which returns immediately: the gate was released while the listener was still closing, and the
/// next suite acquired it into exactly the overlap the gate exists to prevent — the recorded symptom
/// being Network.framework's `Fatal error: Neither nw nor nwGroup is initialized`. A `defer`
/// cannot await, so the work is registered here instead and the suite trait runs it before it lets
/// the gate go.
///
/// `@MainActor` because these closures capture the test's own objects — a `WebTransportEngineServer`,
/// a client, a temporary directory — none of which is `Sendable`, and an actor-isolated registry would
/// need them to be. The transport suites are `@MainActor` already, so registering from a `defer`
/// costs nothing.
@MainActor
enum TransportTeardown {
    private static var pending: [() async -> Void] = []

    /// Register work to run before the gate is released. Order is preserved.
    static func register(_ work: @escaping () async -> Void) {
        pending.append(work)
    }

    /// Run everything registered, in the order it was registered, and clear the list.
    ///
    /// Clearing first means a teardown that registers another one is left for the next drain rather
    /// than extending this one — the alternative is a drain that can be made not to finish.
    static func drain() async {
        let work = pending
        pending.removeAll()
        for item in work { await item() }
    }

    /// How many teardowns are waiting. Read by this file's own tests.
    static var pendingCount: Int { pending.count }
}

/// Serialises every suite that drives a real QUIC listener or client.
///
/// Applied as a suite trait, so a suite cannot be added to this file's list and then forgotten.
///
/// **What the scope actually covers, measured rather than assumed.** A `TestScoping` trait on a
/// suite wraps the *suite*, not each test in it: instrumenting `provideScope` for a four-test suite
/// printed one entry, with work registered by two of those tests before the first release. `.serialized`
/// on the suite is what orders the tests within it. What the gate therefore guarantees is that only one
/// transport suite — and so one QUIC runtime — is live at a time, which is what the gate needed; it does not
/// make the tests inside a suite hold it one at a time. This doc comment used to claim the gate was taken
/// "for each of its tests", which was wrong and had never been measured.
struct TransportSerialized: SuiteTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await Self.withGate(function)
    }

    /// Take `gate`, run `body`, run the teardowns `body` registered, then release.
    ///
    /// Separated from `provideScope` because this is the part with an invariant in it, and a `Test`
    /// value cannot be constructed by a test — so `TeardownTests` exercises this directly, with
    /// a gate of its own, rather than asserting a copy of it.
    ///
    /// `@MainActor` because the body captures the test's own objects through the teardowns it
    /// registers, and neither those objects nor the closures are `Sendable`. Every suite that uses this
    /// trait is `@MainActor` already, so this constrains nothing new; `provideScope` is nonisolated and
    /// hands over a `@Sendable` body, which is safe to run there.
    @MainActor
    static func withGate(_ body: () async throws -> Void) async throws {
        try await withGate(gate: .shared, body)
    }

    /// The same sequence against an explicit gate, so a test that already holds the shared one can
    /// still exercise it.
    @MainActor
    static func withGate(gate: TransportGate, _ body: () async throws -> Void) async throws {
        try await gate.acquire()
        do {
            try await body()
        } catch {
            // Released on the throwing path too; a leaked gate would deadlock every later transport
            // test, which is a worse failure than the one this trait exists to prevent. The teardowns
            // run first here as well: a test that threw still started a listener.
            await TransportTeardown.drain()
            await gate.release()
            throw error
        }
        // Before the release, which is the whole point: the gate is what says "no other transport
        // suite is running", and a listener that has not finished closing still is one.
        await TransportTeardown.drain()
        await gate.release()
    }
}
