// ChatBotsAppTests — a send the engine did not take keeps what the moderator typed (A174)
//
// Both front ends emptied the message box before the send was confirmed. On the page the box was
// cleared and *then* the request was made, and the Mac app cleared `moderatorDraft` immediately after
// dispatching a fire-and-forget task. A send the engine refuses — a message over its 2 000-character
// limit, or any command at all when it cannot be reached — therefore discarded the only copy of what
// had been typed, and the only sign of it was a toast or a banner.
//
// The rule that decides the draft is a pure function so it can be pinned here without a socket, and
// the controller's awaiting half is exercised against a controller with no client at all, which is the
// refusal case that needs no engine to reproduce.

import ChatBotsCore
import Foundation
import Testing

@testable import ChatBots

@MainActor
@Suite("The moderator's draft after a send (A174)")
struct ModeratorDraftTests {

    @Test("An accepted send clears the box")
    func anAcceptedSendClearsTheDraft() {
        #expect(
            ChatController.draft(
                afterSendOf: "Why are eggs not round?", accepted: true,
                current: "Why are eggs not round?") == "")
    }

    @Test("A refused send keeps what was typed, because nothing else holds it")
    func aRefusedSendKeepsTheDraft() {
        #expect(
            ChatController.draft(
                afterSendOf: "a long paste", accepted: false, current: "a long paste")
                == "a long paste")
    }

    @Test("A line started while the send was in flight is not cleared with it")
    func textTypedDuringTheSendStays() {
        // Clearing everything on success would be this defect one step later: the moderator types the
        // next line while the request is in flight, and the answer empties the box under them.
        #expect(
            ChatController.draft(
                afterSendOf: "the first line", accepted: true, current: "the second line")
                == "the second line")
    }

    @Test("Surrounding whitespace does not stop the sent text from being recognised")
    func whitespaceDoesNotDisguiseTheSentText() {
        // `moderatorDraft` is compared trimmed, because the trimmed text is what the engine was sent.
        #expect(
            ChatController.draft(afterSendOf: "sent", accepted: true, current: "  sent  ") == "")
    }

    @Test("With no engine the draft stays and the reason is shown")
    func noEngineKeepsTheDraft() async {
        let controller = ChatController(initialModeratorDraft: "Is this still here?")
        await controller.deliverModeratorDraft("Is this still here?")

        #expect(controller.moderatorDraft == "Is this still here?")
        #expect(
            controller.engineConnection != nil,
            "the send must not look as though it succeeded")
    }

    @Test("The button's action is the same path, not a second one beside it")
    func theButtonActionKeepsTheDraftToo() async {
        let controller = ChatController(initialModeratorDraft: "Typed once")
        await controller.sendModeratorMessage().value

        #expect(controller.moderatorDraft == "Typed once")
        #expect(controller.engineConnection != nil)
    }
}
