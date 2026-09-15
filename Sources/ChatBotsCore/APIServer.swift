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
public struct APISnapshot: Codable, Sendable {
    public struct Seat: Codable, Sendable {
        public var id: String
        public var name: String
        /// The persona's symbol, so a picker and the header can show the cast rather than
        /// only naming it.
        public var personaEmoji: String
        public var model: String
        public var modelShortName: String
        public var backend: String
        public var backendLabel: String
        /// The persona's identifier, so a client can populate a picker from a snapshot.
        public var personaID: String?
        public var personaName: String
        public var personaSummary: String
        public var thinking: String
        public var thinkingDetail: String
        public var temperature: Double
        public var topP: Double
        public var topK: Int
        public var minP: Double
        public var presencePenalty: Double?
        public var repetitionPenalty: Double?
        public var maxTokens: Int
        public var webSearch: Bool
        public var vision: Bool
        public var endpoint: String?
        public var apiModel: String?
    }

    public struct Message: Codable, Sendable {
        public var id: String
        public var sequence: Int
        public var speaker: String
        public var speakerID: String?
        public var kind: String
        public var text: String
        public var timestamp: Date
        public var toolDetail: String?
    }

    /// What a seat is doing right now, for the live panes.
    public struct Live: Codable, Sendable {
        public var seatID: String
        public var isGenerating: Bool
        public var text: String
        public var reasoning: String
        public var activity: String?
        public var toolLog: [String]
        public var stats: TurnStats?
    }

    public var topic: String
    /// The mode this room is in, so a front end knows which library to offer.
    public var mode: String
    public var modeLabel: String
    public var status: String
    public var isRunning: Bool
    public var isPaused: Bool
    public var turnsCompleted: Int
    public var seats: [Seat]
    public var messages: [Message]
    public var live: [Live]
    public var notices: [String]
    public var error: String?
    public var contextTokens: Int
    public var contextWindow: Int
    public var contextFraction: Double
    public var compactThreshold: Double
    public var attachments: [APIAttachment]
    public var canAttach: Bool
    public var imagesAllowed: Bool
    public var availablePersonas: [APIPersona]
    /// The checkpoints this engine offers, so a front end can present the same list the app's own
    /// picker shows without shipping a second copy of it.
    ///
    /// Optional because a snapshot from an engine that predates the field must still decode, the same
    /// reason `revision` is (A110): a missing list is "nothing to offer here", not a broken state.
    public var availableModels: [APIModelOption]?
    public var serverTime: Date

    /// A counter the engine increments for every snapshot it produces.
    ///
    /// `serverTime` is encoded ISO-8601, so it is whole-second and cannot order two snapshots
    /// produced inside the same second — a `run` reply racing a push within one second would
    /// compare equal, and the older `status` could be applied last. It is also the wall clock,
    /// so a backwards clock step would make every later snapshot look stale and freeze the
    /// interface's updates. A revision orders snapshots whatever the clock does (audit A110).
    ///
    /// Optional so a snapshot from an engine that predates the field still decodes; `isOlder`
    /// falls back to `serverTime` when either side has none.
    public var revision: Int?

    /// Whether this snapshot was produced before `other`.
    ///
    /// The engine's monotonic revision decides it whenever both snapshots carry one. When
    /// either does not — an older engine on the other end of the wire — the wall clock is the
    /// only ordering available, which is exactly what was used before the revision existed.
    public func isOlder(than other: APISnapshot) -> Bool {
        if let revision, let otherRevision = other.revision {
            return revision < otherRevision
        }
        return serverTime < other.serverTime
    }

    /// The research session, when there is one. Nil in entertainment, where there is no
    /// budget and no end condition on purpose.
    public var research: ResearchStatus?
    /// What the room calls the human moderator, and how their interjections read.
    public var moderatorName: String
    public var moderatorPersona: String
    /// Where this engine's HTTP server is listening, so a client can build a share link without
    /// being told a port. Nil when there is no HTTP server — a WebTransport-only engine has
    /// nothing for a browser to open.
    public var shareBase: String?
    /// The audience's votes, one per contribution.
    public var votes: [Vote]
    /// The scorecard, best first.
    public var audience: [AudienceEntry]
    /// The finished report, when the session produced one.
    public var report: ReportSummary?

    /// One fragment of a model's output, as streamed.
    ///
    /// The API sends these between snapshots so a client can show a reply being written
    /// rather than receiving whole answers. Small on purpose: a turn can produce thousands of
    /// tokens, and a snapshot per token would be kilobytes each time.
    public struct OutputDelta: Codable, Sendable {
        public var agentID: String
        public var text: String
        /// `token`, `reasoning`, `tool` or `started`.
        public var kind: String

        public init(agentID: String, text: String, kind: String) {
            self.agentID = agentID
            self.text = text
            self.kind = kind
        }

        public var isOutput: Bool { kind == "token" }
        public var isReasoning: Bool { kind == "reasoning" }
        public var isTool: Bool { kind == "tool" }
        public var isStart: Bool { kind == "started" }
    }

    public struct ResearchStatus: Codable, Sendable {
        public var depth: String
        public var budgetSummary: String
        public var rounds: Int
        public var maxRounds: Int
        public var searches: Int
        public var maxSearches: Int
        public var remainingMinutes: Int
        public var statusLine: String
        public var isFinished: Bool
        public var stopReason: String?
    }

    /// One contribution's verdict, for a front end marking up the transcript.
    public struct Vote: Codable, Sendable, Hashable {
        public var turnID: String
        public var seatID: String
        public var verdict: String
    }

    /// How one seat stands with the audience.
    public struct AudienceEntry: Codable, Sendable, Hashable {
        public var seatID: String
        public var name: String
        public var strong: Int
        public var weak: Int
        public var score: Int
    }

    public struct ReportSummary: Codable, Sendable {
        public var question: String
        public var producedAt: Date
        public var stopReason: String
        public var labelledClaims: Int
        /// True when the model returned a report without the labels that make it usable.
        public var isLabelled: Bool
        /// Required sections the report did not cover.
        public var missingSections: [String]
        /// The whole report, as markdown, for display and for saving.
        public var markdown: String
    }
}

public struct APIAttachment: Codable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var summary: String
    public var tokens: Int
    public var wasTruncated: Bool
    // The image's bytes are deliberately absent (A144, A214).
    //
    // This carried `imageBase64` — the whole encoded image, re-encoded on every snapshot — so that a
    // front end *could* show a thumbnail. No front end ever did: the page's chip is a name and a
    // summary, and the Mac app's chip is an SF Symbol. What it did do was put a base64 copy of every
    // attached image into every state push, to every connected client, on every turn — up to 24 files
    // of up to 64 MB each, re-encoded per snapshot. It also let the snapshot exceed the transport's
    // own message cap, which is derived from one maximum-size attachment: two of them need twice the
    // cap, so the state push was refused and the client silently kept the previous state. The engine
    // holds the bytes, which is where the model request reads them from; a front end that ever needs
    // them should ask for one by id rather than be sent all of them again and again.
}

/// What `/api/health` answers with.
///
/// Its own type rather than a dictionary of strings, because a diagnostics report has numbers and a list
/// in it (A151).
public struct APIHealth: Codable, Sendable {
    public var status: String
    /// A number, like every other counter here: this type exists so a report carries numbers rather than
    /// strings a reader has to parse.
    public var port: Int
    /// Connections the listener is holding, streams it is holding open, and connections it has refused.
    public var connections: Int
    public var openStreams: Int
    public var refusedConnections: Int
    /// Why the listener stopped, when it did.
    public var listenerError: String?
    /// The most recent failures, newest first, bounded by `HTTPServer.failureHistoryLimit`.
    public var recentFailures: [HTTPServer.ConnectionFailure]
}

public struct APIModelOption: Codable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    /// The download size as text ("3.2 GB"), when it is known.
    public var sizeLabel: String?
}

public struct APIPersona: Codable, Sendable {
    public var id: String
    public var name: String
    public var category: String
    public var summary: String
    public var emoji: String
    /// True for the analytical roles, so a picker can mark which library it is showing.
    public var isAnalyst: Bool
}

/// One mode's worth of personas, for the picker.
public struct PersonaOption: Codable, Sendable {
    public var mode: String
    public var label: String
    public var summary: String
    public var personas: [APIPersona]
}

/// The profile list, flattened for the wire.
public struct DeviceList: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var id: String
        public var name: String
        public var `class`: String
        public var width: Int
        public var height: Int
        public var pixelRatio: Double
        public var year: Int
        public var common: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, width, height, pixelRatio, year, common
            case `class` = "class"
        }
    }

    public var profiles: [Entry]
    public var captureSet: [String]

    init(profiles: [ListedProfile], captureSet: [String]) {
        self.profiles = profiles.map(\.entry)
        self.captureSet = captureSet
    }
}

public struct ListedProfile: Codable, Sendable {
    public var entry: DeviceList.Entry
    public var index: Int

    init(profile: DeviceProfile, common: Bool, index: Int) {
        self.entry = DeviceList.Entry(
            id: profile.id, name: profile.name, class: profile.kind.rawValue,
            width: profile.width, height: profile.height,
            pixelRatio: profile.pixelRatio, year: profile.year, common: common)
        self.index = index
    }
}

/// The answer to "what screen am I on".
public struct DeviceMatch: Codable, Sendable {
    public var matched: Bool
    public var profile: DeviceProfile?
    public var width: Int
    public var height: Int
    /// The class the layout would use here, which is useful even when the device is unknown.
    public var deviceClass: String

    init(matched: Bool, profile: DeviceProfile?, width: Int, height: Int) {
        self.matched = matched
        self.profile = profile
        self.width = width
        self.height = height
        self.deviceClass = profile?.kind.rawValue ?? (width <= 719 ? "phone" : width <= 1023 ? "tablet" : "desktop")
    }
}

/// A command from a front end. Decoded from a small JSON body.
public struct APICommand: Codable, Sendable {
    public var topic: String?
    public var text: String?
    public var seat: String?
    public var value: String?
    public var on: Bool?
    public var name: String?
    public var personaID: String?
    /// The MLX checkpoint for a seat, as a repository id or a catalogue alias.
    public var modelID: String?
    public var thinking: String?
    public var backend: String?
    public var showReasoning: Bool?
    public var baseURL: String?
    public var apiModel: String?
    public var apiKey: String?
    /// A base64 document, for a front end that cannot do multipart uploads.
    public var filename: String?
    public var content: String?
    /// A line-up or scenario identifier.
    public var id: String?
    /// A seed for a random line-up, when the caller wants a particular draw rather than any.
    public var seed: UInt64?
    /// The audience's verdict: "strong" or "weak". Absent withdraws the vote.
    public var verdict: String?
}

/// Serves the engine over HTTP.
@MainActor
public final class APIServer {

    public let port: UInt16
    private let engine: ConversationEngine
    /// One dispatch for both transports. The HTTP routes are translations into it, so a
    /// command cannot work here and fail over WebTransport.
    private let service: EngineService
    private var server: HTTPServer?

    /// The listener itself, for the tests that inspect what it recorded (A151).
    ///
    /// Internal rather than public: nothing outside this module needs the socket, and every counter it
    /// holds is already answered over `/api/health`.
    var httpServer: HTTPServer? { server }

    private var feedTask: Task<Void, Never>?
    private var tokenObserver: UUID?
    private var streams: [HTTPServer.EventStream] = []

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
        // better than the engine can (A99).
        self.service.shareBase = shareBase ?? "http://127.0.0.1:\(port)"
    }

    /// Why a state-changing request must be refused, or nil when it may proceed.
    ///
    /// Two headers do the work, and each closes a different hole (A136).
    ///
    /// * **`Content-Type` must be `application/json`.** The engine only ever reads JSON, and a
    ///   browser cannot send that cross-origin without a preflight — which this server does not
    ///   answer with an allow-origin (A75), so the preflight fails and the request never arrives.
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

    /// A `Host` header that is safe to reflect into a URL, or nil.
    ///
    /// Reflecting the header is how a share link comes back to the origin that actually served the
    /// page, but the value is client-supplied: anything carrying a path, a userinfo `@`, whitespace
    /// or a character a host or port cannot contain is refused rather than interpolated. A refused
    /// value falls back to the configured base.
    ///
    /// `nonisolated` because it is a pure function of its argument: the server is main-actor
    /// isolated, and a caller that only wants to know whether a string is a host should not have to
    /// hop to that actor to find out.
    nonisolated static func validShareHost(_ host: String?) -> String? {
        guard let host, !host.isEmpty, host.count <= 255 else { return nil }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return host
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
        // Anything that could change state has to be a same-origin JSON request (A136).
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
        // than an engine command: it is a page, and the engine does not render pages.
        if request.method == "GET", request.path.hasPrefix("/s/") {
            return await sharedPage(
                id: String(request.path.dropFirst(3)), host: request.headers["host"])
        }

        // Transport-specific, and none of it is the engine's business.
        switch (request.method, request.path) {
        case ("GET", "/api/health"):
            // What the listener is doing, not just "ok". The counters existed and were reachable from no
            // endpoint, and a dropped connection or a refused request left no trace anywhere, so
            // diagnosing a running engine meant reading source (A151). The strings are operational — a
            // connection error, the listener's own failure, a request the parser refused — and carry no
            // conversation data; `/api` is unauthenticated and LAN-reachable, which is why the history is
            // bounded at the source rather than here.
            return .json(
                APIHealth(
                    status: "ok",
                    port: Int(port),
                    connections: server?.connectionCount ?? 0,
                    openStreams: server?.openStreamCount ?? 0,
                    refusedConnections: server?.refusedConnectionCount ?? 0,
                    listenerError: server?.lastError,
                    recentFailures: server?.recentFailures ?? []))

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
            return .json(DiscussionMode.allCases.map { mode in
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
            // what was wrong with it rather than that the route does not exist (A142).
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

    /// Turn an HTTP request into an engine request.
    /// A kept conversation as a standalone read-only page.
    ///
    /// 404 rather than a blank page for an id that names nothing: a shared link that opens an
    /// empty conversation is indistinguishable from one whose transcript was lost, and the
    /// reader has no way to tell which happened.
    /// The replay page for a shared link.
    ///
    /// The lookup reads the whole conversation index, because that is one file (A137), and it happens
    /// off the main actor: this handler is on the main actor and so is the engine's turn loop, so an
    /// index read while a conversation was streaming stalled the stream (A147). A malformed id never
    /// reaches the store at all, which is what it did before as well — the difference is that a
    /// well-formed id nobody has heard of no longer decodes the history to find that out.
    private func sharedPage(id: String, host: String?) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else { return sharedPageNotFound() }
        guard let record = await service.store.conversationOffMainActor(id: uuid) else {
            return sharedPageNotFound()
        }
        // The page's own links go back to the origin that served it, so a phone that reached the
        // page through Caddy gets Caddy's address rather than the engine's loopback port — which is
        // the address the phone could not reach in the first place (A99).
        let base =
            Self.validShareHost(host).map { "http://\($0)" }
            ?? service.shareBase ?? "http://127.0.0.1:\(port)"
        return HTTPResponse(
            contentType: "text/html; charset=utf-8",
            body: Data(SharedConversationPage.html(record, shareBase: base).utf8),
            // The share page carries its own inline stylesheet and replay script, so it says so
            // rather than inheriting the interface's policy, which has no inline grant.
            headers: ["Content-Security-Policy": HTTPResponse.inlinePagePolicy])
    }

    /// A page that says the link does not work, rather than a bare 404 body: the reader followed a
    /// link somebody sent them, and "no conversation with that link" is the answer they need.
    private func sharedPageNotFound() -> HTTPResponse {
        let missing = [
            "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">",
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
            "<title>No conversation with that link</title></head>",
            "<body style=\"font:15px/1.5 -apple-system,system-ui,sans-serif;max-width:640px;"
                + "margin:60px auto;padding:0 16px\">",
            "<h1 style=\"font-size:19px\">No conversation with that link</h1>",
            "<p>It may have been deleted, or the link may have been copied incompletely.</p>",
            "</body></html>",
        ].joined(separator: "\n")
        return HTTPResponse(
            status: 404, contentType: "text/html; charset=utf-8",
            body: Data(missing.utf8),
            // The default page policy refuses inline style, and this page carries one on its body.
            // It carries no script, so the replacement grants style only.
            headers: ["Content-Security-Policy": HTTPResponse.inlineStylePagePolicy])
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

    /// A request that cannot be turned into an engine request, and why.
    ///
    /// Separate from "no route" because the answer differs: an unknown route is a 404, a body the
    /// server cannot read is a 400 that says what was wrong (A142).
    private struct UnreadableRequest: Error {
        var reason: String
    }

    /// The command body, telling three states apart that `try?` used to collapse into one.
    ///
    /// No body at all means the field was not sent, which some routes treat as "clear this" and is
    /// the caller's decision. A body that decodes is the command. A body that was **sent and cannot
    /// be read** is a client error — and it used to be read as the defaults, so a typo in `mode`
    /// switched the room to entertainment, an unknown research depth reset it to standard, and a
    /// malformed topic cleared it. Silent, and in the direction of changing state (A142).
    private func command(from request: HTTPRequest) throws -> APICommand? {
        guard !request.body.isEmpty else { return nil }
        guard let decoded = request.json(APICommand.self) else {
            throw UnreadableRequest(
                reason: "the request body is not a JSON object with the fields this route takes")
        }
        return decoded
    }

    /// The 400 for a value that is present but not one this server knows.
    ///
    /// The two routes that map a string to a case used to answer with a default instead — an unknown
    /// mode switched the room to entertainment, an unknown research depth reset it to standard — so a
    /// misspelling changed state. It is a bad request, and the answer says what was expected (A142).
    private func unknownValue(_ field: String, _ raw: String, _ allowed: [String]) -> UnreadableRequest {
        UnreadableRequest(
            reason: "unknown \(field) \"\(raw)\" — expected one of: \(allowed.joined(separator: ", "))")
    }

    /// The change a seat update describes.
    ///
    /// Pulled out of `translate` because the case that used to build it inline put that function over
    /// its `function_body_length` budget, and a named value reads better than a nested `.init` anyway.
    private func seatChange(from body: APICommand, seatID: String) -> EngineRequest.SeatChange {
        EngineRequest.SeatChange(
            seatID: seatID, name: body.name, personaID: body.personaID,
            thinking: body.thinking.flatMap(ThinkingMode.init(rawValue:)),
            backend: body.backend.flatMap(AgentSpec.Backend.init(rawValue:)),
            modelID: body.modelID,
            baseURL: body.baseURL, apiModel: body.apiModel, apiKey: body.apiKey)
    }

    private func translate(_ request: HTTPRequest) throws -> EngineRequest? {
        switch (request.method, request.path) {
        case ("GET", "/api/state"): return .fetchState
        case ("POST", "/api/start"): return .start
        case ("POST", "/api/pause"): return .pause
        case ("POST", "/api/resume"): return .resume
        case ("POST", "/api/stop"): return .stop
        case ("POST", "/api/reset"): return .reset
        case ("POST", "/api/compact"): return .compact
        case ("POST", "/api/attachments/clear"): return .clearAttachments
        case ("GET", "/api/conversations"): return .listSavedConversations
        case ("POST", "/api/conversations/new"): return .newConversation

        case ("POST", "/api/conversations/load"):
            guard let id = try command(from: request)?.value else { return nil }
            return .loadSavedConversation(id: id)

        case ("POST", "/api/conversations/delete"):
            guard let id = try command(from: request)?.value else { return nil }
            return .deleteSavedConversation(id: id)

        case ("POST", "/api/topic"):
            guard let body = try command(from: request), let topic = body.topic,
                !topic.isEmpty
            else { return .setTopic("") }   // an empty topic is refused by the engine
            return .setTopic(topic)

        case ("POST", "/api/message"):
            guard let body = try command(from: request), let text = body.text else {
                return .steer("")
            }
            return .steer(text)

        case ("POST", "/api/settings"):
            let body = try command(from: request)
            return .setShowReasoning(body?.showReasoning ?? service.showReasoning)

        case ("POST", "/api/mode"):
            guard let raw = try command(from: request)?.value else { return nil }
            guard let mode = DiscussionMode(rawValue: raw) else {
                throw unknownValue("mode", raw, DiscussionMode.allCases.map(\.rawValue))
            }
            return .setMode(mode)

        case ("POST", "/api/roster"):
            guard let body = try command(from: request), let id = body.id else { return nil }
            // A seed the caller supplies reproduces a draw; one it does not supply is made
            // here and reported, so every draw is repeatable whether or not it was planned.
            return .applyRoster(id: id, seed: body.seed ?? RosterLibrary.freshSeed())

        case ("POST", "/api/scenario"):
            guard let id = try command(from: request)?.id else { return nil }
            return .applyScenario(id: id)

        case ("POST", "/api/vote"):
            guard let body = try command(from: request), let turnID = body.id else { return nil }
            // No verdict withdraws the vote, so a mis-click does not have to be reversed by
            // clicking the opposite button — which would leave a wrong judgement in the record.
            return .castVote(
                turnID: turnID,
                verdict: body.verdict.flatMap(AudienceVote.Verdict.init(rawValue:)))

        case ("POST", "/api/votes/clear"):
            return .clearVotes

        case ("POST", "/api/moderator"):
            guard let body = try command(from: request) else { return nil }
            return .setModerator(
                ModeratorIdentity(
                    name: body.name ?? ModeratorIdentity.defaultName,
                    personaID: body.personaID ?? PersonaLibrary.neutral.id))

        case ("POST", "/api/research/budget"):
            guard let raw = try command(from: request)?.value else { return nil }
            guard let depth = ResearchBudget.Depth(rawValue: raw) else {
                throw unknownValue(
                    "research depth", raw, ResearchBudget.Depth.allCases.map(\.rawValue))
            }
            return .setResearchBudget(depth)

        case ("POST", "/api/seat"):
            guard let body = try command(from: request), let seatID = body.seat else {
                return nil
            }
            return .updateSeat(seatChange(from: body, seatID: seatID))

        case ("POST", "/api/attachments"):
            guard let body = try command(from: request), let filename = body.filename,
                let content = body.content, let data = Data(base64Encoded: content)
            else { return nil }
            return .addAttachment(filename: filename, contents: data)

        case ("POST", "/api/attachments/remove"):
            guard let id = try command(from: request)?.value else { return nil }
            return .removeAttachment(id: id)

        default:
            return nil
        }
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


    // MARK: - Events

    private func subscribe(_ stream: HTTPServer.EventStream) -> [String] {
        streams.append(stream)
        streams.removeAll { !$0.isOpen }
        // A fresh connection is handed the current state immediately, so a page that has
        // just loaded, or reloaded, does not have to wait for the next turn to see anything.
        // It is returned rather than sent so the server can put the response head first.
        return [encode(service.snapshot()) ?? "{}"]
    }

    /// One task per connection, writing each new turn as it is published.
    private func startFeed() {
        feedTask?.cancel()
        feedTask = Task { [weak self] in
            guard let self else { return }
            var seen = Set<UUID>()
            for await turns in self.engine.transcriptUpdates {
                if Task.isCancelled { return }
                for turn in turns where !seen.contains(turn.id) {
                    seen.insert(turn.id)
                    self.broadcast(
                        self.encode(MessageEnvelope(turn: turn)) ?? "{}", event: "turn")
                }
                self.broadcast(self.encode(self.service.snapshot()) ?? "{}", event: "snapshot")
            }
        }
        startTokenFeed()
    }

    /// Stream the model's output as it is written.
    ///
    /// The snapshot feed alone is not enough for a client that wants to show a reply being
    /// written: it fires once per turn, so the text would appear in whole answers rather than
    /// arriving as it is produced. This carries the engine's own per-token events instead.
    ///
    /// Deliberately a small payload — an id and a fragment — rather than a fresh snapshot per
    /// token. A snapshot is a few kilobytes and a turn can produce thousands of tokens;
    /// broadcasting one per token would drown the connection in its own status.
    ///
    /// The reasoning stream is carried too, so a client can show the thinking blocks the
    /// desktop app shows.
    private func startTokenFeed() {
        // Watched rather than read from the stream, because the WebTransport server forwards
        // the same events to the desktop app and an `AsyncStream` would give the whole
        // sequence to one of them and nothing to the other.
        tokenObserver = service.observeEvents { [weak self] event in
            guard let self else { return }
            switch event {
                case .token(let agentID, let text):
                    self.broadcast(
                        self.encode(APISnapshot.OutputDelta(agentID: agentID, text: text, kind: "token")) ?? "{}",
                        event: "delta")
                case .reasoning(let agentID, let text):
                    self.broadcast(
                        self.encode(APISnapshot.OutputDelta(agentID: agentID, text: text, kind: "reasoning")) ?? "{}",
                        event: "delta")
                case .toolCall(let agentID, let name, let query):
                    self.broadcast(
                        self.encode(APISnapshot.OutputDelta(
                            agentID: agentID, text: "\(name)(\(query))", kind: "tool")) ?? "{}",
                        event: "delta")
                case .turnStarted(let agentID, _):
                    self.broadcast(
                        self.encode(APISnapshot.OutputDelta(agentID: agentID, text: "", kind: "started")) ?? "{}",
                        event: "delta")
            default:
                // Everything else is reflected in the snapshot that follows the turn.
                break
            }
        }
    }



    private struct MessageEnvelope: Encodable {
        var turn: APISnapshot.Message

        init(turn: Turn) {
            self.turn = APISnapshot.Message(
                id: turn.id.uuidString,
                sequence: turn.sequence,
                speaker: turn.speakerName,
                speakerID: turn.speakerID,
                kind: turn.kind.rawValue,
                text: turn.content,
                timestamp: turn.timestamp,
                toolDetail: turn.toolDetail
            )
        }
    }

    private func broadcast(_ payload: String, event: String? = nil) {
        streams.removeAll { !$0.isOpen }
        for stream in streams { stream.send(payload, event: event) }
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func encode(_ value: some Encodable) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
