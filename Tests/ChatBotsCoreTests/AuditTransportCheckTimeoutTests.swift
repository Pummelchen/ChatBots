// ChatBotsCoreTests — A122: the transport check's timeout is real
//
// `TransportCheck.run(in:port:timeout:)` declared `timeout` and never read it, so the check the
// installer's smoke test runs had no deadline of its own, and `chatbots-cli --check-transport` run
// directly was unbounded. The mapping from that parameter to the client's request budget is the
// part that needs no socket, so it is the part pinned here.

import Testing

@testable import ChatBotsCore

@Suite("The transport check obeys its timeout (A122)")
struct AuditTransportCheckTimeoutTests {

    @Test("The client's request budget is the check's own timeout")
    func timeoutBecomesTheClientBudget() {
        #expect(TransportCheck.clientTimeoutMilliseconds(.seconds(30)) == 30_000)
        #expect(TransportCheck.clientTimeoutMilliseconds(.seconds(1)) == 1_000)
        #expect(TransportCheck.clientTimeoutMilliseconds(.milliseconds(250)) == 250)
    }

    @Test("A budget too small to be a deadline is floored at one millisecond")
    func subMillisecondBudgetsAreFloored() {
        // A zero-millisecond deadline would have already passed by the time the client used it,
        // which reports as "the engine never answered" rather than as "the budget was absurd".
        #expect(TransportCheck.clientTimeoutMilliseconds(.zero) == 1)
        #expect(TransportCheck.clientTimeoutMilliseconds(.microseconds(1)) == 1)
        #expect(TransportCheck.clientTimeoutMilliseconds(.seconds(-5)) == 1)
    }

    @Test("A budget too large for the transport's field is clamped, not trapped")
    func hugeBudgetsAreClamped() {
        // The conversion used to be `Int32(seconds * 1000)`, which traps on a value that does not
        // fit — the A30/A62 shape of a parse that kills the process instead of reporting.
        #expect(TransportCheck.clientTimeoutMilliseconds(.seconds(100_000_000)) == Int32.max)
    }
}
