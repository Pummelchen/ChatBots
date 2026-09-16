// ChatBotsCore — the audience's verdicts on the shared log
//
// Split out of `ConversationEngine.swift`, which held the orchestrator, its turn loop, its
// transcript plumbing, its context bookkeeping and its research mode in one 1613-line file.
// Casting, withdrawing and clearing a vote are one responsibility, and they persist
// immediately; nothing changed but which file the code lives in.

import Foundation

extension ConversationEngine {

    // MARK: - The audience

    /// Cast, change or withdraw the audience's verdict on one contribution.
    ///
    /// Returns false for a turn that is not a contribution: voting on the topic, on a tool
    /// result or on the moderator's own assignment would put a score against something nobody
    /// argued, and the scorecard is meant to be a judgement of the argument.
    @discardableResult
    public func castVote(turnID: UUID, verdict: AudienceVote.Verdict?) -> Bool {
        guard let turn = conversation.turns.first(where: { $0.id == turnID }),
            turn.kind == .chat, let seatID = turn.speakerID
        else { return false }
        if let verdict {
            conversation.audience.cast(verdict, for: turnID, seatID: seatID)
        } else {
            conversation.audience.withdraw(turnID: turnID)
        }
        // Written immediately rather than at the next turn: a vote is the audience's work, and
        // losing it because the window was closed before the next contribution would be the
        // same class of loss as losing the transcript.
        saveConversation()
        publishTranscript()
        return true
    }

    public func clearVotes() {
        conversation.audience.clear()
        saveConversation()
        publishTranscript()
    }

    /// The audience's scorecard.
    public var audience: AudienceScorecard { conversation.audience }
}
