// ChatBotsApp — folding one engine snapshot into the controller's published state
//
// Split out of `ChatController.swift`, which held the whole snapshot application next to the
// pacing and the settings in one 510-line file. Applying a snapshot did not change; only the file
// it lives in did. Every helper here exists only for `ChatController.apply(_:)`, and each is
// `private` to this file.

import ChatBotsCore
import Foundation

extension ChatController {

    /// Drop any restored file the engine turns out to hold under the same name.
    ///
    /// Such a file is *loaded*, not restored — an adopted engine that already had it, or a file
    /// re-added a moment ago. Dropping the stored copy here is what stops the same file
    /// appearing twice and what retires the "could not be loaded" notice once it is no longer
    /// true.
    func reconcileRestoredAttachments(with snapshot: APISnapshot) {
        guard !restoredAttachments.isEmpty else { return }
        let heldNames = Set(snapshot.attachments.map(\.name))
        let remaining = restoredAttachments.filter { !heldNames.contains($0.name) }
        if remaining.count != restoredAttachments.count {
            restoredAttachments = remaining
            refreshAttachmentRestoreNotice()
        }
    }

    static func turns(from messages: [APISnapshot.Message]) -> [Turn] {
        messages.map { message in
            Turn(
                id: UUID(uuidString: message.id) ?? UUID(),
                sequence: message.sequence,
                speakerID: message.speakerID,
                speakerName: message.speaker,
                kind: Turn.Kind(rawValue: message.kind) ?? .chat,
                content: message.text,
                toolDetail: message.toolDetail,
                timestamp: message.timestamp)
        }
    }

    static func votes(from votes: [APISnapshot.Vote]) -> [String: String] {
        Dictionary(votes.map { ($0.turnID, $0.verdict) }, uniquingKeysWith: { first, _ in first })
    }

    /// Apply the engine's seat settings to the panes.
    func applySeats(from snapshot: APISnapshot) {
        for (index, seat) in snapshot.seats.enumerated() where index < panes.count {
            apply(seat, from: snapshot, to: panes[index])
        }
    }

    private func apply(_ seat: APISnapshot.Seat, from snapshot: APISnapshot, to pane: AgentPaneState) {
        if pane.spec.displayName != seat.name { pane.spec.displayName = seat.name }
        if let personaID = seat.personaID, pane.spec.personaID != personaID {
            pane.spec.personaID = personaID
        }
        if pane.spec.thinking.rawValue != seat.thinking,
            let thinking = ThinkingMode(rawValue: seat.thinking)
        {
            pane.spec.thinking = thinking
        }
        if let backend = AgentSpec.Backend(rawValue: seat.backend) {
            pane.spec.backend = backend
        }
        // The live view is the authority for whether this seat is still producing.
        //
        // The event feed carries only four fragment kinds — token, reasoning, tool and
        // started — and none of them says a turn has ended. `live[].isGenerating` does, and
        // it is the engine's own record of the same events (`record(_:)` in
        // `ConversationEngine`), so it is read here rather than inferred from a fragment
        // that never arrives. That is what clears the stuck "generating…" state after the
        // last turn, what tells a client that connects mid-turn that the seat is busy, and
        // what covers a failed turn, which no fragment expresses either.
        if let live = snapshot.live.first(where: { $0.seatID == seat.id }) {
            applyLive(live, to: pane)
        }
        // The client cannot see whether weights are loaded, only whether anything is
        // being produced. `ready` is the honest description of "the engine is answering".
        pane.engineState = .ready
    }

    /// Fold one seat's live state into its pane.
    ///
    /// Edge-triggered deliberately: `beginTurn` clears the visible answer, so it must fire once
    /// per turn rather than once per snapshot, and a snapshot that agrees with the pane must
    /// change nothing.
    private func applyLive(_ live: APISnapshot.Live, to pane: AgentPaneState) {
        if live.isGenerating, !pane.isGenerating {
            pane.beginTurn()
        } else if !live.isGenerating, pane.isGenerating {
            pane.finishGenerating()
        }
        // The tool log and the statistics arrive by the same route. Reading them only
        // when `stats` was present is what left the tool log permanently empty, since
        // the `.toolResult` branch in `apply(_:)` is unreachable from this transport.
        pane.toolLog = live.toolLog
        if let stats = live.stats { pane.lastStats = stats }
        if let activity = live.activity { pane.activity = activity }
    }
}
