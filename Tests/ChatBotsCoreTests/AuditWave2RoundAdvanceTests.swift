// ChatBotsCoreTests — A91: an abandoned round must end the turn
//
// When the reasoning ceiling ended a round, the engine still reached the same tool-dispatch
// guard as an ordinary round. A `.toolCall` chunk that arrived while the stripper still
// considered itself inside reasoning — which a protocol-violating model can produce — was then
// dispatched, and the turn ran another round instead of ending, spending more of the budget the
// ceiling exists to bound.
//
// The decision is `MLXEngine.roundAdvance`, a pure function so the rule is exercised without
// weights. The generation loop itself is not reachable without a GPU; this asserts the rule the
// loop applies, not a live generation.

import ChatBotsCore
import Testing

@Suite("A ceiling-abandoned round ends the turn (A91)")
struct AuditWave2RoundAdvanceTests {

    @Test("An abandoned round never dispatches tools, whatever fragments arrived")
    func abandonedRoundEndsTheTurn() {
        // The finding's exact shape: a tool call was collected, tools are configured, and the
        // round limit has not been reached — every condition the old guard accepted.
        for calls in [1, 2, 5] {
            #expect(
                MLXEngine.roundAdvance(
                    reasoningWasTruncated: true,
                    toolCallCount: calls,
                    hasTools: true,
                    round: 0,
                    maxToolRounds: 3) == .endTurn,
                "an abandoned round dispatched \(calls) collected call(s)")
        }
        // Even with no calls at all, which the old guard also handled.
        #expect(
            MLXEngine.roundAdvance(
                reasoningWasTruncated: true,
                toolCallCount: 0,
                hasTools: true,
                round: 0,
                maxToolRounds: 3) == .endTurn)
    }

    @Test("An ordinary round with tool calls still dispatches them")
    func ordinaryRoundDispatches() {
        #expect(
            MLXEngine.roundAdvance(
                reasoningWasTruncated: false,
                toolCallCount: 1,
                hasTools: true,
                round: 0,
                maxToolRounds: 3) == .dispatchTools)
    }

    @Test("The other stop conditions are unchanged")
    func otherStopConditions() {
        // No call this round.
        #expect(
            MLXEngine.roundAdvance(
                reasoningWasTruncated: false,
                toolCallCount: 0,
                hasTools: true,
                round: 0,
                maxToolRounds: 3) == .endTurn)
        // No tools configured for this seat.
        #expect(
            MLXEngine.roundAdvance(
                reasoningWasTruncated: false,
                toolCallCount: 1,
                hasTools: false,
                round: 0,
                maxToolRounds: 3) == .endTurn)
        // The round limit is a stop whether or not the round was abandoned.
        #expect(
            MLXEngine.roundAdvance(
                reasoningWasTruncated: false,
                toolCallCount: 1,
                hasTools: true,
                round: 3,
                maxToolRounds: 3) == .endTurn)
        #expect(
            MLXEngine.roundAdvance(
                reasoningWasTruncated: true,
                toolCallCount: 1,
                hasTools: true,
                round: 3,
                maxToolRounds: 3) == .endTurn)
    }

    @Test("A chunk that reaches the ceiling is reported as reaching it")
    func ceilingChunkIsReported() {
        // The assembler marks exactly the chunk that hit the ceiling, which is what the loop
        // uses to set the abandoned flag before the round's tool calls are considered.
        var assembler = TurnTextAssembler(thinking: .minimal)
        var reached = false
        for _ in 0..<10 {
            let step = assembler.consume(String(repeating: "a", count: 200))
            if step.ceilingReached { reached = true }
        }
        #expect(reached, "the ceiling never fired, so the abandoned flag could not be set")
        #expect(assembler.ceilingReached)
    }
}
