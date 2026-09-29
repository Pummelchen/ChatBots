// ChatBotsCoreTests — the arithmetic that holds a fast backend to a readable pace
//
// A local model is paced by this Mac's GPU; a hosted one is not, and a flash-tier API finishes a reply
// before it can be read. The delay is applied where the stream is consumed, so it is backpressure on
// the server rather than a growing buffer in the interface — which makes this arithmetic the whole
// behaviour and worth pinning without a clock in sight.
//
// The contract: the answer is what the average rate says is owed for *everything emitted so far*, net
// of the time the turn has already taken. The caller sleeps that amount, which is why the clock moving
// during the sleep settles the schedule by itself rather than drifting.

import Foundation
import Testing

@testable import ChatBotsCore

@Suite("Holding a fast backend to a readable pace")
struct OutputBudgetTests {

    @Test("No ceiling means no wait at all")
    func noCeilingWaitsNever() {
        var budget = OutputBudget(tokensPerSecond: nil)
        #expect(!budget.isActive)
        #expect(budget.delay(forEmitting: 10_000, now: 0) == nil)
    }

    @Test("Zero is a ceiling turned off, not a seat stopped")
    func zeroMeansOff() {
        // `0` is what a front end sends to clear the ceiling, because nil over the wire means "leave
        // this field alone". It must not be read as "emit nothing", which would hang a turn.
        var budget = OutputBudget(tokensPerSecond: 0)
        #expect(!budget.isActive)
        #expect(budget.delay(forEmitting: 500, now: 0) == nil)

        var negative = OutputBudget(tokensPerSecond: -5)
        #expect(!negative.isActive)
        #expect(negative.delay(forEmitting: 500, now: 0) == nil)
    }

    @Test("Ten tokens a second is forty characters a second")
    func theCeilingIsMeasuredInCharacters() {
        var budget = OutputBudget(tokensPerSecond: 10)
        #expect(budget.isActive)

        // Forty characters are owed a second, and at a second per forty the schedule holds.
        #expect(budget.delay(forEmitting: 40, now: 0) == 1.0)
        #expect(budget.delay(forEmitting: 40, now: 1) == 1.0)
    }

    @Test("A turn that is already slow is never held back further")
    func elapsedTimeIsCredited() {
        var budget = OutputBudget(tokensPerSecond: 10)
        _ = budget.delay(forEmitting: 40, now: 0)

        // Two seconds for eighty characters is exactly the ceiling, so nothing is owed; a source
        // slower than the ceiling must not be slowed twice.
        #expect(budget.delay(forEmitting: 40, now: 2) == nil)
        #expect(budget.delay(forEmitting: 40, now: 3) == nil)
    }

    @Test("A burst is smoothed rather than ignored")
    func burstsAreSmoothed() {
        var budget = OutputBudget(tokensPerSecond: 10)

        // A hundred characters arriving together owe two and a half seconds: the average over the turn
        // is what is held, not one delta at a time.
        #expect(budget.delay(forEmitting: 100, now: 0) == 2.5)
    }

    @Test("An empty delta owes nothing and costs nothing")
    func emptyDeltasCostNothing() {
        var budget = OutputBudget(tokensPerSecond: 10)
        #expect(budget.delay(forEmitting: 40, now: 0) == 1.0)

        // A keep-alive or a non-text event must not add to the total, and must not reset it either.
        #expect(budget.delay(forEmitting: 0, now: 0) == nil)
        #expect(budget.delay(forEmitting: 40, now: 2) == nil)
    }

    @Test("A seat that has never been given a ceiling gets the readable one")
    func unsetSeatsGetTheReadablePace() {
        let seats = AgentSpec.applyingReadablePaceToUnset([
            AgentSpec.seat(index: 0),
            AgentSpec.seat(index: 1),
        ])

        #expect(seats.allSatisfy { $0.maximumTokensPerSecond == AgentSpec.readableTokensPerSecond })
        #expect(seats.first?.maximumTokensPerSecond == 10.0)
    }

    @Test("A ceiling that was chosen is left alone, including one switched off")
    func chosenCeilingsAreUntouched() {
        var off = AgentSpec.seat(index: 0)
        off.maximumTokensPerSecond = 0
        var slower = AgentSpec.seat(index: 1)
        slower.maximumTokensPerSecond = 3

        let seats = AgentSpec.applyingReadablePaceToUnset([off, slower])

        #expect(seats[0].maximumTokensPerSecond == 0, "off has to survive a launch to mean anything")
        #expect(seats[1].maximumTokensPerSecond == 3)
    }
}
