// ChatBotsAppTests — the reveal pacing arithmetic
//
// This is arithmetic, not a timer, so it can be tested without waiting in real time. The
// behaviour worth pinning down is that the reveal rate *tracks generation*: a fixed delay
// would drain long before the next turn is ready, which is the whole reason the queue has
// to be rate-matched instead.

import ChatBotsCore
import Foundation
import Testing

@Suite("Stream pacing")
struct StreamPacerTests {

    @Test("Nothing is released before any time passes")
    func noTimeNoText() {
        var pacer = StreamPacer()
        pacer.enqueue("Hello world")   // 11 characters
        #expect(pacer.drain(elapsed: 0).isEmpty)
        #expect(pacer.backlog == 11, "nothing has been revealed yet, so all of it is queued")
    }

    @Test("Text is released at the configured rate, not in one burst")
    func releasesAtRate() {
        var pacer = StreamPacer()
        pacer.revealRate = 100          // 100 characters per second
        pacer.enqueue(String(repeating: "a", count: 500))

        // A tenth of a second should yield about ten characters, not five hundred.
        let first = pacer.drain(elapsed: 0.1)
        #expect(first.count == 10, "got \(first.count)")
        #expect(pacer.backlog == 490)

        // And it keeps going at that rate.
        let second = pacer.drain(elapsed: 0.1)
        #expect(second.count == 10)
        #expect(pacer.backlog == 480)
    }

    @Test("Fractional remainders accumulate instead of being lost")
    func carriesFractions() {
        var pacer = StreamPacer()
        pacer.revealRate = 10
        pacer.enqueue(String(repeating: "x", count: 100))

        // 0.05 s at 10/s is half a character each frame; after four frames two are due.
        var released = 0
        for _ in 0..<4 { released += pacer.drain(elapsed: 0.05).count }
        #expect(released == 2, "got \(released)")
    }

    @Test("A burst is absorbed: a large chunk is shown over many frames")
    func absorbsBursts() {
        var pacer = StreamPacer()
        pacer.revealRate = 50
        // A model can deliver a whole paragraph at once.
        pacer.enqueue(String(repeating: "word ", count: 200))  // 1000 characters

        var frames = 0
        var shown = 0
        while pacer.backlog > 0 && frames < 1000 {
            shown += pacer.drain(elapsed: 0.05).count
            frames += 1
        }
        #expect(shown == 1000)
        // 1000 characters at 50/s is 20 s of frames, i.e. 400 frames of 50 ms.
        #expect(frames >= 380 && frames <= 400, "took \(frames) frames")
    }

    @Test("Revealing stops on a word boundary so words do not appear letter by letter")
    func cutsAtWordBoundaries() {
        var pacer = StreamPacer()
        // 20/s over a 0.5 s frame is 10 characters, landing mid-word at "quick brown".
        pacer.revealRate = 20
        pacer.enqueue("the quick brown fox jumps over the lazy dog")

        let first = pacer.drain(elapsed: 0.5)
        #expect(first == "the quick ", "got \(first.debugDescription)")
        // Whole words, so no partial word is left dangling at the cut.
        #expect(!first.hasSuffix("quic"))
    }

    @Test("A long word without a boundary is released anyway rather than stalling")
    func doesNotHoldTextForever() {
        var pacer = StreamPacer()
        pacer.revealRate = 10
        // One enormous token, no whitespace at all.
        pacer.enqueue(String(repeating: "a", count: 40))

        let released = pacer.drain(elapsed: 1.0)   // 10 characters due
        #expect(!released.isEmpty, "text must not be held indefinitely chasing a boundary")
    }

    @Test("The reveal rate never exceeds the model's own rate")
    func neverOutpacesGeneration() {
        // The invariant that keeps the hand-off: revealing faster than the model generates
        // drains the queue, and an empty queue is the pause this exists to remove.
        for measured in [30.0, 60.0, 120.0] {
            var pacer = StreamPacer()
            for _ in 0..<60 { pacer.observeGeneration(charactersPerSecond: measured) }
            #expect(
                pacer.revealRate <= measured + 0.001,
                "reveal \(pacer.revealRate) outpaced generation \(measured)")
            #expect(pacer.revealRate > measured * 0.85, "should converge near the measured rate")
        }
    }

    @Test("A slow model is tracked, not sped up to a comfortable reading rate")
    func slowModelIsFollowed() {
        var pacer = StreamPacer()
        // Slower than the safety net: the floor holds it, and it never exceeds what the
        // model can produce.
        for _ in 0..<60 { pacer.observeGeneration(charactersPerSecond: 2) }
        #expect(pacer.revealRate <= pacer.minimumRate + 0.001, "got \(pacer.revealRate)")

        // Above the floor, it follows the model down rather than staying at a comfortable
        // rate: speeding up would empty the queue and bring the visible pause back.
        var following = StreamPacer()
        for _ in 0..<60 { following.observeGeneration(charactersPerSecond: 12) }
        #expect(following.revealRate <= 12.001, "got \(following.revealRate)")
        #expect(following.revealRate > following.minimumRate, "should rise above the floor")
    }

    @Test("The reveal rate follows the model's own throughput")
    func rateFollowsGeneration() {
        var pacer = StreamPacer()
        let start = pacer.revealRate
        // Much faster than the starting assumption.
        for _ in 0..<40 { pacer.observeGeneration(charactersPerSecond: 200) }
        #expect(pacer.revealRate > start, "the rate should have risen")
        #expect(pacer.revealRate > 150, "and should approach the measured rate, got \(pacer.revealRate)")

        // Much slower, and it comes back down.
        for _ in 0..<40 { pacer.observeGeneration(charactersPerSecond: 30) }
        #expect(pacer.revealRate < 60, "got \(pacer.revealRate)")
    }

    @Test("A steady queue is what makes the hand-off immediate")
    func steadyQueueBackfillsTheNextTurn() {
        // Generation runs at 40 characters per second for five seconds, so 200 characters
        // arrive. The reveal rate tracks it, so after the same five seconds almost all of
        // it has been shown and the queue is small rather than growing: a seat finishes
        // displaying just as the next finishes generating.
        var pacer = StreamPacer()
        for _ in 0..<100 {
            pacer.enqueue(String(repeating: "a", count: 2))    // 2 characters every 50 ms
            pacer.observeGeneration(charactersPerSecond: 40)
            _ = pacer.drain(elapsed: 0.05)
        }
        #expect(pacer.backlog < 40, "the queue should stay small, got \(pacer.backlog)")
    }

    @Test("Resetting drops queued text")
    func resetClears() {
        var pacer = StreamPacer()
        pacer.enqueue("leftover text")
        pacer.reset()
        #expect(pacer.backlog == 0)
        #expect(pacer.drain(elapsed: 1).isEmpty)
    }

    @Test("Each seat and each channel is paced separately")
    func poolKeepsStreamsSeparate() {
        let pool = StreamPacerPool()
        pool.enqueue("answer one ", agentID: "Agent 1", channel: .answer)
        pool.enqueue("thinking one ", agentID: "Agent 1", channel: .reasoning)
        pool.enqueue("answer two ", agentID: "Agent 2", channel: .answer)

        // Backlogs are per seat and per channel, so one seat cannot drain another's text.
        #expect(pool.backlog(agentID: "Agent 1", channel: .answer) > 0)
        #expect(pool.backlog(agentID: "Agent 1", channel: .reasoning) > 0)
        #expect(pool.backlog(agentID: "Agent 2", channel: .answer) > 0)
        #expect(pool.backlog(agentID: "Agent 3", channel: .answer) == 0)

        // Draining yields each stream tagged with its owner.
        let released = pool.drain(elapsed: 1.0)
        #expect(released.count == 3)
        let owners = Set(released.map(\.agentID))
        #expect(owners == ["Agent 1", "Agent 2"])
    }

    @Test("Clearing a seat drops only that seat's text")
    func clearingIsPerSeat() {
        let pool = StreamPacerPool()
        pool.enqueue("one ", agentID: "Agent 1", channel: .answer)
        pool.enqueue("two ", agentID: "Agent 2", channel: .answer)
        pool.clear(agentID: "Agent 1")

        #expect(pool.backlog(agentID: "Agent 1") == 0)
        #expect(pool.backlog(agentID: "Agent 2") > 0)
    }

    @Test("isDraining reports whether anything is still being revealed")
    func drainingState() {
        let pool = StreamPacerPool()
        #expect(!pool.isDraining)
        pool.enqueue("some text", agentID: "Agent 1", channel: .answer)
        #expect(pool.isDraining)
        _ = pool.drain(elapsed: 10)
        #expect(!pool.isDraining)
    }
}
