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
    var tavilyKey: String?
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
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func next() -> String? {
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }
            // One shape for every bad-argument message. It used to be built inline at each site,
            // which meant ten copies of the same sentence — six of them long enough to trip the
            // line-length gate. The lead is passed in because two sites
            // ("unknown …") are not "invalid …".
            func reject(_ lead: String, _ value: String, expected: String) -> Never {
                let shown = value.isEmpty ? "(nothing)" : value
                FileHandle.standardError.write(Data("\(lead): \(shown) — expected \(expected)\n".utf8))
                exit(2)
            }
            // Shared so the two backend flags cannot drift apart, and so the accepted values are
            // read from the enum rather than repeated in the message.
            func backend(_ raw: String?, flag: String) -> AgentSpec.Backend {
                let value = raw ?? ""
                guard let parsed = AgentSpec.Backend(rawValue: value) else {
                    let accepted = AgentSpec.Backend.allCases.map(\.rawValue).joined(separator: " or ")
                    reject("unknown backend for \(flag)", value, expected: accepted)
                }
                return parsed
            }
            switch argument {
            case "--topic", "-t": options.topic = next() ?? options.topic
            case "--turns", "-n":
                // `if let Int(...)` with no else meant `--turns abc` and `--turns 0` quietly kept
                // the default of 4, so the run was not the one that had been asked for.
                let turnsRaw = next() ?? ""
                guard let value = Int(turnsRaw), value >= 1 else {
                    reject("invalid turn count", turnsRaw, expected: "1 or more")
                }
                options.turns = value
                options.turnsSpecified = true
            // A catalogue alias or a repository id. Resolution happens here so everything downstream
            // — the spec, the log, the seat — sees the id that will actually be loaded, and a
            // mistyped alias is passed through as the id it looks like rather than being refused,
            // because any repository id is a legitimate value (ModelCatalog).
            case "--model-a": options.modelA = ModelCatalog.resolve(next() ?? options.modelA)
            case "--model-b": options.modelB = ModelCatalog.resolve(next() ?? options.modelB)
            case "--key": options.tavilyKey = next()
            case "--max-tokens":
                // The same silent-default class: a nil from `Int(...)` left the seat's own budget in
                // place without saying so.
                let tokensRaw = next() ?? ""
                guard let value = Int(tokensRaw), value >= 1 else {
                    reject("invalid max tokens", tokensRaw, expected: "1 or more")
                }
                options.maxTokens = value
            case "--backend-a": options.backendA = backend(next(), flag: "--backend-a")
            case "--backend-b": options.backendB = backend(next(), flag: "--backend-b")
            case "--base-url": options.baseURL = next() ?? options.baseURL
            case "--api-model": options.apiModel = next() ?? options.apiModel
            case "--api-key": options.apiKey = next()
            case "--persona-a": options.personaA = next()
            case "--persona-b": options.personaB = next()
            case "--list-models":
                Listings.printModels()
                exit(0)
            case "--list-personas":
                Listings.printPersonas()
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
            case "--check-transport": options.checkTransport = true
            case "--check-client": options.checkClient = true
            case "--prepare-identity": options.prepareIdentity = true
            case "--transport":
                // Unvalidated, so `--transport webtransprot` served HTTP only while the value was
                // never mentioned again, and the app then could not connect.
                let transportRaw = next() ?? ""
                guard ["webtransport", "http", "both"].contains(transportRaw) else {
                    reject("unknown transport", transportRaw, expected: "webtransport, http or both")
                }
                options.transport = transportRaw
                options.transportSpecified = true
            case "--transport-port":
                // Validated rather than swallowed: `UInt16(String)` returns nil for an
                // out-of-range value, so this used to fall back silently to 7790 and the
                // user's number was never mentioned again.
                let transportRaw = next() ?? ""
                guard let value = UInt16(transportRaw), value != 0 else {
                    reject("invalid transport port", transportRaw, expected: "1–65535")
                }
                options.transportPort = value
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
            case "--port":
                // `Int` here and a trapping `UInt16` at the listener meant `--port -1` or
                // `--port 70000` aborted the process instead of exiting 2 like every other
                // bad value. Zero is refused as well: the server would bind an ephemeral
                // port and then announce `http://127.0.0.1:0`, a URL that goes nowhere.
                let portRaw = next() ?? ""
                guard let value = UInt16(portRaw), value != 0 else {
                    reject("invalid port", portRaw, expected: "1–65535")
                }
                options.port = value
            case "--share-base":
                // Where a share link should point. The engine can only know its own loopback port,
                // and the phone the share feature exists for needs the address the website is
                // published on — which only the deployment knows. Validated rather than
                // accepted blindly, because a base that is not a URL produces links that go
                // nowhere.
                let baseRaw = next() ?? ""
                guard let url = URL(string: baseRaw), url.scheme != nil, url.host != nil else {
                    reject("invalid share base", baseRaw, expected: "a URL like http://192.168.1.5:7788")
                }
                options.shareBase = baseRaw
            case "--compact-threshold":
                // A nil here left the engine's own 0.7 in place, silently. The value is a
                // fraction of the context window, so anything outside (0, 1] is not a threshold.
                let thresholdRaw = next() ?? ""
                guard let value = Double(thresholdRaw), value > 0, value <= 1 else {
                    reject(
                        "invalid compact threshold", thresholdRaw,
                        expected: "a fraction above 0 and at most 1")
                }
                options.compactThreshold = value
            case "--context-window":
                // Zero and negatives already meant "unset" to `generationCap`, so a window could be
                // set and silently ignored by the engine.
                let windowRaw = next() ?? ""
                guard let value = Int(windowRaw), value >= 1 else {
                    reject("invalid context window", windowRaw, expected: "1 or more tokens")
                }
                options.contextWindow = value
            case "--compact-keep":
                // A negative value traps inside `dropLast`, which is the worst way to learn about
                // it; zero is meaningful — keep no recent turns — so it is allowed.
                let keepRaw = next() ?? ""
                guard let value = Int(keepRaw), value >= 0 else {
                    reject("invalid compact keep", keepRaw, expected: "0 or more turns")
                }
                options.keepRecent = value
            case "--run-directory":
                // Where this run's certificate and conversations live. The default is right for
                // one engine on one machine; a second engine — a test one, or the one
                // `TransportCheck` starts — needs its own, and the child it spawns has to be told
                // the same path or the two disagree about the identity. A relative path is
                // resolved against the working directory here, so the answer does not depend on
                // where the child ends up running.
                let runRaw = next() ?? ""
                guard !runRaw.isEmpty else {
                    reject("invalid run directory", runRaw, expected: "a path")
                }
                options.runDirectory = URL(fileURLWithPath: runRaw)
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
        // `--transport` only means something to `--serve`. Every other mode builds its own engine
        // and opens no listener, so the flag was accepted and ignored — refused here rather
        // than left to look as though it had been applied.
        if options.transportSpecified, !options.serve {
            FileHandle.standardError.write(
                Data("--transport only applies with --serve; without it the flag does nothing\n".utf8))
            exit(2)
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
              --list-models        Print the checkpoints this app offers and exit
                                   (--model-a also takes any Hugging Face repository id)
              --key <key>          Tavily API key (else env TAVILY_API_KEY or .secrets.env)
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
