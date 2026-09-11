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

// MARK: - Arguments

struct Options {
    var topic = "Why are eggs not round?"
    var turns = 4
    var modelA = AgentSpec.defaultModelID
    var modelB = AgentSpec.defaultModelID
    var tavilyKey: String?
    var benchmark = false
    var solo = false
    /// Cap on visible answer tokens per turn; `nil` keeps every seat's own budget.
    var maxTokens: Int?

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
            case "--benchmark": options.benchmark = true
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
              --benchmark          Measure seat throughput instead of chatting
              --solo               With --benchmark: measure seat A only, then exit

        Seat A and seat B are separate model instances with independent sampling
        parameters, so a headless run exercises exactly the same path as the GUI.
        """

    private func capped(_ spec: AgentSpec) -> AgentSpec {
        guard let maxTokens else { return spec }
        var spec = spec
        spec.maxTokens = maxTokens
        // A cap is only a cap if the thinking block is not given its own headroom,
        // otherwise the seat may still emit budget + 2048 tokens per turn.
        spec.thinkingBudget = 0
        return spec
    }

    var specA: AgentSpec { capped(AgentSpec.seatA(modelID: modelA)) }
    var specB: AgentSpec { capped(AgentSpec.seatB(modelID: modelB)) }
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

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

if let key = options.tavilyKey {
    setenv("TAVILY_API_KEY", key, 1)
}

let specs = [options.specA, options.specB]

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

// MARK: - Conversation

log("ChatBots headless run")
log("  topic     : \(options.topic)")
log("  turns     : \(options.turns)")
log("  seat A    : \(options.modelA)")
log("  seat B    : \(options.modelB)")
log("  tavily    : \(TavilyClient.isConfigured ? "configured" : "MISSING")")
print("")

var configuration = ConversationEngine.Configuration()
configuration.pace = .zero
configuration.maxTurns = max(1, options.turns)

let seats = zip(specs, engines).map { ConversationEngine.Seat(spec: $0, engine: $1) }
let engine = ConversationEngine(seats: seats, configuration: configuration)

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
            log("  [\(agentID)] → \(name)(\(query.prefix(70)))")
        case .toolResult(let agentID, let name, let summary, _):
            log("  [\(agentID)] ← \(name): \(summary)")
        case .toolFailure(let agentID, let name, let message):
            log("  [\(agentID)] ✗ \(name): \(message)")
        case .turnFinished(let agentID, _, let stats):
            log(
                "  [\(agentID)] \(stats.generationTokens) tok in "
                    + "\(String(format: "%.1f", stats.seconds))s "
                    + "(\(String(format: "%.1f", stats.tokensPerSecond)) tok/s, "
                    + "stop=\(stats.stopReason))")
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
