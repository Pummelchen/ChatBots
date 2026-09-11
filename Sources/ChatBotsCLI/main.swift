// chatbots-cli — drive the two-seat conversation without the GUI
//
// Used both as a smoke test for the real MLX engines and as a way to run the
// conversation from a terminal. It consumes exactly the same core types the app does.

import ChatBotsCore
import Foundation

// MARK: - Arguments

struct Options {
    var topic = "Why are eggs not round?"
    var turns = 4
    var modelA = AgentSpec.defaultModelID
    var modelB = AgentSpec.defaultModelID
    var showReasoning = true
    var headless = true
    var tavilyKey: String?

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
            case "--no-thinking": options.showReasoning = false
            case "--key": options.tavilyKey = next()
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
          -t, --topic <text>     Topic to discuss (default: "Why are eggs not round?")
          -n, --turns <count>    Number of LLM turns to run (default: 4)
              --model-a <id>     MLX checkpoint for seat A (default: \(AgentSpec.defaultModelID))
              --model-b <id>     MLX checkpoint for seat B
              --no-thinking      Suppress <think> output in the log
              --key <key>        Tavily API key (default: TAVILY_API_KEY or the built-in dev key)

        Seat A and seat B are separate model instances with independent sampling
        parameters, so a headless run exercises exactly the same path as the GUI.
        """
}

// MARK: - Output helpers

let stderr = FileHandle.standardError

func log(_ message: String) {
    stderr.write(Data((message + "\n").utf8))
}

func blank() {
    print("")
}

func printHeader(_ turn: Turn, showReasoning: Bool) {
    let label: String
    switch turn.kind {
    case .topic: label = "MODERATOR · TOPIC"
    case .introduction: label = "SETUP"
    case .steering: label = "MODERATOR"
    case .tool: label = "TOOL"
    case .chat: label = turn.speakerName.uppercased()
    }
    blank()
    print(String(repeating: "─", count: 78))
    print(label)
    print(String(repeating: "─", count: 78))
}

// MARK: - Run

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

if let key = options.tavilyKey {
    setenv("TAVILY_API_KEY", key, 1)
}

log("ChatBots headless run")
log("  topic     : \(options.topic)")
log("  turns     : \(options.turns)")
log("  seat A    : \(options.modelA)")
log("  seat B    : \(options.modelB)")
log("  tavily    : \(TavilyClient.isConfigured ? "configured" : "MISSING")")
blank()

let configuration = {
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = max(1, options.turns)
    return configuration
}()

let specs = [
    AgentSpec.seatA(modelID: options.modelA),
    AgentSpec.seatB(modelID: options.modelB),
]

// The CLI owns its own engines so it can route events straight to stdout.
let registry = WebToolbox.makeRegistry()
let engines = specs.map { spec in
    MLXEngine(spec: spec, toolRegistry: registry) { state in
        if case .loading(let progress) = state, progress > 0, progress < 1 {
            // Progress lines are noisy in a terminal; only announce the milestones.
            let percent = Int(progress * 100)
            if percent % 25 == 0 { log("  \(spec.id): downloading \(percent)%") }
        }
    }
}

let seats = zip(specs, engines).map { ConversationEngine.Seat(spec: $0, engine: $1) }
let engine = ConversationEngine(seats: seats, configuration: configuration)

// Render the log as it grows, and print each completed message once.
var printedTurnIDs = Set<UUID>()

let transcriptTask = Task {
    for await turns in engine.transcriptUpdates {
        for turn in turns where !printedTurnIDs.contains(turn.id) {
            // Skip the introduction until the log is otherwise empty-friendly; print
            // everything the human would see, in order.
            if turn.kind == .tool {
                printedTurnIDs.insert(turn.id)
                continue
            }
            printedTurnIDs.insert(turn.id)
            printHeader(turn, showReasoning: options.showReasoning)
            print(turn.content)
        }
    }
}

// Stream reasoning/token progress so a long turn does not look hung.
let activityTask = Task {
    for await event in engine.events {
        switch event {
        case .toolCall(let agentID, let name, let query):
            log("  [\(agentID)] → \(name)(\(query.prefix(70)))")
        case .token, .reasoning:
            // Token-level chatter would drown the log; the progress lines above are
            // what a headless run is for.
            break
        case .toolResult(let agentID, let name, let summary, _):
            log("  [\(agentID)] ← \(name): \(summary)")
        case .toolFailure(let agentID, let name, let message):
            log("  [\(agentID)] ✗ \(name): \(message)")
        case .turnFinished(let agentID, _, let stats):
            log(
                "  [\(agentID)] \(stats.generationTokens) tok in \(String(format: "%.1f", stats.seconds))s "
                    + "(\(String(format: "%.1f", stats.tokensPerSecond)) tok/s, stop=\(stats.stopReason))")
        default:
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

// Wait for the loop to finish on its own (turn limit, stop or failure).
while engine.status.isActive {
    try? await Task.sleep(for: .milliseconds(250))
}

// Let the last transcript update land before tearing the streams down.
try? await Task.sleep(for: .milliseconds(300))

transcriptTask.cancel()
activityTask.cancel()
noticeTask.cancel()
statusTask.cancel()

blank()
print(String(repeating: "─", count: 78))
log("done — \(engine.conversation.turns.filter { $0.kind == .chat }.count) messages exchanged")
for notice in engine.notices {
    log("  note: \(notice)")
}
