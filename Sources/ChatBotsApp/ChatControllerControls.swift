// ChatBotsApp — the controls the moderator presses
//
// Starting, pausing and stopping the room, resetting it, sending the moderator's line, and
// the command plumbing every one of those goes through: one place that sends a request, one
// that reports a refusal, and the rule for when the draft is cleared. The two file dialogs
// that export what is on screen belong here as well, because they are the same surface the
// moderator acts through.

import AppKit
import ChatBotsCore
import Foundation

@MainActor
extension ChatController {

    public func startOrRestart() {
        errorBanner = nil
        // Stop and reset first when there is something to clear, then start. The engine
        // refuses to start without a topic, so the topic is set before the start rather than
        // being assumed to have arrived already.
        run { client in
            if self.status.isActive { _ = try await client.send(.stop) }
            if !self.turns.isEmpty { _ = try await client.send(.reset) }
            _ = try await client.send(.setTopic(self.topic))
            _ = try await client.send(.start)
        }
    }

    public func togglePause() {
        run { client in
            _ = try await client.send(self.status.isPaused ? .resume : .pause)
        }
    }

    public func stop() {
        run { client in _ = try await client.send(.stop) }
        // An explicit stop means stop: drop whatever is still queued rather than continuing
        // to type it out.
        for pane in panes {
            pacer.clear(agentID: pane.id)
            pane.endTurn()
        }
    }

    public func reset() {
        run { client in _ = try await client.send(.reset) }
        // Drop anything still queued for display: a fresh conversation must not begin by
        // revealing the tail of the one that was just cleared.
        for pane in panes {
            pacer.clear(agentID: pane.id)
            pane.endTurn()
        }
        rateSamples.removeAll()
        errorBanner = nil
    }

    /// Send the moderator's message.
    ///
    /// The send is returned as a task rather than started and forgotten: the button action ignores it,
    /// and a test can await it instead of polling for the outcome it produces.
    @discardableResult
    public func sendModeratorMessage() -> Task<Void, Never> {
        let text = moderatorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Task {} }
        return Task { [weak self] in await self?.deliverModeratorDraft(text) }
    }

    /// Send the moderator's message, and keep the draft unless the engine took it.
    ///
    /// Split from the button's action so the rule below has a caller a test can drive without
    /// racing the task the button starts.
    func deliverModeratorDraft(_ text: String) async {
        let accepted = await deliver(.steer(text))
        moderatorDraft = Self.draft(afterSendOf: text, accepted: accepted, current: moderatorDraft)
    }

    /// What the moderator's draft becomes once a send has been attempted.
    ///
    /// Cleared only when the engine accepted the message, and only when the box still holds what was
    /// sent: the moderator may have started the next line while the request was in flight, and
    /// clearing *that* would be this defect one step later. A send that was refused — a message over
    /// the engine's limit, or an engine that cannot be reached at all — keeps what was typed, which
    /// is the only copy of it.
    static func draft(afterSendOf sent: String, accepted: Bool, current: String) -> String {
        guard accepted else { return current }
        return current.trimmingCharacters(in: .whitespacesAndNewlines) == sent ? "" : current
    }

    /// Send one command and answer whether the engine accepted it.
    ///
    /// `run` is fire-and-forget: it reports a failure into `engineConnection` and returns, so a
    /// caller whose next step depends on the outcome has nothing to read. This is that caller's
    /// version.
    @discardableResult
    func deliver(_ request: EngineRequest) async -> Bool {
        guard let client else {
            reportNoClient()
            return false
        }
        do {
            let reply = try await client.send(request)
            // A refusal is a normal reply, not a thrown error — only `.failed` throws — so
            // returning `true` here reported a rejected command as accepted: the moderator's
            // draft was cleared and a refused checkpoint was shown as applied, and the reason
            // was discarded. The reason is surfaced instead, and the caller keeps its state.
            if let refusal = Self.refusalReason(in: reply) {
                engineConnection = refusal
                return false
            }
            return true
        } catch {
            engineConnection = error.localizedDescription
            return false
        }
    }

    /// The reason a reply means the command was not carried out, or nil when it was.
    ///
    /// `.refused` is a well-formed command the engine chose not to perform, and `.failed` is the
    /// engine saying why it could not answer; both must leave the caller's state alone. Pure, so
    /// the rule is testable without a transport.
    static func refusalReason(in reply: EngineReply) -> String? {
        switch reply {
        case .refused(let reason), .failed(let reason): return reason
        default: return nil
        }
    }

    /// Send one command and apply whatever the engine answers with.
    ///
    /// Every command answers with the whole state, so the interface never has to guess what
    /// changed — and a refusal arrives the same way as a success, carrying the reason.
    ///
    /// **Why there is no second command queue here.** Each command runs in its own
    /// task, which used to let two sends overlap against a client that routed replies by queue
    /// position, so replies could cross. That is fixed on the client: `send` takes a
    /// one-request-wide slot with a FIFO queue behind it, so the order commands register in is
    /// the order they reach the wire, a reply is checked against the request it answers, and one
    /// that cannot be matched fails the reader explicitly instead of being handed to the next
    /// waiter. A queue here would duplicate that guarantee without adding one — the controls are
    /// already mutually exclusive by run state, and the only concurrent sender is the poll,
    /// which is a read. What the controller does owe is to surface the client's new explicit
    /// failure, which the `catch` below does for a command and the poll does for itself.
    func run(_ body: @escaping (WebTransportEngineClient) async throws -> Void) {
        guard let client else {
            reportNoClient()
            return
        }
        Task { [weak self] in
            do {
                try await body(client)
            } catch {
                self?.engineConnection = error.localizedDescription
            }
        }
    }

    /// Say that a command had nowhere to go, without covering a reason that is already there.
    ///
    /// A control pressed while nothing is connected has to say something, and "Not connected to the
    /// engine." is the right thing to say when nothing else explains it. When something else does —
    /// `connect` failing with "Could not reach the engine: …" — that reason is more specific and
    /// still true, and the controls `applyAPIEndpoints` fires one after another must not overwrite it
    /// with a symptom. `connect` clears the message when a connection is actually made, so a
    /// message that is present is always about the connection that is not.
    func reportNoClient() {
        if engineConnection == nil { engineConnection = "Not connected to the engine." }
    }

    /// The whole conversation as plain text.
    ///
    /// One shared log walked once, so each message appears exactly once — including the
    /// messages the two seats addressed to each other, which are the conversation rather
    /// than duplicates of it. Timestamps are the format the moderator asked for.
    public func transcriptAsText(exportedAt: Date = Date.now) -> String {
        TranscriptWriter.text(
            topic: topic,
            turns: turns,
            participants: currentSeats,
            exportedAt: exportedAt
        )
    }

    public func copyConversation() {
        let text = transcriptAsText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Save the conversation to a text file, through the standard macOS save dialog.
    ///
    /// Returns the chosen URL, or nil if the moderator cancelled.
    @discardableResult
    public func saveConversation() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Conversation"
        panel.message = "Save the full conversation log as a plain text file."
        panel.prompt = "Save"
        panel.allowedContentTypes = [.plainText]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = TranscriptWriter.suggestedFilename(topic: topic)

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let text = transcriptAsText()
        do {
            // Atomic, so a failure part-way through cannot leave a half-written log where
            // the moderator expects a complete one.
            try Data(text.utf8).write(to: url, options: .atomic)
            errorBanner = nil
            return url
        } catch {
            errorBanner = "Could not save the conversation: \(error.localizedDescription)"
            return nil
        }
    }
}
