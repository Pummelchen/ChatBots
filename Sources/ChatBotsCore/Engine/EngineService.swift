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
        attachmentIngestor: @escaping @Sendable () throws -> DocumentIngestor = {
            try DocumentIngestorProvider.ingestor
        }
    ) {
        self.engine = engine
        self.store = store
        self.attachmentIngestor = attachmentIngestor
        // The engine writes on every change, so the app does not have to remember to.
        engine.conversationStore = store
    }

    /// How many seats this engine has.
    public var seatCount: Int { engine.specs.count }

    /// What this engine can serve right now.
    ///
    /// The finding was that `/api/health` answered an unconditional 200 with a hardcoded `"ok"`, so a
    /// client could not tell a listening engine from one that can serve, while the readiness signal
    /// that existed — `seatCount` — was read by nobody. This is the one definition the
    /// endpoint's status code and its body are both built from.
    ///
    /// A seat count on its own cannot answer the question: `ConversationEngine` traps on an empty
    /// roster, so the count is never zero and the number proved nothing. What can answer it is whether
    /// the seats' models loaded. Weights load when a conversation starts rather than at launch, so a
    /// seat that failed carries the reason from then on, and an engine whose every seat failed cannot
    /// serve a turn however healthy the port looks.
    ///
    /// What this deliberately does not claim: that the room is running or paused (`status` in the
    /// snapshot says that), or that a seat which has never been asked to load is ready — before the
    /// first start there is nothing to report, and silence is not failure.
    public struct Readiness: Sendable, Equatable {
        public var isReady: Bool
        /// How many seats the engine has.
        public var seats: Int
        /// The seats whose model could not be loaded, and why, by seat id.
        public var failedSeats: [String: String]
        /// Why the engine cannot serve a conversation, in a sentence a person can act on. Nil when it
        /// can — including when only some seats failed, which is degradation rather than an outage
        /// and is what `failedSeats` is for.
        public var reason: String?
    }

    /// What this engine can serve right now. See `Readiness`.
    public var readiness: Readiness {
        let seats = seatCount
        guard seats > 0 else {
            // Unreachable through `ConversationEngine`, which requires a seat. Kept so the answer is
            // total rather than relying on a trap somewhere else, and because a service is given its
            // engine rather than building it.
            return Readiness(
                isReady: false, seats: 0, failedSeats: [:],
                reason: "the engine has no seats, so there is nobody to speak")
        }
        let failed = engine.modelLoadFailures
        return Readiness(
            isReady: failed.count < seats,
            seats: seats,
            failedSeats: failed,
            reason: failed.count >= seats ? "no seat could load its model" : nil)
    }

    /// Handle one request.
    ///
    /// Returns a reply, or nil when the request is a read that the caller has already been
    /// given another way. Throws only for something genuinely exceptional; a refusal — a
    /// locked topic, an image no seat can see — is an `EngineReply.refused`, because it is an
    /// answer the user should read rather than an error to log.
    public func handle(_ request: EngineRequest) async -> EngineReply {
        switch request {
        // ── Transport controls ───────────────────────────────────────────────────────
        case .start:
            engine.startOrRestart()
            return .state(snapshot())

        case .pause:
            engine.pause()
            return .state(snapshot())

        case .resume:
            engine.resume()
            return .state(snapshot())

        case .stop:
            engine.stop()
            return .state(snapshot())

        case .reset:
            engine.reset()
            return .state(snapshot())

        case .compact:
            engine.compactNow()
            return .state(snapshot())

        // ── Content ──────────────────────────────────────────────────────────────────
        case .setTopic(let topic):
            // A blank topic is refused rather than blanking the question. Restoring from
            // saved settings sets the topic directly, so this does not affect startup.
            guard !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .refused("a topic is required")
            }
            // Refused rather than truncated: a topic is a command, and a silently shortened question is
            // a question the room answers differently from the one that was asked.
            guard topic.count <= Self.maximumFieldCharacters else {
                return .refused(
                    "a topic is limited to \(Self.maximumFieldCharacters) characters")
            }
            guard engine.setTopic(topic) else {
                return .refused("the topic cannot be changed once the conversation has started")
            }
            return .state(snapshot())

        case .steer(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .refused("a message is required")
            }
            guard text.count <= Self.maximumFieldCharacters else {
                return .refused(
                    "a message is limited to \(Self.maximumFieldCharacters) characters")
            }
            engine.steer(text)
            return .state(snapshot())

        // ── View and mode ────────────────────────────────────────────────────────────
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

        // ── Seats ────────────────────────────────────────────────────────────────────
        case .updateSeat(let change):
            guard let index = engine.specs.firstIndex(where: { $0.id == change.seatID }) else {
                return .refused("no seat called \(change.seatID)")
            }
            var spec = engine.specs[index]
            // Only what was asked for. A nil field means "leave it", so renaming a seat
            // cannot reset its persona.
            if let name = change.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                spec.displayName = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
            }
            if let personaID = change.personaID { spec.personaID = personaID }
            if let thinking = change.thinking { spec.thinking = thinking }
            if let backend = change.backend { spec.backend = backend }
            if let baseURL = change.baseURL { spec.openAI.baseURL = baseURL.trimmingCharacters(in: .whitespaces) }
            if let model = change.apiModel { spec.openAI.model = model }
            if let key = change.apiKey { spec.openAI.apiKey = key }
            engine.updateSeat(spec)
            // The checkpoint last, because it is the one field that replaces an engine rather than
            // editing one: `setModel` holds the rule about when that is allowed, so it is stated
            // once. A refusal here is an answer — a change that could not be made is never reported
            // as one that was.
            if let modelID = change.modelID {
                let resolved = ModelCatalog.resolve(modelID)
                guard !resolved.isEmpty else { return .refused("a model is required") }
                if resolved != spec.modelID, !engine.setModel(resolved, for: spec.id) {
                    return .refused("the model cannot be changed while a turn is in flight")
                }
            }
            return .state(snapshot())

        // ── Attachments ──────────────────────────────────────────────────────────────
        case .addAttachment(let filename, let contents):
            return await addAttachment(filename: filename, contents: contents)

        case .removeAttachment(let id):
            // The result is checked. `ConversationEngine.setAttachments` refuses once a turn has
            // completed, and this discarded the `false`: the reply was a state identical to the one the
            // caller already had, so a removal that did not happen was reported as one that did — and
            // the Mac app's ✕ is always enabled, so a user could click it and see nothing at all.
            // The rule the engine enforces is the one the web page already gates on.
            //
            // And an id that matches nothing is a refusal rather than a success, which is what `castVote`
            // already answered for the same shape of request. Filtering produced a state identical to the
            // one the caller had — a removal that never happened, reported as one that did.
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

        case .clearAttachments:
            guard engine.setAttachments([]) else {
                return .refused(Self.sourceMaterialIsFixed)
            }
            return .state(snapshot())

        // ── Reads ────────────────────────────────────────────────────────────────────
        case .fetchState:
            return .state(snapshot())

        case .fetchReport:
            guard let report = engine.researchReport() else {
                return .refused("no report has been produced yet")
            }
            return .report(report.markdown())

        // ── Line-ups and scenarios ───────────────────────────────────────────────────
        case .listRosters(let mode):
            return .rosters(RosterLibrary.rosters(for: mode))

        case .listScenarios(let mode):
            return .scenarios(ScenarioLibrary.scenarios(for: mode))

        case .applyRoster(let id, let seed):
            return applyRoster(id: id, seed: seed)

        case .applyScenario(let id):
            return applyScenario(id: id)

        // ── The audience ─────────────────────────────────────────────────────────────
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

        // ── The human moderator ──────────────────────────────────────────────────────
        case .setModerator(let identity):
            // Changeable while a conversation runs, unlike the topic: who is speaking is not a
            // property of the question, and a moderator who is halfway through an investigation
            // under the wrong name should be able to fix it.
            // The name is a label rather than an instruction, so it is truncated exactly as a seat name
            // is (the 40-character cap at `updateSeat`) instead of being refused: losing the tail of a
            // very long name is a smaller surprise than refusing to rename the moderator.
            var boundedIdentity = identity
            if boundedIdentity.name.count > Self.maximumFieldCharacters {
                boundedIdentity.name = String(
                    boundedIdentity.name.prefix(Self.maximumFieldCharacters))
            }
            engine.moderator = boundedIdentity
            return .state(snapshot())

        // ── Saved conversations ──────────────────────────────────────────────────────
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

        case .newConversation:
            engine.startNewConversation()
            return .state(snapshot())
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
