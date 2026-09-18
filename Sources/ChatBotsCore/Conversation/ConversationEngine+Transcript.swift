// ChatBotsCore — the shared log, its ordering and its persistence
//
// Split out of `ConversationEngine.swift`, which held the orchestrator, its turn loop, its
// transcript plumbing, its context bookkeeping and its research mode in one 1613-line file.
// Sequence numbers, the delivered-plus-queued view, saving and restoring a conversation and
// the seeding path a capture uses all live here; nothing changed but which file the code lives in.

import Foundation

extension ConversationEngine {

    // MARK: - Transcript plumbing

    /// Insert turns directly, without running a model.
    ///
    /// For laying out the interface against a realistic conversation — screen captures, and
    /// checking a long reply renders — without waiting for a model to produce one. It is
    /// deliberately not reachable from any route: the API has no endpoint that fabricates a
    /// conversation, so nothing a user can press will put words in a participant's mouth.
    public func seed(_ turns: [Turn]) {
        guard generationTask == nil else { return }
        for turn in turns {
            var copy = turn
            copy.sequence = nextSequence()
            conversation.turns.append(copy)
        }
        publishTranscript()
    }

    /// Set the source material seats should read. Rejected once a conversation is running,
    /// since the material is context for the discussion rather than a message in it.
    @discardableResult
    public func setAttachments(_ documents: [AttachedDocument]) -> Bool {
        // Allowed *before* a conversation starts, and refused once one has. The task is
        // non-nil only while a turn is running, so requiring it to be nil would have made
        // this succeed precisely in the case it is meant to refuse and fail otherwise.
        guard turnsCompleted == 0, generationTask == nil else { return false }
        conversation.attachments = documents
        publishTranscript()
        return true
    }
    /// The source material currently attached.
    public var attachments: [AttachedDocument] { conversation.attachments }
    /// The log the UI should draw: delivered turns plus any not-yet-delivered steering.
    public var displayTurns: [Turn] {
        (conversation.turns + queuedSteering).sorted { $0.sequence < $1.sequence }
    }
    func nextSequence() -> Int {
        let delivered = conversation.turns.map(\.sequence).max() ?? 0
        let queued = queuedSteering.map(\.sequence).max() ?? 0
        return max(delivered, queued) + 1
    }
    func drainSteering() -> [Turn] {
        let pending = queuedSteering
        queuedSteering = []
        return pending
    }
    func publishTranscript() {
        transcriptContinuation?.yield(displayTurns)
        let turns = displayTurns
        for observer in transcriptObservers.values { observer(turns) }
        saveConversation()
    }

    /// Keep the conversation on disk.
    ///
    /// Called whenever the log changes, which is once per turn — often enough that nothing
    /// meaningful is lost if the app is closed, and rare enough that it is not writing during
    /// generation. The whole conversation is written each time rather than appended to,
    /// because a record that can be rewritten is a record that cannot be left half-appended.
    func saveConversation() {
        guard let store = conversationStore, !conversation.turns.isEmpty else { return }
        let record = StoredConversation(
            id: conversationID,
            conversation: conversation,
            seats: specs,
            startedAt: conversationStartedAt,
            endReason: status.isActive ? nil : status.label)
        if store.save(record) {
            reportedSaveFailure = false
            return
        }
        // `save` returns false for a full disk, a permission failure, and an index the store
        // cannot decode, and this is its only production caller — so without this the
        // conversation is shown as intact all session and is gone at quit. Reported once per
        // failing run rather than once per turn, and cleared by the next successful save.
        guard !reportedSaveFailure else { return }
        reportedSaveFailure = true
        note("the conversation could not be saved to disk; it may be lost when the room closes")
    }

    /// Replace this conversation with a saved one.
    ///
    /// The seats are *not* taken from the record: who is in the room is a current choice, and
    /// a conversation read from a file should not change it. What comes back is the topic and
    /// the transcript — the conversation itself.
    @discardableResult
    public func load(_ record: StoredConversation) -> Bool {
        guard !isRunning else { return false }
        reset()
        conversation = record.conversation()
        // A loaded conversation keeps the identity it was saved under, so continuing it
        // updates that record rather than starting a second one.
        conversationID = record.id
        conversationStartedAt = record.startedAt
        publishTranscript()
        setStatus(.idle)
        return true
    }
}
