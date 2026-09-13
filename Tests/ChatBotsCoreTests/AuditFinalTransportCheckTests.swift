// ChatBotsCoreTests — A02: what the installer's transport check reports
//
// `TransportCheck` is the check the installer runs to prove the channel works, and it had no
// test at all. Its round trip needs a real socket and a spawned engine, which a unit test
// should not fake — but the part that decides what a result *means* is pure, and that is where
// a wrong report would hide: a check that says "refused as expected" without a refusal, or
// "succeeded" on a channel that never carried a command.
//
// The step recorders below are the ones `run()` calls, so these tests pin the reporting the
// installer's banner is built from.

@testable import ChatBotsCore
import Testing

@Suite("The transport check's report (A02)")
struct AuditFinalTransportCheckTests {

    private func baseReport() -> TransportCheckReport {
        TransportCheckReport(fingerprint: "AB:CD")
    }

    @Test("A check that connected and made its round trips succeeds")
    func happyPathSucceeds() {
        var report = baseReport()
        report.connected = true
        report.sessionCount = 1

        report.recordStateRead(received: true)
        report.recordCommand(tookEffect: true, failure: "setTopic did not take effect")
        report.recordRefusal(wasRefused: true, failureWhenNotRefused: nil)
        report.recordRefusal(
            wasRefused: true, failureWhenNotRefused: "an unknown seat was not refused")
        report.recordStateAfterRefusals(received: true)
        report.recordEventStream(state: true, event: false)

        #expect(report.roundTrips == 5)
        #expect(report.failures.isEmpty)
        #expect(report.refusedAsExpected)
        #expect(report.succeeded)
    }

    @Test("Success needs the connection, the round trips and no failure")
    func successRequiresAllThree() {
        var report = baseReport()
        #expect(!report.succeeded, "a report that never connected did not succeed")

        report.connected = true
        #expect(!report.succeeded, "three round trips are the floor")

        report.recordStateRead(received: true)
        report.recordStateRead(received: true)
        report.recordStateRead(received: true)
        #expect(report.succeeded)

        report.recordFailure("something broke")
        #expect(!report.succeeded, "a recorded failure cannot be reported as success")
    }

    @Test("A state read that returned nothing is a failure")
    func emptyStateReadFails() {
        var report = baseReport()
        report.recordStateRead(received: false)
        #expect(report.roundTrips == 1, "the round trip happened even though it carried no state")
        #expect(!report.receivedState)
        #expect(report.failures == ["fetchState returned no state"])
    }

    @Test("A command that did not take effect is a failure")
    func commandWithoutEffectFails() {
        var report = baseReport()
        report.recordCommand(tookEffect: false, failure: "setTopic did not take effect")
        #expect(report.roundTrips == 1)
        #expect(report.failures == ["setTopic did not take effect"])
    }

    @Test("A refusal marks the check, and a missing one is reported")
    func refusalReporting() {
        var report = baseReport()
        report.recordRefusal(wasRefused: false, failureWhenNotRefused: nil)
        #expect(!report.refusedAsExpected)
        #expect(report.failures.isEmpty, "a surprising refusal alone is not a failure")

        report.recordRefusal(
            wasRefused: false, failureWhenNotRefused: "an unknown seat was not refused")
        #expect(report.failures == ["an unknown seat was not refused"])

        report.recordRefusal(wasRefused: true, failureWhenNotRefused: "never used")
        #expect(report.refusedAsExpected)
        #expect(!report.failures.contains("never used"))
    }

    @Test("A session that died after a refusal is reported")
    func sessionAfterRefusals() {
        var report = baseReport()
        report.recordStateAfterRefusals(received: false)
        #expect(report.roundTrips == 1)
        #expect(report.failures == ["the session did not survive a refusal"])
    }

    @Test("The event stream must deliver the initial state")
    func eventStreamRequiresState() {
        var report = baseReport()
        report.recordEventStream(state: false, event: true)
        #expect(report.receivedEvent)
        #expect(report.failures == ["no state arrived on the event stream"])

        var quiet = baseReport()
        quiet.recordEventStream(state: true, event: false)
        #expect(quiet.failures.isEmpty, "no output fragment is expected with nothing loaded")
    }

    @Test("The banner names every field the check measured")
    func describeShowsEverything() {
        var report = baseReport()
        report.connected = true
        report.receivedState = true
        report.roundTrips = 5
        report.refusedAsExpected = true
        report.sessionCount = 1

        let clean = report.describe()
        #expect(clean.contains("AB:CD"))
        #expect(clean.contains("connected     yes"))
        #expect(clean.contains("round trips   5"))
        #expect(clean.contains("state         received"))
        #expect(clean.contains("output event  not seen (no model loaded)"))
        #expect(clean.contains("refusal       refused as expected"))
        #expect(clean.contains("sessions      1"))
        #expect(!clean.contains("failures:"))

        report.recordFailure("connect across processes: timed out")
        let failed = report.describe()
        #expect(failed.contains("failures:"))
        #expect(failed.contains("    · connect across processes: timed out"))

        // The negative forms are distinguishable from the positive ones.
        var nothing = baseReport()
        nothing.fingerprint = "not generated"
        let empty = nothing.describe()
        #expect(empty.contains("connected     NO"))
        #expect(empty.contains("state         NOT RECEIVED"))
        #expect(empty.contains("refusal       NOT REFUSED"))
    }
}
