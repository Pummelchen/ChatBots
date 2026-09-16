// ChatBotsCoreTests — A196: the reasoning ceiling must accumulate the way a real stream arrives
//
// `account` used to add `reasoning.count / 4` per call. A generation stream emits one token per
// call and most tokens decode to one to three characters, for which `/4` is zero — so the counter
// never grew and `.minimal`/`.low`/`.medium` never fired. The existing tests feed 200-character
// segments, where `/4` is non-zero, which is why this survived.
//
// These tests drive the shape the engine actually sees: many short segments.

import Testing

@testable import ChatBotsCore

@Suite("The reasoning ceiling accumulates short segments (A196)")
struct AuditS1ReasoningCeilingTests {

    @Test("A stream of one-character segments reaches the ceiling")
    func singleCharacterSegmentsAccumulate() throws {
        let ceiling = try #require(ReasoningCeiling(mode: .low).ceiling)
        var counter = ReasoningCeiling(mode: .low)

        var fired = false
        // The budget is counted in ~4-characters-per-token units, so this is the number of
        // one-character segments the ceiling needs, with slack for rounding.
        for _ in 0..<(ceiling * 4 + 8) where !fired {
            fired = counter.account(reasoning: "x")
        }

        #expect(
            fired,
            "one-character segments must accumulate: \(ceiling) tokens is about \(ceiling * 4) characters")
        #expect(counter.tokens >= ceiling)
    }

    @Test("Two- and three-character segments accumulate too")
    func shortSegmentsAccumulate() throws {
        let ceiling = try #require(ReasoningCeiling(mode: .low).ceiling)
        var counter = ReasoningCeiling(mode: .low)

        var fired = false
        for _ in 0..<(ceiling * 3 + 8) where !fired {
            fired = counter.account(reasoning: "the")
        }

        #expect(fired, "three-character segments must accumulate")
    }

    @Test("It fires exactly once, and long segments still work")
    func firesOnceAndLongSegmentsWork() throws {
        let ceiling = try #require(ReasoningCeiling(mode: .low).ceiling)
        var counter = ReasoningCeiling(mode: .low)

        let long = String(repeating: "a", count: ceiling * 4)
        // A mutating call cannot sit inside `#expect`: the macro captures its argument immutably.
        let firstFired = counter.account(reasoning: long)
        let secondFired = counter.account(reasoning: long)
        #expect(firstFired, "one long segment must reach the ceiling")
        #expect(!secondFired, "the caller acts once, so later segments must report false")
        #expect(counter.wasReached)
    }

    @Test("A mode with no budget never fires")
    func unlimitedNeverFires() {
        var counter = ReasoningCeiling(mode: .unlimited)
        var firedSegments = 0
        // One mutating call per iteration: every segment must still reach `account`.
        for _ in 0..<10_000 where counter.account(reasoning: "x") { firedSegments += 1 }
        #expect(firedSegments == 0)
        #expect(!counter.wasReached)
    }
}
