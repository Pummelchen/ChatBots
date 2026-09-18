// ChatBotsCore — one dispatch, independent of how it arrived
//
// Everything the engine can be asked to do, in one place. Before this the request handling
// lived inside the HTTP server, which meant the only way to exercise it was over a socket and
// the only transport that could reach it was HTTP. Now both the HTTP server and the
// WebTransport server translate their own wire format into an `EngineRequest` and call here,
// so a command cannot work on one channel and silently fail on the other.
//
// The service knows nothing about HTTP, QUIC, JSON or framing. It takes a request and returns
// a reply; whether that reply is written as an HTTP body or a length-prefixed frame is the
// transport's business.

import Foundation

@MainActor
public final class EngineService {

    // Internal rather than private: the attachment and snapshot extensions live in their own files.
    let engine: ConversationEngine

    /// Whether the web interface shows the models' thinking blocks. A view preference, but it
    /// is held here because both front ends share one conversation.
    public var showReasoning = true

    /// Where the HTTP server is reachable, when there is one.
    ///
    /// Set by whatever started the server, because only it knows the port. It travels in the
    /// snapshot so a client can offer a share link without being told a second address — and so
    /// a WebTransport-only engine honestly reports that there is nothing to share to.
    public var shareBase: String?

    /// Where conversations are kept between runs.
    public let store: ConversationStore

    /// The per-run token this engine proves itself with, or nil when it was started without one.
    ///
    /// Echoed only to `.identify`, and only over the transport the app connects on: it is not a
    /// member of `APISnapshot`, and no HTTP route produces `.identify`. See `SessionToken`.
    public let sessionToken: String?

    /// The revision stamped on the next snapshot.
    ///
    /// Monotonic for the life of this service and incremented in `snapshot()`, the one place a
    /// snapshot is produced — both front ends reach it through the same replies and pushes. A
    /// client uses it to order two snapshots the wall clock cannot separate.
    /// Internal rather than private: `snapshot()` is in its own file.
    var snapshotRevision = 0

    /// Where a staged upload is read.
    ///
    /// A closure rather than a direct call to `DocumentIngestorProvider`, so a test can supply
    /// its own ingestor without installing one process-wide, and so the conversion can be
    /// exercised as the off-actor step it now is. The default is the provider the app installs
    /// at launch.
    /// Internal rather than private: the attachment extension reads it.
    let attachmentIngestor: @Sendable () throws -> DocumentIngestor

    public init(
        engine: ConversationEngine,
        store: ConversationStore,
        sessionToken: String? = nil,
        attachmentIngestor: @escaping @Sendable () throws -> DocumentIngestor = {
            try DocumentIngestorProvider.ingestor
        }
    ) {
        self.engine = engine
        self.store = store
        self.sessionToken = sessionToken
        self.attachmentIngestor = attachmentIngestor
        // The engine writes on every change, so the app does not have to remember to.
        engine.conversationStore = store
    }

    /// How many seats this engine has.
    public var seatCount: Int { engine.specs.count }

    /// Handle one request.
    ///
    /// Returns a reply, or nil when the request is a read that the caller has already been
    /// given another way. Throws only for something genuinely exceptional; a refusal — a
    /// locked topic, an image no seat can see — is an `EngineReply.refused`, because it is an
    /// answer the user should read rather than an error to log.
    ///
    /// The switch groups requests by the kind of work they do and hands each group to a private
    /// helper below, so the dispatch stays readable and each handler can be read on its own.
    /// It is exhaustive: every `EngineRequest` case appears in exactly one clause.
    public func handle(_ request: EngineRequest) async -> EngineReply {
        switch request {
        // ── Transport controls ───────────────────────────────────────────────────────
        case .start, .pause, .resume, .stop, .reset, .compact, .newConversation:
            return applyEngineCommand(request)

        // ── Identity ─────────────────────────────────────────────────────────────────
        // Transport-only: `translate` in `APIServer+Commands` deliberately has no route that
        // produces this case, so the token is not reachable over the HTTP API.
        case .identify:
            return identify()

        // ── Content ──────────────────────────────────────────────────────────────────
        case .setTopic, .steer:
            return handleContent(request)

        // ── View and mode ────────────────────────────────────────────────────────────
        case .setShowReasoning, .setMode, .setResearchBudget:
            return handleViewAndMode(request)

        // ── Seats ────────────────────────────────────────────────────────────────────
        case .updateSeat(let change):
            return updateSeat(change)

        // ── Attachments ──────────────────────────────────────────────────────────────
        case .addAttachment, .removeAttachment, .clearAttachments:
            return await handleAttachments(request)

        // ── Reads ────────────────────────────────────────────────────────────────────
        case .fetchState, .fetchReport:
            return handleReads(request)

        // ── Line-ups and scenarios ───────────────────────────────────────────────────
        case .listRosters, .listScenarios, .applyRoster, .applyScenario:
            return handleLineups(request)

        // ── The audience ─────────────────────────────────────────────────────────────
        case .castVote, .clearVotes:
            return handleAudience(request)

        // ── The human moderator and saved conversations ──────────────────────────────
        case .setModerator, .listSavedConversations, .loadSavedConversation,
            .deleteSavedConversation:
            return await handleSavedAndModerator(request)
        }
    }

    private static func summary(_ record: StoredConversation) -> SavedConversationSummary {
        SavedConversationSummary(
            id: record.id.uuidString,
            topic: record.topic,
            summary: record.summary,
            replies: record.turns.filter { $0.kind == "chat" }.count,
            updatedAt: record.updatedAt,
            startedAt: record.startedAt)
    }

    /// Why an attachment change was refused, in the words the app and the page both use.
    ///
    /// One string rather than two, because the app's disabled ✕, the page's disabled ✕ and this
    /// refusal are the same rule.
    static let sourceMaterialIsFixed =
        "Source material cannot be changed once the conversation has started"

    /// How much user-supplied text one field may carry.
    ///
    /// Every value bounded by this enters the conversation and is re-sent inside every `APISnapshot` to
    /// every connected client, so an uncapped field is an uncapped cost per turn and per client for as
    /// long as the conversation lives — and a snapshot is a few kilobytes even when the fields are
    /// small. The seat name has been capped at 40 characters and attachments at 24 for a while; the
    /// topic, the steering message and the moderator's name were the fields that were not.
    /// 2 000 characters is a long paragraph: more than any of these needs, and far less than the ~85 MB
    /// one request may carry.
    public static let maximumFieldCharacters = 2_000

    /// The engine's event stream, for a transport to forward.
    public var events: AsyncStream<TurnEvent> { engine.events }

    /// Watch the shared log. See `ConversationEngine.observeTranscript` for why this is a
    /// callback rather than a stream.
    public func observeTranscript(_ body: @escaping ([Turn]) -> Void) -> UUID {
        engine.observeTranscript(body)
    }

    public func stopObservingTranscript(_ id: UUID) {
        engine.stopObservingTranscript(id)
    }

    /// Watch the models' output. A callback for the same reason as the transcript.
    @discardableResult
    public func observeEvents(_ body: @escaping (TurnEvent) -> Void) -> UUID {
        engine.observeEvents(body)
    }

    public func stopObservingEvents(_ id: UUID) {
        engine.stopObservingEvents(id)
    }
    /// The shared log, for a transport that reports changes rather than deltas.
    public var transcriptUpdates: AsyncStream<[Turn]> { engine.transcriptUpdates }

    /// The seats, for a transport that needs to describe the room before a snapshot exists.
    public var specs: [AgentSpec] { engine.specs }
}

// The dispatch helpers, one per group of requests, declared here so `handle` reads as a table
// of contents. A group's `default` is unreachable: `handle` routes only its own cases into it.
extension EngineService {

    /// The transport controls and `newConversation`: each changes the room's own state and
    /// answers with the state it produced.
    private func applyEngineCommand(_ request: EngineRequest) -> EngineReply {
        switch request {
        case .start: engine.startOrRestart()
        case .pause: engine.pause()
        case .resume: engine.resume()
        case .stop: engine.stop()
        case .reset: engine.reset()
        case .compact: engine.compactNow()
        case .newConversation: engine.startNewConversation()
        // Unreachable: `handle` routes only the commands above into this branch.
        default: break
        }
        return .state(snapshot())
    }

    /// The two free-text commands, each validated before it reaches the engine.
    private func handleContent(_ request: EngineRequest) -> EngineReply {
        switch request {
        case .setTopic(let topic): return setTopic(topic)
        case .steer(let text): return steer(text)
        // Unreachable: `handle` routes only `.setTopic` and `.steer` into this branch.
        default: return .state(snapshot())
        }
    }

    /// A blank topic is refused rather than blanking the question. Restoring from saved settings
    /// sets the topic directly, so this does not affect startup.
    private func setTopic(_ topic: String) -> EngineReply {
        guard !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refused("a topic is required")
        }
        // Refused rather than truncated: a topic is a command, and a silently shortened question is
        // a question the room answers differently from the one that was asked.
        guard topic.count <= Self.maximumFieldCharacters else {
            return .refused("a topic is limited to \(Self.maximumFieldCharacters) characters")
        }
        guard engine.setTopic(topic) else {
            return .refused("the topic cannot be changed once the conversation has started")
        }
        return .state(snapshot())
    }

    /// A steering message, bounded and refused in the same shape as the topic.
    private func steer(_ text: String) -> EngineReply {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refused("a message is required")
        }
        guard text.count <= Self.maximumFieldCharacters else {
            return .refused("a message is limited to \(Self.maximumFieldCharacters) characters")
        }
        engine.steer(text)
        return .state(snapshot())
    }

    /// The show-reasoning preference, the discussion mode and the research budget.
    private func handleViewAndMode(_ request: EngineRequest) -> EngineReply {
        switch request {
        case .setShowReasoning(let on):
            showReasoning = on
            return .state(snapshot())
        case .setMode(let mode):
            guard engine.setMode(mode) else {
                return .refused("the mode cannot be changed once the conversation has started")
            }
            return .state(snapshot())
        case .setResearchBudget(let depth):
            guard engine.setResearchBudget(depth) else {
                return .refused(
                    "the research budget cannot be changed once the investigation has started")
            }
            return .state(snapshot())
        // Unreachable: `handle` routes only the three commands above into this branch.
        default: return .state(snapshot())
        }
    }

    /// One seat's change.
    ///
    /// The checkpoint is decided first, because it is the one field that replaces an engine
    /// rather than editing one and the only field that can be refused: `setModel` holds the
    /// rule about when that is allowed. Applying the other fields first and returning
    /// `.refused` afterwards left the seat renamed by a request that reported it had changed
    /// nothing — against this method's own rule that a change which could not be made is
    /// never reported as one that was.
    private func updateSeat(_ change: EngineRequest.SeatChange) -> EngineReply {
        guard let index = engine.specs.firstIndex(where: { $0.id == change.seatID }) else {
            return .refused("no seat called \(change.seatID)")
        }
        if let modelID = change.modelID, let refusal = resolveModel(modelID, forSeatAt: index) {
            return refusal
        }
        // `setModel` rewrites the seat's own spec — the short name and the sampling
        // parameters are derived from the checkpoint — so the local copy is re-read
        // rather than kept, which would write the pre-change values back.
        var spec = engine.specs[index]
        // Only what was asked for. A nil field means "leave it", so renaming a seat
        // cannot reset its persona.
        applyEditableFields(change, to: &spec)
        engine.updateSeat(spec)
        return .state(snapshot())
    }

    /// Apply the checkpoint a seat change named, or say why it cannot be. `nil` means the seat
    /// now carries the checkpoint the caller asked for.
    private func resolveModel(_ modelID: String, forSeatAt index: Int) -> EngineReply? {
        let resolved = ModelCatalog.resolve(modelID)
        guard !resolved.isEmpty else { return .refused("a model is required") }
        let spec = engine.specs[index]
        if resolved != spec.modelID, !engine.setModel(resolved, for: spec.id) {
            return .refused("the model cannot be changed while a turn is in flight")
        }
        return nil
    }

    /// Write each field the caller actually set, leaving every other field alone.
    private func applyEditableFields(_ change: EngineRequest.SeatChange, to spec: inout AgentSpec) {
        if let name = change.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            spec.displayName = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
        }
        if let personaID = change.personaID { spec.personaID = personaID }
        if let thinking = change.thinking { spec.thinking = thinking }
        if let backend = change.backend { spec.backend = backend }
        if let baseURL = change.baseURL {
            spec.openAI.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        }
        if let model = change.apiModel { spec.openAI.model = model }
        if let key = change.apiKey { spec.openAI.apiKey = key }
    }

    /// The three attachment routes. `addAttachment` does its own conversion and validation; the
    /// other two are the same "check, then set" shape.
    private func handleAttachments(_ request: EngineRequest) async -> EngineReply {
        switch request {
        case .addAttachment(let filename, let contents):
            return await addAttachment(filename: filename, contents: contents)
        case .removeAttachment(let id):
            return removeAttachment(id)
        case .clearAttachments:
            guard engine.setAttachments([]) else {
                return .refused(Self.sourceMaterialIsFixed)
            }
            return .state(snapshot())
        // Unreachable: `handle` routes only the three attachment commands into this branch.
        default: return .state(snapshot())
        }
    }

    /// Remove one attachment.
    ///
    /// The result is checked. `ConversationEngine.setAttachments` refuses once a turn has
    /// completed, and this discarded the `false`: the reply was a state identical to the one the
    /// caller already had, so a removal that did not happen was reported as one that did — and
    /// the Mac app's ✕ is always enabled, so a user could click it and see nothing at all.
    /// The rule the engine enforces is the one the web page already gates on.
    ///
    /// And an id that matches nothing is a refusal rather than a success, which is what `castVote`
    /// already answered for the same shape of request. Filtering produced a state identical to the
    /// one the caller had — a removal that never happened, reported as one that did.
    private func removeAttachment(_ id: String) -> EngineReply {
        guard let attachmentID = UUID(uuidString: id) else {
            return .refused("that is not a valid file id")
        }
        // Compared as a UUID, not as text: `UUID(uuidString:)` is case-insensitive while
        // `uuidString` is uppercase, so a client echoing the id lowercased passed the guard
        // above and then matched nothing — "there is no attached file with that id" for a
        // file that was attached. `castVote` already parses to a UUID for the same reason.
        let remaining = engine.attachments.filter { $0.id != attachmentID }
        guard remaining.count != engine.attachments.count else {
            return .refused("there is no attached file with that id")
        }
        guard engine.setAttachments(remaining) else {
            return .refused(Self.sourceMaterialIsFixed)
        }
        return .state(snapshot())
    }

    /// The two reads: the plain state, and the report once one exists.
    private func handleReads(_ request: EngineRequest) -> EngineReply {
        switch request {
        case .fetchState:
            return .state(snapshot())
        case .fetchReport:
            guard let report = engine.researchReport() else {
                return .refused("no report has been produced yet")
            }
            return .report(report.markdown())
        // Unreachable: `handle` routes only `.fetchState` and `.fetchReport` into this branch.
        default: return .state(snapshot())
        }
    }

    /// The line-ups and the ready-made scenarios.
    private func handleLineups(_ request: EngineRequest) -> EngineReply {
        switch request {
        case .listRosters(let mode):
            return .rosters(RosterLibrary.rosters(for: mode))
        case .listScenarios(let mode):
            return .scenarios(ScenarioLibrary.scenarios(for: mode))
        case .applyRoster(let id, let seed):
            return applyRoster(id: id, seed: seed)
        case .applyScenario(let id):
            return applyScenario(id: id)
        // Unreachable: `handle` routes only the four line-up commands into this branch.
        default: return .state(snapshot())
        }
    }

    /// The audience's verdict on one contribution, or on all of them.
    private func handleAudience(_ request: EngineRequest) -> EngineReply {
        switch request {
        case .castVote(let turnID, let verdict):
            guard let uuid = UUID(uuidString: turnID) else {
                return .refused("that is not a valid message id")
            }
            guard engine.castVote(turnID: uuid, verdict: verdict) else {
                return .refused("there is no contribution with that id to score")
            }
            return .state(snapshot())
        case .clearVotes:
            engine.clearVotes()
            return .state(snapshot())
        // Unreachable: `handle` routes only `.castVote` and `.clearVotes` into this branch.
        default: return .state(snapshot())
        }
    }

    /// Who the human moderator is, and the conversations kept from earlier runs.
    private func handleSavedAndModerator(_ request: EngineRequest) async -> EngineReply {
        switch request {
        case .setModerator(let identity):
            // Changeable while a conversation runs, unlike the topic: who is speaking is not a
            // property of the question, and a moderator who is halfway through an investigation
            // under the wrong name should be able to fix it.
            // The name is a label rather than an instruction, so it is truncated exactly as a seat
            // name is (the 40-character cap at `updateSeat`) instead of being refused: losing the
            // tail of a very long name is a smaller surprise than refusing to rename the moderator.
            var boundedIdentity = identity
            if boundedIdentity.name.count > Self.maximumFieldCharacters {
                boundedIdentity.name = String(
                    boundedIdentity.name.prefix(Self.maximumFieldCharacters))
            }
            engine.moderator = boundedIdentity
            return .state(snapshot())
        case .listSavedConversations:
            // Off the main actor: this decodes the whole index, and the engine's turn loop is on
            // the same actor.
            return .savedConversations(await store.listOffMainActor().map(Self.summary))
        case .loadSavedConversation(let id):
            guard let uuid = UUID(uuidString: id),
                let record = await store.conversationOffMainActor(id: uuid)
            else {
                return .refused("no saved conversation with that id")
            }
            guard engine.load(record) else {
                return .refused("a conversation is running; stop it before opening another")
            }
            return .state(snapshot())
        case .deleteSavedConversation(let id):
            guard let uuid = UUID(uuidString: id) else {
                return .refused("that is not a valid id")
            }
            _ = store.delete(id: uuid)
            // Off the main actor: this decodes the whole index, and the engine's turn loop is on
            // the same actor.
            return .savedConversations(await store.listOffMainActor().map(Self.summary))
        // Unreachable: `handle` routes only the moderator and saved-conversation commands here.
        default: return .state(snapshot())
        }
    }
}
