// ChatBotsCLI — the default headless conversation run
//
// What `chatbots-cli --topic … --turns N` does: stream the transcript to stdout, print progress so
// a long turn does not look hung, and report the tool traffic as it happens. Split out of
// `main.swift`, which held the entry point, the command line and every mode in one 1132-line file.

import ChatBotsCore
import Foundation

@MainActor
enum HeadlessRun {

    static func run(context: RunContext) async {
        let options = context.options
        logHeader(context: context)
        let engine = makeEngine(context: context)
        attachDocuments(options: options, engine: engine)

        let transcriptTask = Task { await renderTranscript(engine) }

        let activityTask = Task { await streamActivity(engine) }

        let noticeTask = Task { await reportNotices(engine) }
        let statusTask = Task { await reportStatus(engine) }

        engine.start(topic: options.topic)
        while engine.status.isActive || engine.isLoopRunning {
            try? await Task.sleep(for: .milliseconds(250))
        }

        // Let the last transcript update land before tearing the streams down.
        try? await Task.sleep(for: .milliseconds(300))

        transcriptTask.cancel()
        activityTask.cancel()
        noticeTask.cancel()
        statusTask.cancel()

        header("END")
        let exchanged = engine.conversation.turns.filter { $0.kind == .chat }.count
        log("done — \(exchanged) messages exchanged")
        for notice in engine.notices {
            log("  note: \(notice)")
        }

        // The exit code has to reflect what happened. This mode ended at `header("END")`
        // whatever occurred — the same false success the benchmark and the probes were fixed
        // for — so a run in which a turn errored, or in which no turn produced a message at all,
        // reported 0 to the install or CI script reading the status.
        if engine.failedTurns > 0 {
            log("\(engine.failedTurns) turn(s) failed")
            exit(1)
        }
        if exchanged == 0 {
            log("no turn produced a message")
            exit(1)
        }
    }

    /// The run banner: what this run is, seat by seat, and where its models are.
    private static func logHeader(context: RunContext) {
        let options = context.options
        let specs = context.specs

        log("ChatBots headless run")
        log("  topic     : \(options.topic)")
        log("  turns     : \(options.turns)")
        log("  seat A    : \(options.modelA)")
        log("  seat B    : \(options.modelB)")
        log("  thinking  : \(specs[0].thinking.rawValue) — \(specs[0].thinking.detail)")
        for spec in specs {
            log("  \(spec.id) style: \(spec.persona.name) — \(spec.persona.summary)")
            log(
                "  \(spec.id) backend: \(spec.backend.rawValue)"
                    + (spec.backend == .openAIResponses
                        ? " → \(spec.openAI.baseURL) as \(spec.openAI.model)" : ""))
        }
        log("  models    : \(context.modelsRoot.path)")
        log("  tavily    : \(TavilyClient.isConfigured ? "configured" : "MISSING")")
        print("")
    }

    /// The engine this run drives, built from the flags and the context's seats.
    private static func makeEngine(context: RunContext) -> ConversationEngine {
        let options = context.options
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        configuration.maxTurns = max(1, options.turns)
        if let threshold = options.compactThreshold { configuration.compactThreshold = threshold }
        if let keep = options.keepRecent { configuration.compactKeepRecentTurns = keep }

        let seats = zip(context.specs, context.engines).map { spec, mlx in
            ConversationEngine.Seat(
                spec: spec,
                mlx: mlx,
                openAI: OpenAIResponsesEngine(spec: spec)
            )
        }
        var engineConfiguration = configuration
        if let depth = options.researchDepth {
            engineConfiguration.researchBudget = ResearchBudget.preset(depth)
        }
        return ConversationEngine(seats: seats, configuration: engineConfiguration)
    }

    /// Source material, read the same way the app reads it. Absent attachments leave the engine
    /// as it was.
    private static func attachDocuments(options: Options, engine: ConversationEngine) {
        guard !options.attachments.isEmpty else { return }
        DocumentIngestorProvider.install(SystemDocumentExtractor.ingestor)
        let (documents, failures) = SystemDocumentExtractor.add(
            urls: options.attachments.map { URL(fileURLWithPath: $0) })
        for failure in failures { log("  attachment refused: \(failure)") }
        guard engine.setAttachments(documents) else {
            log("  attachments must be added before the conversation starts")
            exit(2)
        }
        for document in documents {
            log("  attached: \(document.name) — \(document.summary)")
        }
        if documents.contains(where: { $0.kind.isImage }) {
            log("  images allowed: \(engine.allSeatsSupportVision)")
        }
    }

    /// Render the log as it grows, printing each entry once.
    private static func renderTranscript(_ engine: ConversationEngine) async {
        var printedTurnIDs = Set<UUID>()
        for await turns in engine.transcriptUpdates {
            for turn in turns where !printedTurnIDs.contains(turn.id) {
                printedTurnIDs.insert(turn.id)
                guard turn.kind != .tool else { continue }
                header(label(for: turn))
                print(turn.content)
            }
        }
    }

    /// The heading a turn gets in the transcript.
    private static func label(for turn: Turn) -> String {
        switch turn.kind {
        case .topic: return "\(turn.speakerName.uppercased()) · TOPIC"
        case .introduction: return "SETUP"
        case .steering: return turn.speakerName.uppercased()
        case .direction: return "RESEARCH MODERATOR — ASSIGNMENT"
        case .tool: return "TOOL"
        case .summary: return "CONDENSED EARLIER DISCUSSION"
        case .report: return "RESEARCH MODERATOR — FINAL REPORT"
        case .chat: return turn.speakerName.uppercased()
        }
    }

    /// Stream progress so a long turn does not look hung.
    private static func streamActivity(_ engine: ConversationEngine) async {
        for await event in engine.events {
            switch event {
            case .toolCall(let agentID, let name, let query):
                log("  [\(agentID)] → \(name)(\(UTF8Text.prefix(query, 70)))")
            case .toolResult(let agentID, let name, let summary, _, _):
                log("  [\(agentID)] ← \(name): \(summary)")
            case .toolFailure(let agentID, let name, let message):
                log("  [\(agentID)] ✗ \(name): \(message)")
            case .turnFinished(let agentID, _, let stats):
                log(
                    "  [\(agentID)] \(stats.generationTokens) tok in "
                        + "\(String(format: "%.1f", stats.seconds))s "
                        + "(\(String(format: "%.1f", stats.tokensPerSecond)) tok/s, "
                        + "stop=\(stats.stopReason))"
                        + (stats.prefillSeconds > 0
                            ? String(
                                format: " | prefill %d tok in %.2fs (%.0f tok/s)",
                                stats.promptTokens, stats.prefillSeconds,
                                stats.prefillTokensPerSecond)
                            : ""))
            case .turnFailed(let agentID, let message):
                log("  [\(agentID)] ✗ \(message)")
            case .token, .reasoning, .turnStarted:
                break
            }
        }
    }

    private static func reportNotices(_ engine: ConversationEngine) async {
        for await notices in engine.noticeUpdates {
            if let last = notices.last {
                log("  note: \(last)")
            }
        }
    }

    private static func reportStatus(_ engine: ConversationEngine) async {
        for await status in engine.statusUpdates {
            if case .running(let turn) = status {
                log("turn \(turn)…")
            } else if case .failed(let message) = status {
                log("failed: \(message)")
            }
        }
    }
}
