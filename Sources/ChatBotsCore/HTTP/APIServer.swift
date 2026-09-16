// ChatBotsCore — the HTTP API in front of the conversation engine
//
// This is the piece that makes "one engine, two front ends" real. The SwiftUI app and the
// web page are both clients of this; neither of them owns the conversation. The engine is
// `@MainActor`, and requests are handled on the main actor, so every route sees a
// single-threaded engine while the network side stays concurrent — no locks around the
// conversation, and no way for two requests to interleave inside a turn.
//
// The routes are deliberately narrow and mirror what the interface can do, rather than
// exposing the engine wholesale. A front end is expected to read the whole state and render
// it; the events feed exists so it does not have to poll while a model is talking.

import Foundation

/// A snapshot of everything a front end needs to draw the current state.
///
/// Sent whole, and sent again after every command. A small payload that is always consistent
/// beats a set of patches that can drift out of step with the engine.
@MainActor
public final class APIServer {

    public let port: UInt16
    // The state the split-out halves of this type share with it. `private` is file-scoped in Swift, so
    // these members are internal rather than private: `APIServer+Events.swift` pushes snapshots and
    // deltas from the feed task, `APIServer+Commands.swift` translates a request against the shared
    // dispatch, and `APIServer+SharedPages.swift` reads a conversation from the store. Nothing outside
    // this module can see them.
    let engine: ConversationEngine
    /// One dispatch for both transports. The HTTP routes are translations into it, so a
    /// command cannot work here and fail over WebTransport.
    let service: EngineService
    private var server: HTTPServer?

    /// The listener itself, for the tests that inspect what it recorded.
    ///
    /// Internal rather than public: nothing outside this module needs the socket, and every counter it
    /// holds is already answered over `/api/health`.
    var httpServer: HTTPServer? { server }

    var feedTask: Task<Void, Never>?
    var tokenObserver: UUID?
    var streams: [HTTPServer.EventStream] = []

    public init(
        engine: ConversationEngine, store: ConversationStore, port: UInt16 = 7788,
        shareBase: String? = nil
    ) {
        self.engine = engine
        self.port = port
        self.service = EngineService(engine: engine, store: store)
        // Where a share link should point.
        //
        // The default is this engine's own loopback address, which is right for a browser on this
        // Mac and useless for the phone the feature exists for. A deployment that publishes the
        // website through Caddy passes its own address (`--share-base`), and the web interface
        // prefers the origin the page was loaded from regardless, because the browser knows that
        // better than the engine can.
        self.service.shareBase = shareBase ?? "http://127.0.0.1:\(port)"
    }

    /// Why a state-changing request must be refused, or nil when it may proceed.
    ///
    /// Two headers do the work, and each closes a different hole.
    ///
    /// * **`Content-Type` must be `application/json`.** The engine only ever reads JSON, and a
    ///   browser cannot send that cross-origin without a preflight — which this server does not
    ///   answer with an allow-origin, so the preflight fails and the request never arrives.
    ///   A cross-origin `text/plain` POST is a *simple request* that skips the preflight entirely,
    ///   which is how a page the user merely visited could drive the engine, and (through
    ///   `/api/seat`) repoint a cloud seat at a host the attacker controlled.
    /// * **When `Origin` is present it must be the host the request was addressed to.** Caddy
    ///   overwrites `Host` with the upstream, so the original is read from `X-Forwarded-Host` when
    ///   it is there. Ports are ignored on purpose: the engine's port is not Caddy's.
    ///
    /// A client that sends neither header — `curl`, the CLI, a script — is unaffected, and a
    /// *same-origin* browser request carries an `Origin` matching `X-Forwarded-Host`.
    nonisolated static func crossOriginRefusal(for request: HTTPRequest) -> HTTPResponse? {
        guard request.method != "GET", request.method != "HEAD" else { return nil }

        // Origin first: a cross-origin request is refused *as* cross-origin whatever its body, so
        // the answer says what was wrong. A preflight carries no body at all, and answering it 415
        // would name the wrong reason.
        if let origin = request.headers["origin"], !origin.isEmpty {
            let addressed = request.headers["x-forwarded-host"] ?? request.headers["host"] ?? ""
            let originHost = URL(string: origin)?.host ?? ""
            let addressedHost = addressed.split(separator: ":").first.map(String.init) ?? addressed
            guard !originHost.isEmpty, originHost == addressedHost else {
                return .error("cross-origin request refused", status: 403)
            }
        }

        if request.headers["sec-fetch-site"]?.lowercased() == "cross-site" {
            return .error("cross-origin request refused", status: 403)
        }

        let contentType = request.headers["content-type"]?.lowercased() ?? ""
        guard contentType.hasPrefix("application/json") else {
            return .error("this endpoint accepts application/json only", status: 415)
        }
        return nil
    }

    /// The shared dispatch, so a caller can treat both transports alike.
    public var engineService: EngineService { service }

    public var isRunning: Bool { server?.isRunning ?? false }

    // MARK: - Lifecycle

    public func start() throws {
        let server = HTTPServer(
            port: port,
            handler: { [weak self] request in
                guard let self else { return .error("server is shutting down") }
                return await self.handle(request)
            },
            streamer: { [weak self] request, stream in
                guard let self, request.path == "/api/events" else { return [] }
                return self.subscribe(stream)
            }
        )
        try server.start()
        self.server = server
        startFeed()
    }

    /// Wait until the HTTP listener is accepting connections.
    ///
    /// False means the port could not be taken. Worth checking wherever a server is started:
    /// the failure is asynchronous, so `start()` returning is not evidence that anything is
    /// listening.
    public func waitUntilReady(timeout: Duration = .seconds(2)) async -> Bool {
        guard let server else { return false }
        return await server.waitUntilReady(timeout: timeout)
    }

    public func stop() {
        feedTask?.cancel()
        feedTask = nil
        if let tokenObserver {
            service.stopObservingEvents(tokenObserver)
            self.tokenObserver = nil
        }
        for stream in streams { stream.close() }
        streams.removeAll()
        server?.stop()
        server = nil
    }

    // MARK: - Routing

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // Anything that could change state has to be a same-origin JSON request.
        if let refusal = Self.crossOriginRefusal(for: request) { return refusal }
        let response = await route(request)
        // Anything that is not an API route may be a static asset, which is how the web
        // interface is served when Caddy is not in front.
        if response.status == 404, request.method == "GET",
            let asset = WebAssets.asset(for: request.path)
        {
            return HTTPResponse(contentType: asset.contentType, body: asset.body)
        }
        return response
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        // A conversation somebody can open, with replay controls. Checked before the switch
        // because the path is a prefix rather than a fixed route, and transport-specific rather
        // than an engine command: it is a page, and the engine does not render pages. The request's
        // `Host` is deliberately not read: the page needs no origin, so nothing from the header is
        // reflected anywhere.
        if request.method == "GET", request.path.hasPrefix("/s/") {
            return await sharedPage(id: String(request.path.dropFirst(3)))
        }

        // Transport-specific, and none of it is the engine's business.
        switch (request.method, request.path) {
        case ("GET", "/api/health"):
            // What the listener is doing, not just "ok". The counters existed and were reachable from no
            // endpoint, and a dropped connection or a refused request left no trace anywhere, so
            // diagnosing a running engine meant reading source. The strings are operational — a
            // connection error, the listener's own failure, a request the parser refused — and carry no
            // conversation data; `/api` is unauthenticated and LAN-reachable, which is why the history is
            // bounded at the source rather than here.
            //
            // And the status code answers the other question: whether the engine behind the listener can
            // serve a conversation at all. It used to be a hardcoded 200, so a client could not tell the
            // two apart. 503 is what `tools/start.sh` already treats as "not ready" — it probes
            // this route with `curl -sf` — and it is the answer an orchestrator needs.
            let readiness = service.readiness
            var response = HTTPResponse.json(
                APIHealth(
                    status: readiness.isReady ? "ok" : "unavailable",
                    ready: readiness.isReady,
                    seats: readiness.seats,
                    reason: readiness.reason,
                    failedSeats: readiness.failedSeats,
                    port: Int(port),
                    connections: server?.connectionCount ?? 0,
                    openStreams: server?.openStreamCount ?? 0,
                    refusedConnections: server?.refusedConnectionCount ?? 0,
                    listenerError: server?.lastError,
                    recentFailures: server?.recentFailures ?? []))
            response.status = readiness.isReady ? 200 : 503
            return response

        case ("GET", "/api/devices"):
            return .json(
                DeviceList(
                    profiles: DeviceProfiles.all.enumerated().map { index, profile in
                        ListedProfile(profile: profile, common: profile.isCommon, index: index)
                    },
                    captureSet: DeviceProfiles.captureSet.map(\.id)))

        case ("GET", "/api/device"):
            // Identify the screen, so the interface can name it and support can ask what a
            // report came from. An unknown device is a valid answer, not an error.
            let width = request.int("w") ?? 0
            let height = request.int("h") ?? 0
            let isMobile = request.string("mobile") != "false"
            guard width > 0 else { return .error("w is required", status: 400) }
            if let match = DeviceProfiles.nearest(width: width, height: height, isMobile: isMobile) {
                return .json(DeviceMatch(matched: true, profile: match, width: width, height: height))
            }
            return .json(DeviceMatch(matched: false, profile: nil, width: width, height: height))

        case ("GET", "/api/personas"):
            // Both libraries, so a picker can switch modes without a second request.
            return .json(
                DiscussionMode.allCases.map { mode in
                    PersonaOption(
                        mode: mode.rawValue,
                        label: mode.label,
                        summary: mode.summary,
                        personas: PersonaCatalog.styles(for: mode).map {
                            APIPersona(
                                id: $0.id, name: $0.name, category: $0.group,
                                summary: $0.summary, emoji: $0.emoji, isAnalyst: $0.isAnalyst)
                        })
                })

        case ("GET", "/api/report"):
            // Plain markdown rather than JSON, so it opens in a browser.
            guard let report = service.snapshot().report else {
                return .error("no report has been produced yet", status: 404)
            }
            return HTTPResponse(
                contentType: "text/markdown; charset=utf-8", body: Data(report.markdown.utf8))

        case ("GET", "/api/rosters"):
            return .json(RosterLibrary.rosters(for: mode(from: request)))

        case ("GET", "/api/scenarios"):
            return .json(ScenarioLibrary.scenarios(for: mode(from: request)))

        default:
            break
        }

        // Everything else is the engine's, and goes through the same dispatch the
        // WebTransport server uses. A command that works on one channel therefore works on
        // the other, because there is only one implementation of it.
        let command: EngineRequest?
        do {
            command = try translate(request)
        } catch let unreadable as UnreadableRequest {
            // 400, and the reason is the server's own: a client that sent something unreadable is told
            // what was wrong with it rather than that the route does not exist.
            return .error(unreadable.reason, status: 400)
        } catch {
            // `translate` throws only `UnreadableRequest`; anything else here is a defect, and naming
            // it in a 400 is better than a crash or a blank answer.
            return .error("the request could not be read: \(error)", status: 400)
        }
        guard let command else {
            return .error("no route for \(request.method) \(request.path)", status: 404)
        }
        let reply = await service.handle(command)
        return respond(to: reply)
    }

    /// The mode a query asks about, defaulting to entertainment.
    ///
    /// Used only by the two list endpoints, because they answer questions about a library
    /// rather than commands about the conversation. Everything else asks the engine what mode
    /// it is in, which is the only place that can answer.
    private func mode(from request: HTTPRequest) -> DiscussionMode {
        guard let raw = request.string("mode"), let mode = DiscussionMode(rawValue: raw) else {
            return .entertainment
        }
        return mode
    }

    /// Turn an engine reply into an HTTP response.
    private func respond(to reply: EngineReply) -> HTTPResponse {
        switch reply {
        case .state(let snapshot): return .json(snapshot)
        case .report(let markdown):
            return HTTPResponse(
                contentType: "text/markdown; charset=utf-8", body: Data(markdown.utf8))
        case .savedConversations(let list):
            return .json(list)
        case .rosters(let list):
            return .json(list)
        case .scenarios(let list):
            return .json(list)
        case .refused(let reason):
            // A refusal is an answer, so it is 409 rather than 500 — the client shows the
            // reason and carries on.
            return .error(reason, status: 409)
        case .failed(let reason):
            // The engine could not answer at all, which is a server-side failure rather than
            // something the caller did: 500, with the reason the transport gave.
            return .error(reason, status: 500)
        }
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Internal rather than private: `APIServer+Events.swift` encodes every frame it broadcasts
    /// through it. `encoder` stays private here, because this is still the only caller.
    func encode(_ value: some Encodable) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
