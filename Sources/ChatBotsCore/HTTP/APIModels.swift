// ChatBotsCore — the shapes the HTTP API speaks
//
// Split out of `APIServer.swift`, which held every request and response shape the HTTP interface
// speaks next to the server that serves them. The types did not change.

import Foundation

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
    /// reason `revision` is: a missing list is "nothing to offer here", not a broken state.
    public var availableModels: [APIModelOption]?
    public var serverTime: Date

    /// A counter the engine increments for every snapshot it produces.
    ///
    /// `serverTime` is encoded ISO-8601, so it is whole-second and cannot order two snapshots
    /// produced inside the same second — a `run` reply racing a push within one second would
    /// compare equal, and the older `status` could be applied last. It is also the wall clock,
    /// so a backwards clock step would make every later snapshot look stale and freeze the
    /// interface's updates. A revision orders snapshots whatever the clock does.
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
    // The image's bytes are deliberately absent.
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
/// in it.
public struct APIHealth: Codable, Sendable {
    /// `"ok"`, or `"unavailable"` when the engine cannot serve a conversation.
    public var status: String
    /// The same fact as a boolean, for a client that would rather not read the word.
    public var ready: Bool
    /// How many seats the engine has.
    public var seats: Int
    /// Why the engine cannot serve a conversation, in a sentence. Nil when it can.
    public var reason: String?
    /// The seats whose model could not be loaded, and why, by seat id. A seat here is degradation
    /// rather than an outage while another seat still works.
    public var failedSeats: [String: String]
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
