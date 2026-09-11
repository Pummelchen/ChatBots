// chatbots-cli — drive the two-seat conversation without the GUI
//
// Used both as a smoke test for the real MLX engines and as a way to run the
// conversation from a terminal. It consumes exactly the same core types the app does.
//
//   chatbots-cli --topic "…" --turns 4                  converse
//   chatbots-cli --benchmark                            measure both seats' throughput
//   chatbots-cli --benchmark --solo                     measure one seat, then exit

import ChatBotsCore
import Foundation
import MLX

// MARK: - Arguments

struct Options {
    var topic = "Why are eggs not round?"
    var turns = 4
    var modelA = AgentSpec.defaultModelID
    var modelB = AgentSpec.defaultModelID
    var tavilyKey: String?
    var benchmark = false
    var solo = false
    var memoryProbe = false
    var sessionProbe = false
    var compactThreshold: Double?
    var exportSample = false
    var check = false
    var serve = false
    var mode = DiscussionMode.entertainment
    var listCharacters = false
    var attachments: [String] = []
    var seed = false
    var researchDepth: ResearchBudget.Depth?
    var listRoles = false
    var port = 7788
    var contextWindow: Int?
    var keepRecent: Int?
    /// Cap on answer tokens per turn; `nil` keeps the seat's own budget.
    var maxTokens: Int?
    /// Thinking level for both seats; `nil` keeps the preset (medium).
    var thinking: ThinkingMode?
    var personaA: String?
    var personaB: String?
    var backendA: AgentSpec.Backend = .mlx
    var backendB: AgentSpec.Backend = .mlx
    var baseURL = "http://localhost:1234"
    var apiModel = "mlx-community/Qwen3.5-4B-MLX-4bit"
    var apiKey: String?

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func next() -> String? {
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }
            switch argument {
            case "--topic", "-t": options.topic = next() ?? options.topic
            case "--turns", "-n": options.turns = Int(next() ?? "") ?? options.turns
            case "--model-a": options.modelA = next() ?? options.modelA
            case "--model-b": options.modelB = next() ?? options.modelB
            case "--key": options.tavilyKey = next()
            case "--max-tokens": options.maxTokens = Int(next() ?? "")
            case "--backend-a":
                options.backendA = AgentSpec.Backend(rawValue: next() ?? "") ?? .mlx
            case "--backend-b":
                options.backendB = AgentSpec.Backend(rawValue: next() ?? "") ?? .mlx
            case "--base-url": options.baseURL = next() ?? options.baseURL
            case "--api-model": options.apiModel = next() ?? options.apiModel
            case "--api-key": options.apiKey = next()
            case "--persona-a": options.personaA = next()
            case "--persona-b": options.personaB = next()
            case "--list-personas":
                for category in Persona.Category.allCases {
                    print("\(category.rawValue):")
                    for persona in PersonaLibrary.personas(in: category) {
                        print("  \(persona.id.padding(toLength: 18, withPad: " ", startingAt: 0)) \(persona.summary)")
                    }
                }
                exit(0)
            case "--thinking":
                let raw = next() ?? ""
                guard let mode = ThinkingMode(rawValue: raw.lowercased()) else {
                    FileHandle.standardError.write(Data("unknown thinking mode: \(raw)\n".utf8))
                    exit(2)
                }
                options.thinking = mode
            case "--benchmark": options.benchmark = true
            case "--memory-probe": options.memoryProbe = true
            case "--session-probe": options.sessionProbe = true
            case "--export-sample": options.exportSample = true
            case "--check": options.check = true
            case "--serve": options.serve = true
            case "--attach": options.attachments.append(next() ?? "")
            case "--seed": options.seed = true
            case "--research":
                let raw = next() ?? ""
                if let depth = ResearchBudget.Depth(rawValue: raw) {
                    options.researchDepth = depth
                    options.mode = .research
                } else {
                    FileHandle.standardError.write(
                        Data("unknown research budget: \(raw) — try quick, standard or deep\n".utf8))
                    exit(2)
                }
            case "--list-characters": options.listCharacters = true
            case "--list-roles": options.listRoles = true
            case "--mode":
                let raw = next() ?? ""
                if let parsed = DiscussionMode(rawValue: raw) {
                    options.mode = parsed
                } else {
                    FileHandle.standardError.write(
                        Data("unknown mode: \(raw) — try entertainment or research\n".utf8))
                    exit(2)
                }
            case "--port": options.port = Int(next() ?? "") ?? options.port
            case "--compact-threshold": options.compactThreshold = Double(next() ?? "")
            case "--context-window": options.contextWindow = Int(next() ?? "")
            case "--compact-keep": options.keepRecent = Int(next() ?? "")
            case "--solo": options.solo = true
            case "--help", "-h":
                print(Self.usage)
                exit(0)
            default:
                FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
                print(Self.usage)
                exit(2)
            }
            index += 1
        }
        return options
    }

    static let usage = """
        chatbots-cli — run two local LLMs in conversation

        USAGE
          chatbots-cli [options]

        OPTIONS
          -t, --topic <text>       Topic to discuss (default: "Why are eggs not round?")
          -n, --turns <count>      Number of LLM turns to run (default: 4)
              --model-a <id>       MLX checkpoint for seat A (default: \(AgentSpec.defaultModelID))
              --model-b <id>       MLX checkpoint for seat B
              --key <key>          Tavily API key (env TAVILY_API_KEY, else built-in dev key)
              --max-tokens <n>     Cap answer tokens per turn
              --thinking <mode>    off | minimal | low | medium | high | unlimited
              --backend-a <mlx|openAIResponses>   Engine for seat A (default: mlx)
              --backend-b <mlx|openAIResponses>   Engine for seat B
              --base-url <url>     Server for the API backend (default: http://localhost:1234)
              --api-model <id>     Model id as the server names it
              --api-key <key>      Bearer token, if the server wants one
              --persona-a <id>     Style for seat A (see --list-personas)
              --persona-b <id>     Style for seat B
              --list-personas      Print the persona library and exit
              --benchmark          Measure seat throughput instead of chatting
              --solo               With --benchmark: measure seat A only, then exit
              --memory-probe       Report MLX GPU memory across loading and turns

        Seat A and seat B are separate model instances with independent sampling
        parameters, so a headless run exercises exactly the same path as the GUI.
        """

    private func configured(
        _ spec: AgentSpec, persona: String?, backend: AgentSpec.Backend
    ) -> AgentSpec {
        var spec = spec
        if let maxTokens { spec.maxTokens = maxTokens }
        if let thinking { spec.thinking = thinking }
        if let persona { spec.personaID = persona }
        if let contextWindow { spec.contextWindow = contextWindow }
        spec.backend = backend
        spec.openAI = OpenAIEndpoint(baseURL: baseURL, model: apiModel, apiKey: apiKey)
        return spec
    }

    var specA: AgentSpec {
        configured(AgentSpec.seatA(modelID: modelA), persona: personaA, backend: backendA)
    }
    var specB: AgentSpec {
        configured(AgentSpec.seatB(modelID: modelB), persona: personaB, backend: backendB)
    }
}

// MARK: - Output helpers

let stderr = FileHandle.standardError

func log(_ message: String) {
    stderr.write(Data((message + "\n").utf8))
}

func header(_ title: String) {
    print("")
    print(String(repeating: "─", count: 78))
    print(title)
    print(String(repeating: "─", count: 78))
}


// MARK: - Setup

// Model storage lives in the project's `models/` folder; set before any engine loads.
let modelsRoot = ModelStore.prepare()
let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

// The self-test an installer runs: it proves the runtime, the Metal library and the
// checkpoint all work together on this machine, and it does so without needing to read or
// interpret a conversation.
if options.check {
    let spec = AgentSpec.seat(index: 0, modelID: options.modelA ?? AgentSpec.defaultModelID)
    log("Checking seat A: \(spec.modelID)")
    let engine = MLXEngine(spec: spec)
    do {
        try await engine.load()
        let window = await engine.contextWindow
        log("  model loaded — context window \(window) tokens")
        let started = Date()
        let reply = try await engine.generate(
            messages: [
                .init(role: .system, content: "You are terse."),
                .init(role: .user, content: "Reply with the single word: ready"),
            ],
            tools: [], onToolCall: { _, _ in }, onEvent: { _ in })
        let seconds = Date().timeIntervalSince(started)
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        log(String(format: "  generated %d characters in %.1fs", trimmed.count, seconds))
        if trimmed.isEmpty {
            FileHandle.standardError.write(Data("check failed: the model produced no output\n".utf8))
            exit(1)
        }
        log("Check passed — the app is ready to run")
        exit(0)
    } catch {
        FileHandle.standardError.write(
            Data("check failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// Printing the export format, with no model involved: handy for checking what a saved
// conversation looks like, and for support.
if options.exportSample {
    // Named, so the sample shows what a real log looks like.
    let specA = AgentSpec.SeatRoster.namedSpecs()[0]
    let specB = AgentSpec.SeatRoster.namedSpecs()[1]
    let stamp: (String) -> Date = { value in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value) ?? Date()
    }
    let turns = [
        Turn(
            sequence: 1, speakerName: "Moderator", kind: .topic,
            content: options.topic, timestamp: stamp("2026-12-25 13:15:04")),
        Turn(
            sequence: 2, speakerName: specA.displayName, kind: .chat,
            content: "An ovoid resists a point load at the tip far better than a sphere does.\nThe shell thickens where curvature is highest.",
            timestamp: stamp("2026-12-25 13:15:41")),
        Turn(
            sequence: 3, speakerName: specB.displayName, kind: .chat,
            content: "Which part of that is established? A sphere is the minimal surface for a given volume.",
            timestamp: stamp("2026-12-25 13:16:02")),
    ]
    print(TranscriptWriter.text(
        topic: options.topic, turns: turns, participants: [specA, specB],
        exportedAt: stamp("2026-12-25 13:20:00")))
    exit(0)
}

if let key = options.tavilyKey {
    setenv("TAVILY_API_KEY", key, 1)
}

// The roster decides how many seats, so `CHATBOTS_SEATS=4` gives four — the same rule the
// app uses. The first two keep the CLI's own flags; any beyond that take their defaults, so
// the flags did not have to grow a third and fourth variant to make a four-seat run possible.
var specs: [AgentSpec] = {
    let count = AgentSpec.SeatRoster.count()
    var built = [options.specA, options.specB]
    if count > 2 {
        built.append(contentsOf: AgentSpec.makeSeats(count: count).dropFirst(2))
    }
    built = Array(built.prefix(count))
    // Named like the app: one female and one male, at random. The CLI built its own first two
    // seats, so it has to ask for this rather than inheriting it.
    var generator = SystemRandomNumberGenerator()
    AgentSpec.assignNames(to: &built, using: &generator)
    return built
}()
// The mode decides which library a persona comes from, so it is applied to every seat
// before anything reads one. A seat holding an identifier from the other library resolves
// to that mode's default rather than to nothing.
for index in specs.indices {
    specs[index].mode = options.mode
    if !options.mode.owns(personaID: specs[index].personaID) {
        specs[index].personaID = options.mode.defaultPersonaID(forSeat: index)
    }
}

/// One engine per seat. The CLI wires its own so it can route events straight to stdout.
let registry = WebToolbox.makeRegistry()
let engines = specs.map { spec in
    MLXEngine(spec: spec, toolRegistry: registry) { state in
        if case .loading(let progress) = state, progress > 0, progress < 1 {
            let percent = Int(progress * 100)
            if percent % 25 == 0 { log("  \(spec.id): downloading \(percent)%") }
        }
    }
}

func loadSeat(_ engine: MLXEngine, label: String) async -> Bool {
    do {
        try await engine.load()
        return true
    } catch {
        log("  \(label) failed to load: \(error.localizedDescription)")
        return false
    }
}

// MARK: - Benchmark

/// Measures how two seats behave when they share the GPU: each answers the same prompt
/// alone, then both answer simultaneously. Also the cheapest way to prove a given
/// checkpoint loads and generates at all.
func runBenchmark() async {
    log("max tokens per turn: \(options.maxTokens.map(String.init) ?? "seat default")")
    let prompt = [
        PromptMessage(role: .system, content: "Answer in about 120 words. Be concrete."),
        PromptMessage(
            role: .user,
            content: "In about 120 words: why are bird eggs ovoid rather than spherical?"),
    ]

    func measure(_ engine: MLXEngine, label: String) async -> Double {
        log("  starting \(label)…")
        do {
            _ = try await engine.generate(
                messages: prompt, tools: [], onToolCall: { _, _ in }, onEvent: { _ in })
            let stats = await engine.lastStats
            let rate = stats?.tokensPerSecond ?? 0
            log(
                "  \(label): \(String(format: "%.1f", rate)) tok/s "
                    + "(\(stats?.generationTokens ?? 0) tok in "
                    + "\(String(format: "%.1f", stats?.seconds ?? 0))s)")
            return rate
        } catch {
            log("  \(label): FAILED — \(error.localizedDescription)")
            return 0
        }
    }

    log("loading…")
    let loadedA = await loadSeat(engines[0], label: "A")
    log("  A loaded: \(loadedA)")
    guard loadedA, !options.solo else {
        if loadedA { _ = await measure(engines[0], label: "A") }
        return
    }

    let loadedB = await loadSeat(engines[1], label: "B")
    log("  B loaded: \(loadedB)")

    log("alone, sequential:")
    let aloneA = await measure(engines[0], label: "A")
    let aloneB = await measure(engines[1], label: "B")

    log("simultaneous:")
    async let concurrentA = measure(engines[0], label: "A")
    async let concurrentB = measure(engines[1], label: "B")
    let (sharedA, sharedB) = await (concurrentA, concurrentB)

    func verdict(_ alone: Double, _ shared: Double) -> String {
        guard alone > 0, shared > 0 else { return "n/a" }
        return String(format: "%.0f%% of its solo rate", shared / alone * 100)
    }
    log("verdict:")
    log("  A: \(verdict(aloneA, sharedA))")
    log("  B: \(verdict(aloneB, sharedB))")
}

if options.benchmark {
    await runBenchmark()
    exit(0)
}

// Measures what keeping one conversation alive across turns would save: three prompts
// that share a growing prefix, through one engine, with prefill reported each time.
if options.sessionProbe {
    let engine = engines[0]
    try? await engine.load()
    var turns: [PromptMessage] = [
        .init(role: .system, content: "You are a participant in a discussion about eggs.")
    ]
    log("session probe — one engine, three prompts sharing a growing prefix")
    if let results = try? await engine.sessionReuseProbe() {
        log("  one ChatSession, three successive calls:")
        for (index, result) in results.enumerated() {
            log(
                String(
                    format: "    call %d: prefilled %d tok in %.2fs",
                    index + 1, result.prefilled, result.prefillSeconds))
        }
    }
    for turn in 1...3 {
        turns.append(
            .init(
                role: turn == 1 ? .user : .assistant,
                content: turn == 1
                    ? "Why are bird eggs ovoid rather than spherical? Answer in one sentence."
                    : "And what does that imply for shell thickness? Answer in one sentence."))
        _ = try? await engine.generate(
            messages: turns, tools: [], onToolCall: { _, _ in }, onEvent: { _ in })
        if let stats = await engine.lastStats {
            log(
                String(
                    format: "  turn %d: prompt %d tok, prefill %.2fs (%.0f tok/s), gen %.1f tok/s",
                    turn, stats.promptTokens, stats.prefillSeconds,
                    stats.prefillTokensPerSecond, stats.tokensPerSecond))
        }
        // The reply would be appended as an assistant message in the real loop.
        turns.append(.init(role: .assistant, content: "…"))
    }
    exit(0)
}

if options.memoryProbe {
    let mib = 1024.0 * 1024.0
    func report(_ label: String) {
        log(String(
            format: "  %-22@ active=%7.1f MiB  cache=%7.1f MiB  peak=%7.1f MiB  gpuLimit=%7.1f MiB  memLimit=%7.1f MiB",
            label as NSString,
            Double(GPU.activeMemory) / mib,
            Double(GPU.cacheMemory) / mib,
            Double(GPU.peakMemory) / mib,
            Double(GPU.memoryLimit) / mib,
            Double(Memory.memoryLimit) / mib))
    }
    log("GPU memory (one seat, then both, then a turnaround):")
    report("start")
    _ = await loadSeat(engines[0], label: "A")
    report("after load A")
    _ = await loadSeat(engines[1], label: "B")
    report("after load B")
    let prompt = [
        PromptMessage(role: .system, content: "Answer briefly."),
        PromptMessage(role: .user, content: "Name three shapes."),
    ]
    for turn in 1...3 {
        _ = try? await engines[turn % 2].generate(
            messages: prompt, tools: [], onToolCall: { _, _ in }, onEvent: { _ in })
        report("after turn \(turn)")
    }
    exit(0)
}

// Listing the persona libraries, so the pickers are discoverable from the terminal as well
// as from the interface.
if options.listCharacters {
    print("Entertainment cast — \(SocialLibrary.all.count) characters\n")
    for group in SocialCharacter.Group.allCases {
        print("\(group.rawValue):")
        for character in SocialLibrary.all where character.group == group {
            print("  \(character.emoji) \(character.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(character.summary)")
        }
        print("")
    }
    print("Shared styles are also available in both modes: see --list-personas")
    exit(0)
}
if options.listRoles {
    print("Research analysts — \(AnalystLibrary.all.count) roles\n")
    for group in AnalystRole.Group.allCases {
        print("\(group.rawValue):")
        for role in AnalystLibrary.all where role.group == group {
            print("  \(role.emoji) \(role.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(role.summary)")
        }
        print("")
    }
    print("Default line-up: " + AnalystLibrary.startingLineUp.map(\.name).joined(separator: ", "))
    exit(0)
}

// MARK: - Server
//
// The same engine the printed run uses, behind HTTP instead of stdout. Both front ends —
// the web page and the SwiftUI app — talk to this, so there is one conversation engine and
// one place where a conversation actually lives.
if options.serve {
    let configuration = ConversationEngine.Configuration()
    let seats = zip(specs, engines).map { spec, mlx in
        ConversationEngine.Seat(spec: spec, mlx: mlx, openAI: OpenAIResponsesEngine(spec: spec))
    }
    var engineConfiguration = configuration
if let depth = options.researchDepth {
    engineConfiguration.researchBudget = ResearchBudget.preset(depth)
}
let engine = ConversationEngine(seats: seats, configuration: engineConfiguration)

// Source material, read the same way the app reads it.
if !options.attachments.isEmpty {
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
    if !options.topic.isEmpty { _ = engine.setTopic(options.topic) }
    // A sample conversation, for laying out the interface without waiting for a model.
    if options.seed { engine.seed(SampleConversation.turns(topic: engine.topic)) }

    // Documents are read by the app's extractors, which live in the app target; the CLI
    // links the same code, so the server can accept uploads too.
    DocumentIngestorProvider.install(SystemDocumentExtractor.ingestor)

    let server = APIServer(engine: engine, port: UInt16(options.port))
    do {
        try server.start()
    } catch {
        FileHandle.standardError.write(
            Data("could not start the server on port \(options.port): \(error.localizedDescription)\n".utf8))
        exit(1)
    }

    log("ChatBots server listening on http://127.0.0.1:\(options.port)")
    log("  state   : GET  /api/state")
    log("  events  : GET  /api/events  (server-sent events)")
    log("  control : POST /api/start | /api/pause | /api/resume | /api/stop | /api/reset")
    log("  models  : \(specs.map(\.backendLabel).joined(separator: ", "))")
    log("Press Control-C to stop.")

    // Keep the process alive; the HTTP listener runs on its own queue.
    while true {
        try? await Task.sleep(for: .seconds(3600))
    }
}

// MARK: - Conversation

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
log("  models    : \(modelsRoot.path)")
log("  tavily    : \(TavilyClient.isConfigured ? "configured" : "MISSING")")
print("")

var configuration = ConversationEngine.Configuration()
configuration.pace = .zero
configuration.maxTurns = max(1, options.turns)
if let threshold = options.compactThreshold { configuration.compactThreshold = threshold }
if let keep = options.keepRecent { configuration.compactKeepRecentTurns = keep }

let seats = zip(specs, engines).map { spec, mlx in
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
let engine = ConversationEngine(seats: seats, configuration: engineConfiguration)

// Source material, read the same way the app reads it.
if !options.attachments.isEmpty {
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

// Render the log as it grows, printing each entry once.
var printedTurnIDs = Set<UUID>()

let transcriptTask = Task {
    for await turns in engine.transcriptUpdates {
        for turn in turns where !printedTurnIDs.contains(turn.id) {
            printedTurnIDs.insert(turn.id)
            guard turn.kind != .tool else { continue }
            let label: String
            switch turn.kind {
            case .topic: label = "MODERATOR · TOPIC"
            case .introduction: label = "SETUP"
            case .steering: label = "MODERATOR"
            case .tool: label = "TOOL"
            case .summary: label = "CONDENSED EARLIER DISCUSSION"
            case .report: label = "RESEARCH MODERATOR — FINAL REPORT"
            case .chat: label = turn.speakerName.uppercased()
            }
            header(label)
            print(turn.content)
        }
    }
}

// Stream progress so a long turn does not look hung.
let activityTask = Task {
    for await event in engine.events {
        switch event {
        case .toolCall(let agentID, let name, let query):
            log("  [\(agentID)] → \(name)(\(UTF8Text.prefix(query, 70)))")
        case .toolResult(let agentID, let name, let summary, _):
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

let noticeTask = Task {
    for await notices in engine.noticeUpdates {
        if let last = notices.last {
            log("  note: \(last)")
        }
    }
}

let statusTask = Task {
    for await status in engine.statusUpdates {
        if case .running(let turn) = status {
            log("turn \(turn)…")
        } else if case .failed(let message) = status {
            log("failed: \(message)")
        }
    }
}

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
log("done — \(engine.conversation.turns.filter { $0.kind == .chat }.count) messages exchanged")
for notice in engine.notices {
    log("  note: \(notice)")
}
