// ChatBotsCLI — the `--serve` mode
//
// The same engine the printed run uses, behind HTTP and WebTransport instead of stdout. Both front
// ends — the web page and the SwiftUI app — talk to this, so there is one conversation engine and
// one place where a conversation actually lives. Split out of `main.swift`, which held the entry
// point, the command line and every mode in one 1132-line file.

import ChatBotsCore
import Dispatch
import Foundation

@MainActor
enum ServeCommand {

    static func run(context: RunContext) async {
        let options = context.options
        let engine = makeEngine(context: context)
        attachDocuments(options: options, engine: engine)
        if !options.topic.isEmpty { _ = engine.setTopic(options.topic) }
        // A sample conversation, for laying out the interface without waiting for a model.
        if options.seed { engine.seed(SampleConversation.turns(topic: engine.topic)) }

        // Documents are read by `SystemDocumentExtractor`, from `ChatBotsCore`: the core keeps
        // extraction behind an installed provider, and this process is what installs one, so the
        // server it starts can accept uploads. (This used to say the extractors were the app's and
        // lived in the app target; the CLI does not link the app target, and no extractor is
        // defined there.)
        DocumentIngestorProvider.install(SystemDocumentExtractor.ingestor)

        // Runtime state — the certificate, and the conversations this engine keeps — is the one
        // directory this run resolved at startup: `--run-directory` when it was given, otherwise
        // what `RunDirectory` answers for this process. Never the working directory, so an engine
        // started from inside `ChatBots.app` does not write its state into its own bundle.
        //
        // The `APIServer` owns the one `EngineService` that both transports dispatch through, so
        // it is always built. Only its HTTP listener is optional.
        let server = APIServer(
            engine: engine, store: ConversationStore(directory: context.runDirectory),
            port: options.port, shareBase: options.shareBase)

        await startHTTP(server: server, options: options)
        let transportServer = await startWebTransport(
            server: server, context: context, options: options)

        log("  models  : \(context.specs.map(\.backendLabel).joined(separator: ", "))")
        log("Press Control-C to stop.")

        let (shutdownSignals, signalSources) = installSignalHandlers()
        _ = signalSources

        // Keep the process alive until a signal arrives; the HTTP listener runs on its own queue.
        for await number in shutdownSignals {
            log("received signal \(number) — stopping")
            break
        }
        await transportServer?.stop()
        server.stop()
        exit(0)
    }

    /// The engine `--serve` runs, wired the same way the headless run wires its own.
    private static func makeEngine(context: RunContext) -> ConversationEngine {
        let options = context.options
        // This engine is the same engine the headless run uses, so the tuning flags have to reach
        // it too. The configuration was built from defaults and only `--research` was applied, so
        // `--serve --turns 100`, `--compact-threshold` and `--compact-keep` were accepted and
        // ignored. `--turns` is applied only when it was actually given, so `--serve` on its own
        // keeps the engine's own default rather than the CLI's 4.
        var engineConfiguration = ConversationEngine.Configuration()
        // A front end can point a seat at another checkpoint while this engine is serving, which
        // builds a new MLX engine for it. That engine has to carry the same wiring as the seats
        // built below — the tool registry, and the progress line this run's stdout is for.
        engineConfiguration.makeMLXEngine = { spec in
            MLXEngine(spec: spec, toolRegistry: context.registry) { state in
                if case .loading(let progress) = state, progress > 0, progress < 1 {
                    let percent = Int(progress * 100)
                    if percent % 25 == 0 { log("  \(spec.id): downloading \(percent)%") }
                }
            }
        }
        if options.turnsSpecified { engineConfiguration.maxTurns = max(1, options.turns) }
        if let threshold = options.compactThreshold { engineConfiguration.compactThreshold = threshold }
        if let keep = options.keepRecent { engineConfiguration.compactKeepRecentTurns = keep }
        if let depth = options.researchDepth {
            engineConfiguration.researchBudget = ResearchBudget.preset(depth)
        }
        let seats = zip(context.specs, context.engines).map { spec, mlx in
            ConversationEngine.Seat(spec: spec, mlx: mlx, openAI: OpenAIResponsesEngine(spec: spec))
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

    /// Open the HTTP listener only when the requested transport includes it.
    ///
    /// It used to be opened unconditionally, so `--serve --transport webtransport` — the exact
    /// command the app's supervisor runs — also bound port 7788. 7788 is the port the documented
    /// website deployment publishes through Caddy, so with the website running, the app's engine
    /// died on a collision that had nothing to do with the transport it was asked for.
    private static func startHTTP(server: APIServer, options: Options) async {
        let servesHTTP = options.transport == "http" || options.transport == "both"
        if servesHTTP {
            do {
                try server.start()
            } catch {
                FileHandle.standardError.write(
                    Data("could not start the server on port \(options.port): \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            // `start()` returning only means the listener was created. A port already in use is
            // reported asynchronously, so without this the server would announce itself as
            // listening and then serve nothing — the same false green the transport check used to
            // have.
            guard await server.waitUntilReady() else {
                FileHandle.standardError.write(
                    Data("could not listen on port \(options.port): the port is already in use\n".utf8))
                exit(1)
            }

            log("ChatBots server listening on http://127.0.0.1:\(options.port)")
            log("  state   : GET  /api/state")
            log("  events  : GET  /api/events  (server-sent events)")
            log("  control : POST /api/start | /api/pause | /api/resume | /api/stop | /api/reset")
        } else {
            log("  http    : not served (--transport \(options.transport))")
        }
    }

    /// Start the WebTransport endpoint, for the desktop app. Caddy and the website keep using
    /// HTTP: browsers speak that, and it is what Caddy is for.
    private static func startWebTransport(
        server: APIServer, context: RunContext, options: Options
    ) async -> WebTransportEngineServer? {
        guard options.transport == "webtransport" || options.transport == "both" else {
            log("  app     : not served (--transport \(options.transport))")
            return nil
        }
        do {
            let identity = try CertificateStore.loadOrCreate(in: context.runDirectory)
            var configuration = WebTransportEngineServer.Configuration()
            configuration.port = options.transportPort
            let transport = WebTransportEngineServer(
                service: server.engineService, identity: identity, configuration: configuration)
            try await transport.start()
            log("  app     : webtransport://127.0.0.1:\(options.transportPort)")
            log("  cert    : \(identity.fingerprintDisplay)")
            return transport
        } catch {
            // Not fatal: the website works without it, and saying so is better than refusing to
            // start at all.
            log("  app     : WebTransport unavailable — \(error.localizedDescription)")
            return nil
        }
    }

    /// Stop on SIGINT or SIGTERM instead of being killed: `WebTransportEngineServer.stop()` and
    /// the HTTP server's teardown have to run so the listener releases its port and the logs are
    /// flushed, and the installer's lifecycle and `tools/start.sh --stop` both depend on that
    /// being predictable.
    private static func installSignalHandlers() -> (AsyncStream<Int32>, [DispatchSourceSignal]) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let (shutdownSignals, shutdownContinuation) = AsyncStream<Int32>.makeStream()
        // Held for the life of the process: a signal source that is released stops delivering.
        var signalSources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM] {
            // `.main`, not `.global`: top-level code in a Swift 6 `main.swift` is main-actor
            // isolated, and the event handler inherits that isolation. Dispatching it to a global
            // queue tripped the runtime's actor-isolation assertion (SIGTRAP) instead of shutting
            // anything down. The main queue is the main actor's executor, so the handler is
            // invoked where its isolation says it should be.
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { shutdownContinuation.yield(number) }
            source.resume()
            signalSources.append(source)
        }
        return (shutdownSignals, signalSources)
    }
}
