// ChatBotsCLI — the flags, and the one place they are read
//
// Split out of `main.swift`, which held the entry point, the command line and every mode in one
// 1132-line file. `Options` is the whole of the command line: the defaults, the parser and the
// `--help` text it prints. Each flag is checked exactly where it was checked before.

import ChatBotsCore
import Foundation

// MARK: - Arguments

struct Options {
    var topic = "Why are eggs not round?"
    var turns = 4
    /// Whether `--turns` was actually given. `--serve` builds its own engine configuration
    /// and must apply the flag when present without overriding the engine's own default when
    /// it is not.
    var turnsSpecified = false
    var modelA = AgentSpec.defaultModelID
    var modelB = AgentSpec.defaultModelID
    var benchmark = false
    var solo = false
    var memoryProbe = false
    var sessionProbe = false
    var compactThreshold: Double?
    var exportSample = false
    var check = false
    var checkTransport = false
    var checkClient = false
    var prepareIdentity = false
    /// webtransport, http, or both. Both by default, so the website and the app can each be
    /// run against the same engine while the app is being moved onto the new channel.
    var transport = "both"
    /// Whether `--transport` was actually given, so a value that cannot take effect is refused
    /// rather than silently accepted.
    var transportSpecified = false
    /// Whether `--port` was actually given, so a value no listener will use is refused rather than
    /// silently accepted.
    var portSpecified = false
    /// Whether `--share-base` was actually given, for the same reason.
    var shareBaseSpecified = false
    var transportPort: UInt16 = 7790
    var serve = false
    var mode = DiscussionMode.entertainment
    var listCharacters = false
    var attachments: [String] = []
    var seed = false
    var researchDepth: ResearchBudget.Depth?
    var listRoles = false
    /// The HTTP port. `UInt16` rather than `Int`, so an out-of-range value cannot reach the
    /// listener through a second, trapping conversion.
    var port: UInt16 = 7788
    /// Where a share link should point, when this engine is published behind a proxy. Nil keeps
    /// the engine's own loopback address.
    var shareBase: String?
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
    /// The model an OpenAI-compatible server is assumed to be serving, which is the checkpoint this
    /// project ships and the installer downloads — named here rather than copied.
    var apiModel = AgentSpec.defaultModelID
    var apiKey: String?
    /// Where the certificate and the conversations live, when it is not the default. Nil means
    /// `RunDirectory.current`: the project's `.run` in a checkout, Application Support otherwise.
    var runDirectory: URL?

    static func parse(_ arguments: [String]) -> Options {
        OptionParser.parse(arguments)
    }

    /// A flag that only means something to another mode is refused rather than accepted and
    /// ignored: `--transport`, `--port` and `--share-base` describe the listener only `--serve`
    /// opens, and `--solo` describes the benchmark.
    fileprivate func rejectInapplicableFlags() {
        if transportSpecified, !serve {
            FileHandle.standardError.write(
                Data("--transport only applies with --serve; without it the flag does nothing\n".utf8))
            exit(2)
        }
        if portSpecified, !serve {
            FileHandle.standardError.write(
                Data("--port only applies with --serve; without it the flag does nothing\n".utf8))
            exit(2)
        }
        if shareBaseSpecified, !serve {
            FileHandle.standardError.write(
                Data("--share-base only applies with --serve; without it the flag does nothing\n".utf8))
            exit(2)
        }
        if solo, !benchmark {
            FileHandle.standardError.write(
                Data("--solo only applies with --benchmark; without it the flag does nothing\n".utf8))
            exit(2)
        }
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
              --list-models        Print the checkpoints this app offers and exit
                                   (--model-a also takes any Hugging Face repository id)
              --key is refused      Set TAVILY_API_KEY or add the key to .secrets.env instead
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
              --run-directory <path>   Where the certificate and conversations live
                                       (default: .run in a checkout)

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

    /// Apply this run's settings to every seat, including the third and fourth.
    ///
    /// Found by running a four-seat conversation: `--max-tokens 30` reached seats 1 and 2,
    /// because they are built through `configured` above, while seats 3 and 4 came from
    /// `makeSeats` and kept their defaults. The log showed `maxOut=30` for two seats and a
    /// 636-token turn from a fourth. Any per-run setting has to reach all of them or a
    /// four-seat run is not testing what the flags say it is.
    func applyToAllSeats(_ seats: [AgentSpec]) -> [AgentSpec] {
        seats.map { spec in
            configured(
                spec,
                persona: nil,
                // Only the first two have a per-seat backend choice on the command line.
                backend: spec.backend)
        }
    }

    var specA: AgentSpec {
        configured(AgentSpec.seatA(modelID: modelA), persona: personaA, backend: backendA)
    }
    var specB: AgentSpec {
        configured(AgentSpec.seatB(modelID: modelB), persona: personaB, backend: backendB)
    }
}

// MARK: - Reading the command line

/// One pass over the arguments. `next()` moves to the value that follows a flag; `advance()`
/// moves past the argument just handled — the trailing `index += 1` the old loop did for every
/// flag, with or without a value.
private struct ArgumentReader {
    private let arguments: [String]
    private var index = 0

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    var isFinished: Bool { index >= arguments.count }

    var current: String { arguments[index] }

    mutating func next() -> String? {
        index += 1
        return index < arguments.count ? arguments[index] : nil
    }

    mutating func advance() {
        index += 1
    }
}

/// The command line, mid-parse: the arguments left to read and the options they have set. The
/// flags are handled in groups small enough to read on their own; every flag, check and message
/// is the one the single 189-line `parse` switch carried, so nothing here changes what a flag
/// does.
private final class OptionParser {
    private var reader: ArgumentReader
    private(set) var options = Options()

    init(_ arguments: [String]) {
        reader = ArgumentReader(arguments)
    }

    static func parse(_ arguments: [String]) -> Options {
        let parser = OptionParser(arguments)
        let groups: [(String) -> Bool] = [
            parser.topicAndModels,
            parser.backends,
            parser.limits,
            parser.listings,
            parser.runToggles,
            parser.displayToggles,
            parser.server,
            parser.research,
            parser.compaction,
        ]
        while !parser.reader.isFinished {
            let argument = parser.reader.current
            let handled = groups.contains { $0(argument) }
            guard handled else {
                FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
                print(Options.usage)
                exit(2)
            }
            parser.reader.advance()
        }
        parser.options.rejectInapplicableFlags()
        return parser.options
    }

    /// One shape for every bad-argument message, built in one place instead of ten.
    private func reject(_ lead: String, _ value: String, expected: String) -> Never {
        let shown = value.isEmpty ? "(nothing)" : value
        FileHandle.standardError.write(Data("\(lead): \(shown) — expected \(expected)\n".utf8))
        exit(2)
    }

    /// Shared so the two backend flags cannot drift apart, and so the accepted values are read
    /// from the enum rather than repeated in the message.
    private func backend(_ raw: String?, flag: String) -> AgentSpec.Backend {
        let value = raw ?? ""
        guard let parsed = AgentSpec.Backend(rawValue: value) else {
            let accepted = AgentSpec.Backend.allCases.map(\.rawValue).joined(separator: " or ")
            reject("unknown backend for \(flag)", value, expected: accepted)
        }
        return parsed
    }

    private func topicAndModels(_ argument: String) -> Bool {
        switch argument {
        case "--topic", "-t": options.topic = reader.next() ?? options.topic
        // A catalogue alias or a repository id; resolution happens here so every downstream
        // reader sees the id that will actually be loaded (ModelCatalog).
        case "--model-a": options.modelA = ModelCatalog.resolve(reader.next() ?? options.modelA)
        case "--model-b": options.modelB = ModelCatalog.resolve(reader.next() ?? options.modelB)
        case "--turns", "-n":
            // `--turns abc` and `--turns 0` used to keep the default of 4 silently.
            let turnsRaw = reader.next() ?? ""
            guard let value = Int(turnsRaw), value >= 1 else {
                reject("invalid turn count", turnsRaw, expected: "1 or more")
            }
            options.turns = value
            options.turnsSpecified = true
        default: return false
        }
        return true
    }

    private func backends(_ argument: String) -> Bool {
        switch argument {
        case "--backend-a": options.backendA = backend(reader.next(), flag: "--backend-a")
        case "--backend-b": options.backendB = backend(reader.next(), flag: "--backend-b")
        case "--base-url": options.baseURL = reader.next() ?? options.baseURL
        case "--api-model": options.apiModel = reader.next() ?? options.apiModel
        case "--api-key": options.apiKey = reader.next()
        case "--persona-a": options.personaA = reader.next()
        case "--persona-b": options.personaB = reader.next()
        default: return false
        }
        return true
    }

    private func limits(_ argument: String) -> Bool {
        switch argument {
        case "--max-tokens":
            // A nil from `Int(...)` left the seat's own budget in place without saying so.
            let tokensRaw = reader.next() ?? ""
            guard let value = Int(tokensRaw), value >= 1 else {
                reject("invalid max tokens", tokensRaw, expected: "1 or more")
            }
            options.maxTokens = value
        case "--thinking":
            let raw = reader.next() ?? ""
            guard let mode = ThinkingMode(rawValue: raw.lowercased()) else {
                FileHandle.standardError.write(Data("unknown thinking mode: \(raw)\n".utf8))
                exit(2)
            }
            options.thinking = mode
        default: return false
        }
        return true
    }

    private func listings(_ argument: String) -> Bool {
        switch argument {
        case "--list-models":
            Listings.printModels()
            exit(0)
        case "--list-personas":
            Listings.printPersonas()
            exit(0)
        case "--key":
            // Refused rather than accepted: a value here is readable through `ps` and kept in
            // the shell history, so it is not a way to supply a secret.
            FileHandle.standardError.write(
                Data(
                    ("""
                    --key is refused: the value would be visible to every process on this \
                    machine and recorded in your shell history. Set TAVILY_API_KEY in the \
                    environment, or put it in .secrets.env at the project root.
                    """ + "\n").utf8))
            exit(2)
        case "--help", "-h":
            print(Options.usage)
            exit(0)
        default: return false
        }
        return true
    }

    private func runToggles(_ argument: String) -> Bool {
        switch argument {
        case "--benchmark": options.benchmark = true
        case "--memory-probe": options.memoryProbe = true
        case "--session-probe": options.sessionProbe = true
        case "--export-sample": options.exportSample = true
        case "--check": options.check = true
        case "--check-transport": options.checkTransport = true
        case "--check-client": options.checkClient = true
        case "--prepare-identity": options.prepareIdentity = true
        default: return false
        }
        return true
    }

    private func displayToggles(_ argument: String) -> Bool {
        switch argument {
        case "--serve": options.serve = true
        case "--seed": options.seed = true
        case "--list-characters": options.listCharacters = true
        case "--list-roles": options.listRoles = true
        case "--solo": options.solo = true
        default: return false
        }
        return true
    }

    private func server(_ argument: String) -> Bool {
        switch argument {
        case "--transport":
            // Unvalidated, so `--transport webtransprot` served HTTP only and the app could
            // not connect.
            let transportRaw = reader.next() ?? ""
            guard ["webtransport", "http", "both"].contains(transportRaw) else {
                reject("unknown transport", transportRaw, expected: "webtransport, http or both")
            }
            options.transport = transportRaw
            options.transportSpecified = true
        case "--transport-port":
            // `UInt16(String)` is nil out of range, so this used to fall back silently to 7790.
            let transportRaw = reader.next() ?? ""
            guard let value = UInt16(transportRaw), value != 0 else {
                reject("invalid transport port", transportRaw, expected: "1–65535")
            }
            options.transportPort = value
        case "--port":
            // A trapping `UInt16` at the listener aborted the process for `--port -1` or
            // `--port 70000`; zero would announce a URL that goes nowhere.
            let portRaw = reader.next() ?? ""
            guard let value = UInt16(portRaw), value != 0 else {
                reject("invalid port", portRaw, expected: "1–65535")
            }
            options.port = value
            options.portSpecified = true
        case "--share-base":
            // Only the deployment knows the address the website is published on; a base that is
            // not a URL produces links that go nowhere.
            let baseRaw = reader.next() ?? ""
            guard let url = URL(string: baseRaw), url.scheme != nil, url.host != nil else {
                reject("invalid share base", baseRaw, expected: "a URL like http://192.168.1.5:7788")
            }
            options.shareBase = baseRaw
            options.shareBaseSpecified = true
        default: return false
        }
        return true
    }

    private func research(_ argument: String) -> Bool {
        switch argument {
        case "--research":
            let raw = reader.next() ?? ""
            if let depth = ResearchBudget.Depth(rawValue: raw) {
                options.researchDepth = depth
                options.mode = .research
            } else {
                FileHandle.standardError.write(
                    Data("unknown research budget: \(raw) — try quick, standard or deep\n".utf8))
                exit(2)
            }
        case "--mode":
            let raw = reader.next() ?? ""
            if let parsed = DiscussionMode(rawValue: raw) {
                options.mode = parsed
            } else {
                FileHandle.standardError.write(
                    Data("unknown mode: \(raw) — try entertainment or research\n".utf8))
                exit(2)
            }
        case "--attach":
            // A missing value used to append an empty path, or take the next flag as the path.
            let attachRaw = reader.next() ?? ""
            guard !attachRaw.isEmpty, !attachRaw.hasPrefix("--") else {
                reject("invalid attachment path", attachRaw, expected: "a file path")
            }
            options.attachments.append(attachRaw)
        default: return false
        }
        return true
    }

    private func compaction(_ argument: String) -> Bool {
        switch argument {
        case "--compact-threshold":
            // A nil here left the engine's own 0.7 in place, silently.
            let thresholdRaw = reader.next() ?? ""
            guard let value = Double(thresholdRaw), value > 0, value <= 1 else {
                reject(
                    "invalid compact threshold", thresholdRaw,
                    expected: "a fraction above 0 and at most 1")
            }
            options.compactThreshold = value
        case "--context-window":
            // Zero and negatives already meant "unset" to `generationCap`.
            let windowRaw = reader.next() ?? ""
            guard let value = Int(windowRaw), value >= 1 else {
                reject("invalid context window", windowRaw, expected: "1 or more tokens")
            }
            options.contextWindow = value
        case "--compact-keep":
            // A negative value traps inside `dropLast`; zero is meaningful, so it is allowed.
            let keepRaw = reader.next() ?? ""
            guard let value = Int(keepRaw), value >= 0 else {
                reject("invalid compact keep", keepRaw, expected: "0 or more turns")
            }
            options.keepRecent = value
        case "--run-directory":
            // A second engine — a test one, or the one `TransportCheck` starts — needs its own
            // state directory, and a relative path is resolved here so the child it spawns can
            // be told the same, working-directory-independent path.
            let runRaw = reader.next() ?? ""
            guard !runRaw.isEmpty else {
                reject("invalid run directory", runRaw, expected: "a path")
            }
            options.runDirectory = URL(fileURLWithPath: runRaw)
        default: return false
        }
        return true
    }
}
