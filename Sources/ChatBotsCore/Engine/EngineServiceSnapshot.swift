// ChatBotsCore — the state every successful command returns
//
// Split out of `EngineService.swift`, which held the dispatch, the attachment pipeline, the
// snapshot and the line-up commands in one 814-line file. The snapshot is the wire view both front
// ends read: one flat `APISnapshot` assembled from the engine, with the monotonically increasing
// revision a client orders two of them by.

import Foundation

extension EngineService {

    /// The whole state, which every successful command returns.
    public func snapshot() -> APISnapshot {
        let usage = engine.contextUsage
        let roomMode = engine.specs.first?.mode ?? .entertainment
        snapshotRevision += 1
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
                // Metadata only: the bytes stay in the engine, which is where the model request
                // reads them from. They used to be re-encoded into every snapshot.
                APIAttachment(
                    id: document.id.uuidString,
                    name: document.name,
                    kind: document.kind.rawValue,
                    summary: document.summary,
                    tokens: document.estimatedTokens,
                    wasTruncated: document.wasTruncated)
            },
            canAttach: engine.canAttachFiles,
            imagesAllowed: engine.allSeatsSupportVision,
            availablePersonas: PersonaCatalog.styles(for: roomMode).map {
                APIPersona(
                    id: $0.id, name: $0.name, category: $0.group, summary: $0.summary,
                    emoji: $0.emoji, isAnalyst: $0.isAnalyst)
            },
            // The checkpoint list travels with every state for the same reason the personas do: a
            // front end offers what this engine can actually run, without a second copy of the
            // catalogue to keep in step (ModelCatalog).
            availableModels: ModelCatalog.choices.map { choice in
                APIModelOption(
                    id: choice.id, name: choice.name, summary: choice.summary,
                    sizeLabel: choice.sizeLabel)
            },
            serverTime: .now,
            revision: snapshotRevision,
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
}
