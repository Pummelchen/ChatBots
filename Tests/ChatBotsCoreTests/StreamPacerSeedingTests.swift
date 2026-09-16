// ChatBotsCoreTests — a new pacer starts from the rate the stream last produced at
//
// `StreamPacerPool` measured each stream's generation rate into `generationRates` and then
// never read it back: `enqueue` built a default `StreamPacer` at 40 cps, and the app clears a
// seat's pacer at every `.turnStarted`, so a stream slower than 40 drained its queue at the
// start of every turn — the visible gap the mechanism exists to remove. These tests pin the
// carry-over: a new pacer is seeded from the learned rate, the rate survives `clear`, and the
// pool still behaves as before when nothing has been measured. The app's own
// clear-at-turn-start lives in the `ChatBots` executable and is not reachable from here.

import ChatBotsCore
import Testing

@Suite("Pacer seeding from the learned rate")
struct StreamPacerSeedingTests {

    /// Characters the pool releases for one seat's answer in a tenth of a second.
    private func releasedInATenth(_ pool: StreamPacerPool, agentID: String = "A") -> Int {
        pool.drain(elapsed: 0.1)
            .filter { $0.channel == .answer }
            .map(\.text)
            .joined()
            .count
    }

    @Test("A new pacer starts from the measured rate, not the 40 cps default")
    func newPacerUsesLearnedRate() {
        let pool = StreamPacerPool()
        // One pacer exists so `observe` has something to record against, as it does in the app.
        pool.enqueue("warm up", agentID: "A", channel: .answer)
        for _ in 0..<40 { pool.observe(agentID: "A", charactersPerSecond: 12) }

        // The app clears the pacer at every turn start; the learned rate must survive that.
        pool.clear(agentID: "A")
        pool.enqueue(String(repeating: "a", count: 1000), agentID: "A", channel: .answer)

        // 12 cps converges to 11.4, so about one character in 0.1 s. From the default 40 it
        // would be four — which is the drain-at-turn-start the finding is about.
        let seeded = releasedInATenth(pool)
        #expect(
            seeded <= 2,
            "seeded pacer released \(seeded) characters in 0.1 s; the old default would release 4")
    }

    @Test("With nothing measured the default rate is unchanged")
    func unmeasuredStaysAtTheDefault() {
        let pool = StreamPacerPool()
        pool.enqueue(String(repeating: "a", count: 1000), agentID: "A", channel: .answer)
        #expect(releasedInATenth(pool) == 4, "40 cps over 0.1 s is four characters")
    }

    @Test("Seeding starts at the ceiling a measured pacer converges to")
    func seedMatchesConvergence() {
        let seeded = StreamPacer(seedingFrom: 30)
        var converged = StreamPacer()
        for _ in 0..<60 { converged.observeGeneration(charactersPerSecond: 30) }
        #expect(abs(seeded.revealRate - converged.revealRate) < 0.001)

        // The floor and cap still hold, and the measurement itself is remembered.
        let slow = StreamPacer(seedingFrom: 1)
        #expect(slow.revealRate == slow.minimumRate)
        let fast = StreamPacer(seedingFrom: 10_000)
        #expect(fast.revealRate == fast.maximumRate)
        #expect(fast.generationRate == 10_000)
    }

    @Test("A missing or unmeasurable rate leaves the pacer at its defaults")
    func noMeasurementKeepsDefaults() {
        for rate in [Double?.none, 0, -5, .infinity, .nan] {
            let pacer = StreamPacer(seedingFrom: rate)
            #expect(pacer.revealRate == 40, "rate \(String(describing: rate)) changed the default")
            #expect(pacer.generationRate == nil)
        }
    }
}
