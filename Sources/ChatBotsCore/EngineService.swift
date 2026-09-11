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

    private let engine: ConversationEngine

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

    public init(engine: ConversationEngine, store: ConversationStore) {
        self.engine = engine
        self.store = store
        // The engine writes on every change, so the app does not have to remember to.
        engine.conversationStore = store
    }

    /// How many seats and what state, for a health check.
    public var seatCount: Int { engine.specs.count }

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
            guard engine.setTopic(topic) else {
                return .refused("the topic cannot be changed once the conversation has started")
            }
            return .state(snapshot())

        case .steer(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .refused("a message is required")
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
            return .state(snapshot())

        // ── Attachments ──────────────────────────────────────────────────────────────
        case .addAttachment(let filename, let contents):
            return addAttachment(filename: filename, contents: contents)

        case .removeAttachment(let id):
            engine.setAttachments(engine.attachments.filter { $0.id.uuidString != id })
            return .state(snapshot())

        case .clearAttachments:
            engine.setAttachments([])
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
            engine.moderator = identity
            return .state(snapshot())

        // ── Saved conversations ──────────────────────────────────────────────────────
        case .listSavedConversations:
            return .savedConversations(store.list().map(Self.summary))

        case .loadSavedConversation(let id):
            guard let uuid = UUID(uuidString: id), let record = store.conversation(id: uuid)
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
            return .savedConversations(store.list().map(Self.summary))

        case .newConversation:
            engine.startNewConversation()
            return .state(snapshot())
        }
    }

    /// Put a named line-up, or a draw, into the seats.
    ///
    /// Refused once the conversation has started, for the same reason the topic is: who is in
    /// the room is a decision about the conversation, and a seat that changed character
    /// mid-argument would make the earlier turns read as though someone else had said them.
    ///
    /// A draw reports its seed. Without that the line-up is a one-off — nobody can reproduce it,
    /// nobody can suggest it to somebody else, and a kept conversation cannot be continued with
    /// the same room.
    private func applyRoster(id: String, seed: UInt64) -> EngineReply {
        guard !engine.isRunning else {
            return .refused("who is in the room cannot be changed once the conversation has started")
        }

        let mode = engine.specs.first?.mode ?? .entertainment
        let personaIDs: [String]
        let described: String
        if id == RosterLibrary.randomID {
            let draw = RosterLibrary.draw(mode: mode, seats: engine.specs.count, seed: seed)
            personaIDs = draw.personaIDs
            described = "a random line-up (seed \(draw.seed))"
        } else if let roster = RosterLibrary.roster(id: id, mode: mode) {
            personaIDs = roster.personaIDs
            described = roster.name
        } else {
            return .refused("no line-up called \(id) in this mode")
        }

        guard !personaIDs.isEmpty else {
            return .refused("that line-up has nobody in it")
        }

        var names: [String] = []
        for (index, personaID) in personaIDs.enumerated() {
            guard index < engine.specs.count else { break }
            var spec = engine.specs[index]
            spec.personaID = personaID
            engine.updateSeat(spec)
            names.append(PersonaCatalog.style(id: personaID, mode: mode, seatIndex: index).name)
        }
        // Said out loud, because a draw nobody can see is a draw nobody can repeat. And when
        // the room is smaller than the line-up, said out loud that people were left out: a log
        // reading "The starting line-up — Research Moderator, Economist" looks like a two-person
        // line-up rather than a four-person one in a two-seat room.
        var line = "Line-up: \(described) — \(names.joined(separator: ", "))."
        if personaIDs.count > names.count {
            line += " The room holds \(engine.specs.count), so "
            line += "\(personaIDs.count - names.count) of the \(personaIDs.count) were left out."
        }
        engine.note(line)
        return .state(snapshot())
    }

    /// Everything a scenario changes, in one command.
    ///
    /// One command rather than four, because the parts only make sense together: setting the
    /// question without the panel, or the panel without the budget, would leave a session
    /// someone has to finish by hand — and a half-applied scenario is worse than none, since the
    /// user cannot tell which half took.
    private func applyScenario(id: String) -> EngineReply {
        guard !engine.isRunning else {
            return .refused("a scenario cannot be applied once the conversation has started")
        }
        guard let scenario = ScenarioLibrary.scenario(id: id) else {
            return .refused("no scenario called \(id)")
        }

        guard engine.setMode(scenario.mode) else {
            return .refused("the mode cannot be changed once the conversation has started")
        }
        guard engine.setTopic(scenario.topic) else {
            return .refused("the topic cannot be changed once the conversation has started")
        }
        if let depth = scenario.depth {
            // A refusal here is not fatal to the scenario: the question and the panel are the
            // substance, and the budget defaults to the mode's preset.
            _ = engine.setResearchBudget(depth)
        }

        var applied = "Scenario: \(scenario.topic)"
        if let rosterID = scenario.rosterID {
            let roster = applyRoster(id: rosterID, seed: RosterLibrary.freshSeed())
            if let reason = roster.refusal {
                engine.note("The scenario's panel could not be applied: \(reason)")
            } else {
                applied += " — with \(RosterLibrary.roster(id: rosterID, mode: scenario.mode)?.name ?? rosterID)"
            }
        }
        engine.note(applied + ". \(scenario.note)")
        return .state(snapshot())
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

    /// Stage an upload and read it.
    ///
    /// Written to a temporary file because the extractors take a URL — the same path the app
    /// uses for a dragged file — so there is one implementation of "what is in this document"
    /// rather than a second one for bytes.
    private func addAttachment(filename: String, contents: Data) -> EngineReply {
        guard engine.canAttachFiles else {
            return .refused("source material must be added before the conversation starts")
        }
        guard engine.attachments.count < 24 else {
            return .refused("too many attached files")
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "chatbots-upload-\(UUID().uuidString)")
        let temporary = directory.appending(path: filename)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.write(to: temporary)
        } catch {
            return .refused("could not stage the upload: \(error.localizedDescription)")
        }

        do {
            let document = try DocumentIngestorProvider.ingestor.add(url: temporary)
            guard !document.kind.isImage || engine.allSeatsSupportVision else {
                return .refused("images need every seat to support vision")
            }
            engine.setAttachments(engine.attachments + [document])
            return .state(snapshot())
        } catch let error as DocumentError {
            return .refused(error.errorDescription ?? "the file could not be read")
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// The whole state, which every successful command returns.
    public func snapshot() -> APISnapshot {
        let usage = engine.contextUsage
        let roomMode = engine.specs.first?.mode ?? .entertainment
        return APISnapshot(
            topic: engine.topic,
            mode: roomMode.rawValue,
            modeLabel: roomMode.label,
            status: engine.status.label,
            isRunning: engine.isRunning,
            isPaused: engine.isPaused,
            turnsCompleted: engine.startedTurns,
            seats: engine.specs.map(seat),
            messages: engine.displayTurns.map { turn in
                APISnapshot.Message(
                    id: turn.id.uuidString,
                    sequence: turn.sequence,
                    speaker: turn.speakerName,
                    speakerID: turn.speakerID,
                    kind: turn.kind.rawValue,
                    text: turn.content,
                    timestamp: turn.timestamp,
                    toolDetail: turn.toolDetail)
            },
            live: engine.liveSeats.map { live in
                APISnapshot.Live(
                    seatID: live.id,
                    isGenerating: live.isGenerating,
                    text: live.text,
                    reasoning: live.reasoning,
                    activity: live.activity,
                    toolLog: live.toolLog,
                    stats: live.stats)
            },
            notices: engine.notices.suffix(12).map { $0 },
            error: engine.lastError,
            contextTokens: usage.tokens,
            contextWindow: usage.window,
            contextFraction: usage.fraction,
            compactThreshold: engine.configuration.compactThreshold,
            attachments: engine.attachments.map { document in
                APIAttachment(
                    id: document.id.uuidString,
                    name: document.name,
                    kind: document.kind.rawValue,
                    summary: document.summary,
                    tokens: document.estimatedTokens,
                    wasTruncated: document.wasTruncated,
                    imageBase64: document.kind.isImage
                        ? document.imageData?.base64EncodedString() : nil)
            },
            canAttach: engine.canAttachFiles,
            imagesAllowed: engine.allSeatsSupportVision,
            availablePersonas: PersonaCatalog.styles(for: roomMode).map {
                APIPersona(
                    id: $0.id, name: $0.name, category: $0.group, summary: $0.summary,
                    emoji: $0.emoji, isAnalyst: $0.isAnalyst)
            },
            serverTime: .now,
            research: engine.researchStatus(),
            moderatorName: engine.moderator.speakerName,
            moderatorPersona: PersonaCatalog.style(
                id: engine.moderator.personaID,
                mode: roomMode,
                seatIndex: 0
            ).name,
            shareBase: shareBase,
            votes: engine.conversation.votes.map { vote in
                APISnapshot.Vote(
                    turnID: vote.turnID.uuidString, seatID: vote.seatID,
                    verdict: vote.verdict.rawValue)
            },
            audience: engine.audience.scores.map { entry in
                APISnapshot.AudienceEntry(
                    seatID: entry.seatID,
                    name: engine.specs.first { $0.id == entry.seatID }?.displayName ?? entry.seatID,
                    strong: entry.strong, weak: entry.weak, score: entry.score)
            },
            report: engine.researchReport().map { report in
                APISnapshot.ReportSummary(
                    question: report.question,
                    producedAt: report.producedAt,
                    stopReason: report.stopReason,
                    labelledClaims: report.labelledStatements,
                    isLabelled: report.isLabelled,
                    missingSections: report.missingSections,
                    markdown: report.markdown())
            })
    }

    private func seat(_ spec: AgentSpec) -> APISnapshot.Seat {
        let persona = spec.personaStyle
        return APISnapshot.Seat(
            id: spec.id,
            name: spec.displayName,
            personaEmoji: persona.emoji,
            model: spec.modelID,
            modelShortName: spec.modelLabel,
            backend: spec.backend.rawValue,
            backendLabel: spec.backend.label,
            personaName: persona.name,
            personaSummary: persona.summary,
            thinking: spec.thinking.rawValue,
            thinkingDetail: spec.thinking.detail,
            temperature: spec.temperature,
            topP: spec.topP,
            topK: spec.topK,
            minP: spec.minP,
            presencePenalty: spec.presencePenalty,
            repetitionPenalty: spec.repetitionPenalty,
            maxTokens: spec.maxTokens,
            webSearch: spec.webSearchEnabled,
            vision: spec.visionSupport.allowsImages,
            endpoint: spec.backend == .openAIResponses ? spec.openAI.baseURL : nil,
            apiModel: spec.backend == .openAIResponses ? spec.openAI.model : nil)
    }

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
