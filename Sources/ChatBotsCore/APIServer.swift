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
        public var model: String
        public var modelShortName: String
        public var backend: String
        public var backendLabel: String
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
    public var serverTime: Date
}

public struct APIAttachment: Codable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var summary: String
    public var tokens: Int
    public var wasTruncated: Bool
    /// Only for images, and only so a front end can show a thumbnail.
    public var imageBase64: String?
}

public struct APIPersona: Codable, Sendable {
    public var id: String
    public var name: String
    public var category: String
    public var summary: String
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
    public var thinking: String?
    public var backend: String?
    public var showReasoning: Bool?
    public var baseURL: String?
    public var apiModel: String?
    public var apiKey: String?
    /// A base64 document, for a front end that cannot do multipart uploads.
    public var filename: String?
    public var content: String?
}

/// Serves the engine over HTTP.
@MainActor
public final class APIServer {

    public let port: UInt16
    private let engine: ConversationEngine
    private var server: HTTPServer?
    private var feedTask: Task<Void, Never>?
    private var streams: [HTTPServer.EventStream] = []

    /// Whether the web interface shows the models' thinking blocks. A view preference, but
    /// it belongs to the server because both front ends share one conversation.
    public var showReasoning = true

    public init(engine: ConversationEngine, port: UInt16 = 7788) {
        self.engine = engine
        self.port = port
    }

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

    public func stop() {
        feedTask?.cancel()
        feedTask = nil
        for stream in streams { stream.close() }
        streams.removeAll()
        server?.stop()
        server = nil
    }

    // MARK: - Routing

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // A browser issues a preflight before a cross-origin write; answer it and stop.
        if request.method == "OPTIONS" { return HTTPResponse(status: 204) }

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
        switch (request.method, request.path) {
        case ("GET", "/api/health"):
            return .json(["status": "ok", "port": "\(port)"])

        case ("GET", "/api/state"):
            return .json(snapshot())

        case ("GET", "/api/personas"):
            return .json(PersonaLibrary.all.map {
                APIPersona(id: $0.id, name: $0.name, category: $0.category.rawValue, summary: $0.summary)
            })

        case ("POST", "/api/topic"):
            guard let command = request.json(APICommand.self), let topic = command.topic else {
                return .error("a topic is required", status: 400)
            }
            // Refused once the conversation has started, the same as attachments: the
            // topic is the frame the whole log was written against.
            guard engine.setTopic(topic) else {
                return .error(
                    "the topic cannot be changed once the conversation has started", status: 409)
            }
            return .json(snapshot())

        case ("POST", "/api/start"):
            engine.startOrRestart()
            return .json(snapshot())

        case ("POST", "/api/pause"):
            engine.pause()
            return .json(snapshot())

        case ("POST", "/api/resume"):
            engine.resume()
            return .json(snapshot())

        case ("POST", "/api/stop"):
            engine.stop()
            return .json(snapshot())

        case ("POST", "/api/reset"):
            engine.reset()
            // Any open page may still be mid-render of turns that no longer exist.
            broadcast(encode(snapshot()) ?? "{}", event: "snapshot")
            return .json(snapshot())

        case ("POST", "/api/compact"):
            engine.compactNow()
            return .json(snapshot())

        case ("POST", "/api/message"):
            guard let command = request.json(APICommand.self), let text = command.text,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .error("a message is required", status: 400)
            }
            engine.steer(text)
            return .json(snapshot())

        case ("POST", "/api/settings"):
            guard let command = request.json(APICommand.self) else {
                return .error("a JSON body is required", status: 400)
            }
            if let show = command.showReasoning { showReasoning = show }
            return .json(snapshot())

        case ("POST", "/api/seat"):
            return applySeatCommand(request)

        case ("POST", "/api/attachments"):
            return addAttachment(request)

        case ("POST", "/api/attachments/remove"):
            guard let command = request.json(APICommand.self), let id = command.value else {
                return .error("an attachment id is required", status: 400)
            }
            engine.setAttachments(engine.attachments.filter { $0.id.uuidString != id })
            return .json(snapshot())

        case ("POST", "/api/attachments/clear"):
            engine.setAttachments([])
            return .json(snapshot())

        default:
            return .error("no route for \(request.method) \(request.path)", status: 404)
        }
    }

    private func applySeatCommand(_ request: HTTPRequest) -> HTTPResponse {
        guard let command = request.json(APICommand.self),
            let seatID = command.seat,
            let index = engine.specs.firstIndex(where: { $0.id == seatID })
        else {
            return .error("a seat id is required", status: 400)
        }

        var spec = engine.specs[index]
        if let name = command.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            spec.displayName = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
        }
        if let personaID = command.personaID { spec.personaID = personaID }
        if let raw = command.thinking, let mode = ThinkingMode(rawValue: raw) {
            spec.thinking = mode
        }
        if let raw = command.backend, let backend = AgentSpec.Backend(rawValue: raw) {
            spec.backend = backend
        }
        if let url = command.baseURL {
            spec.openAI.baseURL = url.trimmingCharacters(in: .whitespaces)
        }
        if let model = command.apiModel { spec.openAI.model = model }
        if let key = command.apiKey { spec.openAI.apiKey = key }
        if let showVision = command.on { spec.visionOverride = showVision ? .supported : .unsupported }
        if let value = command.value, let temperature = Double(value) { spec.temperature = temperature }

        engine.updateSeat(spec)
        return .json(snapshot())
    }

    private func addAttachment(_ request: HTTPRequest) -> HTTPResponse {
        guard let command = request.json(APICommand.self),
            let filename = command.filename, let content = command.content
        else {
            return .error("filename and content are required", status: 400)
        }
        guard let data = Data(base64Encoded: content) else {
            return .error("content must be base64-encoded", status: 400)
        }
        guard engine.attachments.count < 24 else {
            return .error("too many attached files", status: 409)
        }

        // Written to a temporary file because the extractors take a URL — the app's own
        // import path is file-based, and duplicating it for an in-memory case would mean
        // two code paths that could disagree about what a file contains.
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "chatbots-upload-\(UUID().uuidString)")
            .appending(path: filename)
        do {
            try FileManager.default.createDirectory(
                at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: temporary)
        } catch {
            return .error("could not stage the upload: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }

        do {
            let document = try DocumentIngestorProvider.ingestor.add(url: temporary)
            guard !document.kind.isImage || engine.allSeatsSupportVision else {
                return .error("images need every seat to support vision", status: 409)
            }
            engine.setAttachments(engine.attachments + [document])
            return .json(snapshot())
        } catch let error as DocumentError {
            return .error(error.errorDescription ?? "the file could not be read", status: 400)
        } catch {
            return .error(error.localizedDescription, status: 400)
        }
    }

    // MARK: - State

    public func snapshot() -> APISnapshot {
        let usage = engine.contextUsage
        return APISnapshot(
            topic: engine.topic,
            status: engine.status.label,
            isRunning: engine.isRunning,
            isPaused: engine.isPaused,
            turnsCompleted: engine.startedTurns,
            seats: engine.specs.map { self.seat($0) },
            messages: engine.displayTurns.map { turn in
                APISnapshot.Message(
                    id: turn.id.uuidString,
                    sequence: turn.sequence,
                    speaker: turn.speakerName,
                    speakerID: turn.speakerID,
                    kind: turn.kind.rawValue,
                    text: turn.content,
                    timestamp: turn.timestamp,
                    toolDetail: turn.toolDetail
                )
            },
            live: engine.liveSeats.map { live in
                APISnapshot.Live(
                    seatID: live.id,
                    isGenerating: live.isGenerating,
                    text: live.text,
                    reasoning: live.reasoning,
                    activity: live.activity,
                    toolLog: live.toolLog,
                    stats: live.stats
                )
            },
            notices: engine.notices.suffix(12).map { $0 },
            error: engine.lastError,
            contextTokens: usage.tokens,
            contextWindow: usage.window,
            contextFraction: usage.fraction,
            compactThreshold: engine.configuration.compactThreshold,
            attachments: engine.attachments.map { document in
                APIAttachment(
                    id: document.id.uuidString,
                    name: document.name,
                    kind: document.kind.rawValue,
                    summary: document.summary,
                    tokens: document.estimatedTokens,
                    wasTruncated: document.wasTruncated,
                    imageBase64: document.kind.isImage
                        ? document.imageData?.base64EncodedString() : nil
                )
            },
            canAttach: engine.canAttachFiles,
            imagesAllowed: engine.allSeatsSupportVision,
            availablePersonas: PersonaLibrary.all.map {
                APIPersona(id: $0.id, name: $0.name, category: $0.category.rawValue, summary: $0.summary)
            },
            serverTime: Date()
        )
    }

    private func seat(_ spec: AgentSpec) -> APISnapshot.Seat {
        let persona = PersonaLibrary.persona(id: spec.personaID)
        return APISnapshot.Seat(
            id: spec.id,
            name: spec.displayName,
            model: spec.modelID,
            modelShortName: spec.modelShortName,
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
            apiModel: spec.backend == .openAIResponses ? spec.openAI.model : nil
        )
    }

    // MARK: - Events

    private func subscribe(_ stream: HTTPServer.EventStream) -> [String] {
        streams.append(stream)
        streams.removeAll { !$0.isOpen }
        // A fresh connection is handed the current state immediately, so a page that has
        // just loaded, or reloaded, does not have to wait for the next turn to see anything.
        // It is returned rather than sent so the server can put the response head first.
        return [encode(snapshot()) ?? "{}"]
    }

    /// One task per connection, writing each new turn as it is published.
    private func startFeed() {
        feedTask?.cancel()
        feedTask = Task { [weak self] in
            guard let self else { return }
            var seen = Set<UUID>()
            var ticks = 0
            for await turns in self.engine.transcriptUpdates {
                if Task.isCancelled { return }
                for turn in turns where !seen.contains(turn.id) {
                    seen.insert(turn.id)
                    self.broadcast(
                        self.encode(MessageEnvelope(turn: turn)) ?? "{}", event: "turn")
                }
                self.broadcast(self.encode(self.snapshot()) ?? "{}", event: "snapshot")
                ticks = 0
            }
            // The stream ending means the engine was reset or replaced.
            _ = ticks
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
