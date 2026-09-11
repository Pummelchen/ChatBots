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

    public init(engine: ConversationEngine) {
        self.engine = engine
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
        }
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
    /// The shared log, for a transport that reports changes rather than deltas.
    public var transcriptUpdates: AsyncStream<[Turn]> { engine.transcriptUpdates }

    /// The seats, for a transport that needs to describe the room before a snapshot exists.
    public var specs: [AgentSpec] { engine.specs }
}
