// ChatBotsApp — kept conversations, the room's shape, and the audience
//
// The commands that are about the conversation as a whole rather than about one seat: which
// conversation is loaded, which mode the room is in, which line-up or scenario is applied,
// who the moderator is, how the audience voted, and the report that comes out of it. They are
// together because each one is a single request whose reply — a refusal or the whole engine
// state — is what the interface is updated from.

import AppKit
import ChatBotsCore
import Foundation

@MainActor
extension ChatController {

    /// What the engine has kept, newest first.
    public func refreshSavedConversations() {
        run { [weak self] client in
            let reply = try await client.send(.listSavedConversations)
            let list = reply.saved ?? []
            await MainActor.run { self?.savedConversations = list }
        }
    }

    /// Replace what is on screen with a conversation the engine kept.
    ///
    /// The engine answers with the whole state, so the transcript, the topic and the seats all
    /// come from one reply and cannot disagree with each other. A conversation can only be
    /// swapped while nothing is running: loading mid-run would leave the turn in flight writing
    /// into a transcript that is no longer on screen.
    public func loadSavedConversation(id: String) {
        errorBanner = nil
        run { [weak self] client in
            let reply = try await client.send(.loadSavedConversation(id: id))
            if let reason = reply.refusal {
                await MainActor.run { self?.errorBanner = reason }
                return
            }
            guard let snapshot = reply.snapshot else { return }
            await MainActor.run { self?.apply(snapshot) }
        }
    }

    /// Forget one kept conversation. The file on disk is removed, not just hidden.
    public func deleteSavedConversation(id: String) {
        errorBanner = nil
        run { [weak self] client in
            let reply = try await client.send(.deleteSavedConversation(id: id))
            if let reason = reply.refusal {
                await MainActor.run { self?.errorBanner = reason }
                return
            }
            self?.refreshSavedConversations()
        }
    }

    /// Start a fresh conversation without restarting the app or the engine.
    public func beginNewConversation() {
        errorBanner = nil
        run { [weak self] client in
            let reply = try await client.send(.newConversation)
            if let snapshot = reply.snapshot {
                await MainActor.run { self?.apply(snapshot) }
            }
            self?.refreshSavedConversations()
        }
    }

    /// Where this engine's HTTP server is, so a share link can be built without being told a
    /// port. Nil when the engine is WebTransport-only, and then there is nothing to share to.
    public var shareBase: String? {
        guard let base = lastSnapshot?.shareBase, !base.isEmpty else { return nil }
        return base
    }

    /// A read-only link to one kept conversation, if the engine has a page to serve.
    public func shareLink(for id: String) -> URL? {
        shareBase.flatMap { URL(string: "\($0)/s/\(id)") }
    }

    /// Whether a kept conversation can be opened right now. Loading replaces the transcript, so
    /// it is refused while a turn is generating rather than silently discarding that turn.
    public var canLoadSavedConversation: Bool { !isRunning }

    // MARK: - Mode, line-ups and scenarios

    /// Switch the room between a show and an investigation.
    ///
    /// The engine refuses once a conversation has started, and the refusal is shown rather than
    /// pre-empted: a disabled control would hide which rule was being applied.
    public func setMode(_ value: DiscussionMode) {
        errorBanner = nil
        run { client in
            let reply = try await client.send(.setMode(value))
            if let reason = reply.refusal { await MainActor.run { self.errorBanner = reason } }
        }
    }

    /// Set how hard a research session looks before concluding.
    public func setResearchDepth(_ depth: ResearchBudget.Depth) {
        errorBanner = nil
        run { client in
            let reply = try await client.send(.setResearchBudget(depth))
            if let reason = reply.refusal { await MainActor.run { self.errorBanner = reason } }
        }
    }

    /// Fetch the line-ups and scenarios for the mode the engine is in.
    public func refreshLineup() {
        let mode = self.mode
        run { [weak self] client in
            let rosters = try await client.send(.listRosters(mode)).rosters ?? []
            let scenarios = try await client.send(.listScenarios(mode)).scenarios ?? []
            await MainActor.run {
                self?.rosters = rosters
                self?.scenarios = scenarios
            }
        }
    }

    /// Apply a line-up, or a draw. The engine reports the seed in the log either way.
    public func applyRoster(id: String) {
        errorBanner = nil
        run { client in
            let reply = try await client.send(
                .applyRoster(id: id, seed: RosterLibrary.freshSeed()))
            if let reason = reply.refusal { await MainActor.run { self.errorBanner = reason } }
        }
    }

    /// Put a whole scenario — question, panel and budget — in place at once.
    public func applyScenario(id: String) {
        errorBanner = nil
        run { client in
            let reply = try await client.send(.applyScenario(id: id))
            if let reason = reply.refusal { await MainActor.run { self.errorBanner = reason } }
        }
    }

    /// Whether who is in the room, and what they are asked, can still be changed.
    public var canChangeLineup: Bool { !isRunning }

    // MARK: - The human moderator

    /// The moderator's chosen persona, or neutral.
    ///
    /// The engine reports the persona's *display* name, because that is what a person reads;
    /// the picker needs the identifier, so it is resolved back through the same library the
    /// engine used. An unknown name falls back to neutral rather than to a wrong persona.
    public var moderatorPersonaID: String {
        guard let reported = lastSnapshot?.moderatorPersona else { return PersonaLibrary.neutral.id }
        if reported
            == PersonaCatalog.style(
                id: PersonaLibrary.neutral.id, mode: mode, seatIndex: 0
            ).name
        {
            return PersonaLibrary.neutral.id
        }
        return availablePersonas.first { $0.name == reported }?.id ?? PersonaLibrary.neutral.id
    }

    /// The personas this mode offers, for the identity picker.
    public var availablePersonas: [APIPersona] { lastSnapshot?.availablePersonas ?? [] }

    public func setModerator(name: String, personaID: String) {
        errorBanner = nil
        let identity = ModeratorIdentity(name: name, personaID: personaID)
        // Kept here as well as in the engine, because the engine will not remember it across a
        // restart and this is the only place that will.
        restoredModerator = identity
        saveSettings()
        run { client in
            let reply = try await client.send(.setModerator(identity))
            if let reason = reply.refusal { await MainActor.run { self.errorBanner = reason } }
        }
    }

    // MARK: - The audience

    /// Score one contribution, or withdraw the score by passing the same verdict again.
    ///
    /// Voting twice with the same verdict clears it rather than re-casting, so a mis-click is
    /// undone by clicking the same button — reversing it by casting the opposite would leave a
    /// judgement in the record that nobody made.
    public func castVote(turnID: String, verdict: AudienceVote.Verdict) {
        errorBanner = nil
        let next: AudienceVote.Verdict? = votes[turnID] == verdict.rawValue ? nil : verdict
        run { client in
            let reply = try await client.send(.castVote(turnID: turnID, verdict: next))
            if let reason = reply.refusal { await MainActor.run { self.errorBanner = reason } }
        }
    }

    /// What the audience decided about one contribution, if anything.
    public func vote(for turnID: UUID) -> AudienceVote.Verdict? {
        votes[turnID.uuidString].flatMap(AudienceVote.Verdict.init(rawValue:))
    }

    public func clearVotes() {
        errorBanner = nil
        run { client in
            let reply = try await client.send(.clearVotes)
            if let reason = reply.refusal { await MainActor.run { self.errorBanner = reason } }
        }
    }

    /// Save the report the engine produced, as markdown.
    @discardableResult
    public func saveReport() -> URL? {
        guard let report, !report.markdown.isEmpty else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue =
            TranscriptWriter.suggestedFilename(topic: report.question, at: report.producedAt)
            .replacingOccurrences(of: ".txt", with: ".md")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try report.markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            errorBanner = error.localizedDescription
            return nil
        }
    }
}
