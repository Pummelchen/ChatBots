// ChatBotsAppTests — a refused command is not an accepted one
//
// `deliver` returned true for any reply at all, and a `.refused` reply is a normal answer
// rather than a thrown error. The moderator's draft was therefore cleared on a message the
// engine had rejected, and a refused checkpoint was shown as applied. The decision is a pure
// function so the rule can be pinned without a transport.

import ChatBotsCore
import Testing

@testable import ChatBots

@MainActor
@Suite("A refused command is not an accepted one")
struct RefusalTests {

    @Test("A refusal or a failure is not acceptance")
    func refusalReason() {
        #expect(ChatController.refusalReason(in: .refused("over the limit")) == "over the limit")
        #expect(ChatController.refusalReason(in: .failed("no transport")) == "no transport")
    }

    @Test("A report or a list is acceptance")
    func otherRepliesAreAccepted() {
        #expect(ChatController.refusalReason(in: .report("a report")) == nil)
        #expect(ChatController.refusalReason(in: .rosters([])) == nil)
        #expect(ChatController.refusalReason(in: .scenarios([])) == nil)
        #expect(ChatController.refusalReason(in: .savedConversations([])) == nil)
    }
}
