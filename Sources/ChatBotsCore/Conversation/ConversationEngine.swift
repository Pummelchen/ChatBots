// ChatBotsCore — the orchestrator
//
// Owns the shared transcript and the turn loop. Three properties matter here:
//
//  * **Deterministic turn order.** Seat A speaks, then B, then A… Models are never
//    asked to decide who talks next; that would burn a whole generation per turn and
//    occasionally deadlock. A round is one A turn plus one B turn.
//  * **One shared log.** Both seats read the identical history, and every logged entry
//    is rendered to both of them with a speaker tag. Nothing an agent writes is ever
//    private to the other.
//  * **Interruptible but never inconsistent.** Pause takes effect *between* turns, so a
//    half-generated reply is never written into the log. Steering typed mid-turn is
//    queued and appended at the turn boundary, exactly once, for both seats.

import Foundation

/// Control messages the UI sends into the loop.
public enum EngineCommand: Sendable {
    case start
    case pause
    case resume
    case stop
    /// Human moderator speaks into the shared log.
    case steer(text: String)
    /// Wipe the transcript and counters (keeps loaded weights).
    case reset
}

/// Observable status line for the control bar.
public enum RunStatus: Sendable, Equatable {
    case idle
    case preparing
    case running(turn: Int)
    case paused
    /// The configured turn budget is spent. Unlike `.paused`, the loop has exited —
    /// a limit is not something Resume can lift, so it must not keep a task parked.
    case limitReached
    case stopped
    case failed(String)

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .preparing: "Loading models…"
        case .running(let turn): "Running — turn \(turn)"
        case .paused: "Paused"
        case .limitReached: "Turn limit reached"
        case .stopped: "Stopped"
        case .failed(let message): "Failed: \(message)"
        }
    }

    /// Rebuild a status from the line the API reports.
    ///
    /// A client cannot see the engine's enum, so the status crosses as text. This turns it
    /// back, which keeps every view reading the same type whether the engine is local or
    /// across a socket.
    public init(label: String, isRunning: Bool, isPaused: Bool, error: String? = nil) {
        if let error, !error.isEmpty {
            self = .failed(error)
        } else if isPaused {
            self = .paused
        } else if isRunning {
            // The exact turn number is cosmetic; the important part is that it is active.
            let number = Int(label.split(separator: " ").last.map(String.init) ?? "") ?? 0
            self = .running(turn: number)
        } else if label.hasPrefix("Stopped") {
            self = .stopped
        } else if label.hasPrefix("Turn limit") {
            self = .limitReached
        } else {
            self = .idle
        }
    }

    public var isActive: Bool {
        switch self {
        case .preparing, .running: true
        case .idle, .paused, .limitReached, .stopped, .failed: false
        }
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}

@MainActor
public final class ConversationEngine {

    // MARK: Configuration

    public struct Configuration: Sendable {
        /// Sleep between turns so a human can read along.
        public var pace: Duration = .milliseconds(600)
        /// Absolute cap on LLM turns in one conversation.
        public var maxTurns: Int = 40
        /// Condense older turns once a seat's prompt reaches this share of its context
        /// window. The point is to reclaim room *before* the provider truncates, which
        /// would silently drop the start of the discussion.
        public var autoCompact: Bool = true
        /// Fraction of the context window at which compaction runs.
        public var compactThreshold: Double = 0.7
        /// The budget for a research session. Nil means the mode's default preset.
        public var researchBudget: ResearchBudget?
        /// How many recent entries to keep verbatim. Older ones are condensed.
        public var compactKeepRecentTurns: Int = 8
        /// Token allowance for the digest itself.
        public var compactSummaryTokens: Int = 900
        /// How an MLX engine is built for a seat.
        ///
        /// Injected because a seat's checkpoint can be changed while the engine is alive, and the
        /// wiring around an engine is the caller's: the command line routes load progress to stdout,
        /// the app reports it into a pane, and a test wants to see the swap without loading weights.
        public var makeMLXEngine: @Sendable (AgentSpec) -> any LLMEngine = { MLXEngine(spec: $0) }

        public init() {}
    }

    /// One seat: its configuration plus one engine per backend.
    ///
    /// Both engines are held even though only one is used at a time, so a seat can switch
    /// backend without losing the loaded MLX weights or re-resolving the endpoint.
    public struct Seat: Sendable {
        public var spec: AgentSpec
        /// The MLX engine. Every seat has one — both initialisers install an engine here — so
        /// the fallback in `engine` below cannot be empty.
        ///
        /// Replaceable, because the checkpoint a seat runs is a user choice: `setModel` builds a new
        /// engine for the new weights and releases the old one.
        public var mlx: any LLMEngine
        /// The API engine, present only when the seat was built for both backends.
        public var openAI: (any LLMEngine)?

        public init(spec: AgentSpec, engine: any LLMEngine) {
            self.spec = spec
            self.mlx = engine
            self.openAI = nil
        }

        public init(spec: AgentSpec, mlx: any LLMEngine, openAI: any LLMEngine) {
            self.spec = spec
            self.mlx = mlx
            self.openAI = openAI
        }

        /// The engine the spec currently selects. A backend with no engine of its own falls
        /// back to the MLX one, which every seat is guaranteed to hold.
        public var engine: any LLMEngine {
            switch spec.backend {
            case .mlx: mlx
            case .openAIResponses: openAI ?? mlx
            }
        }
    }

    // MARK: Observable state

    public internal(set) var conversation = Conversation(topic: "")
    public private(set) var status: RunStatus = .idle
    /// Steering accepted but not yet appended to the shared log.
    public internal(set) var queuedSteering: [Turn] = []
    /// Non-fatal notices, newest last. The UI drains these into a running commentary.
    public internal(set) var notices: [String] = []
    var noticeContinuation: AsyncStream<[String]>.Continuation?

    /// Why a seat's model could not be loaded, by seat id, from the last attempt to load it.
    ///
    /// A failed load was a notice in the room and nothing else, so a listener could answer
    /// `/api/health` with "ok" while every seat was unusable — the checkpoint deleted, the Metal
    /// library missing. This is what the health check reads. Written from the load group, which
    /// is why it lives on the main actor with the rest of the observable state.
    ///
    /// Cleared by the next successful load and by pointing a seat at a different checkpoint, so a
    /// failure that has been dealt with is not reported for the rest of the session.
    public internal(set) var modelLoadFailures: [String: String] = [:]

    /// Notices as they happen.
    public private(set) lazy var noticeUpdates: AsyncStream<[String]> = {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.noticeContinuation = continuation
        }
    }()

    // MARK: Streams

    /// The sinks for the three streams above. Optional rather than implicitly unwrapped: every
    /// read is `?.yield(…)`, so an unset sink already behaves as "nobody is listening", and the
    /// type can say that instead of asserting it was set.
    private var eventContinuation: AsyncStream<TurnEvent>.Continuation?
    private var statusContinuation: AsyncStream<RunStatus>.Continuation?
    var transcriptContinuation: AsyncStream<[Turn]>.Continuation?
    /// Where the conversation is kept between runs. Set by whoever creates the engine, so the
    /// engine itself does not decide where files live.
    public var conversationStore: ConversationStore?
    /// Whether the last failed save has already produced a notice, so a store that cannot be
    /// written does not append one on every turn. Cleared by the next successful save.
    /// Internal rather than private: `saveConversation()` lives in
    /// `ConversationEngine+Transcript.swift`, and `private` would be file-scoped.
    var reportedSaveFailure = false
    /// Identifies this conversation across saves, so growing it updates one record rather than
    /// adding another every turn.
    public internal(set) var conversationID = UUID()
    /// When it began, for the record.
    var conversationStartedAt = Date.now

    /// Everyone watching the log. See `observeTranscript`.
    var transcriptObservers: [UUID: ([Turn]) -> Void] = [:]
    /// Everyone watching the output. See `observeEvents`.
    private var eventObservers: [UUID: (TurnEvent) -> Void] = [:]

    /// Every token, tool call and note, in order, for a consumer following a run live.
    ///
    /// Built once, in `init`, so the continuation is stable. It was a `lazy var` whose closure
    /// assigned the continuation, which meant *reading the property a second time replaced the
    /// continuation* — so a second reader silently took the stream away from the first, and the
    /// first received nothing more. A stream is still a single-consumer channel, though:
    /// `observeEvents` is the multi-subscriber path, and it is what the HTTP API, the
    /// WebTransport server and the engine's own live panes use. This stream is for a headless
    /// consumer — the CLI.
    ///
    /// **Bounded on purpose.** This was `.unbounded`, which retained every event for the life
    /// of the process whenever nobody iterated it, and in the app nobody does: `publishEvent`
    /// yields on every token, reasoning chunk and tool event, and every `.turnStarted` carries
    /// the whole prompt, so an unobserved run accumulated a full event-by-event copy of the
    /// conversation including one copy of a multi-thousand-token prompt per turn. A consumer
    /// that falls behind now loses the oldest events instead of the process retaining them
    /// forever — the same policy and bound the WebTransport server and the client give each hop, from the
    /// one constant they share. The CLI
    /// only reads the coarse tool and turn events, so dropping stale fragments cannot starve it.
    public private(set) var events: AsyncStream<TurnEvent>

    /// The run status as it changes. Built once; see `events` for why.
    public private(set) var statusUpdates: AsyncStream<RunStatus>

    /// The shared log whenever it changes. Built once; see `events` for why.
    public private(set) var transcriptUpdates: AsyncStream<[Turn]>

    // MARK: Internals

    public var configuration: Configuration
    var seats: [Seat]

    var seatCursor = 0
    /// Who the human moderator is, for the room and for the transcript.
    public var moderator = ModeratorIdentity()
    var turnsCompleted = 0
    /// Prompt tokens the last completed turn actually sent, and how much of that was
    /// transcript text — together they let the next prompt be predicted rather than
    /// guessed. Set from `TurnStats.promptTokens`.
    var measuredPromptTokens: Int?
    /// The name the seat currently speaking goes by, so its reply is logged under the name
    /// it was spoken under rather than the seat's internal id. Captured per turn, which is
    /// what lets a rename change future turns without rewriting history.
    var currentSpeakerName: String?
    var lastMeasuredDialogueTokens = 0
    /// The context window each seat's engine last reported, keyed by seat id.
    ///
    /// The spec's `contextWindow` is only the fallback for an engine that cannot report one.
    /// The MLX backend reads the real number from the checkpoint's own config, and measuring
    /// the auto-compaction threshold against the spec's guess (262 144) meant it never fired
    /// for a model whose actual window is 32 768 — so the provider truncated the start of the
    /// discussion, which is the failure compaction exists to prevent.
    var reportedContextWindows: [String: Int] = [:]
    /// Turns that have begun generating (unlike `turnsCompleted`, counts the current one).
    public internal(set) var startedTurns = 0
    /// Billed web calls made during the turn currently in flight, counted at the tool-call
    /// callback. Reset at the start of each turn and read when the turn finishes, so the search
    /// budget is charged for what was spent rather than inferred from the transcript.
    var toolCallsThisTurn = 0
    var generationTask: Task<Void, Never>?
    /// Which loop `generationTask` belongs to.
    ///
    /// A cancelled task does not stop at the moment it is cancelled: it notices when it next
    /// resumes, which can be after its replacement has already been installed. Each loop
    /// carries the generation it was started in and clears the task reference only if it is
    /// still that generation's loop — so a late predecessor cannot orphan its successor.
    var loopGeneration = 0
    var pauseContinuation: CheckedContinuation<Void, Never>?
    /// Per-seat live progress, keyed by seat id, folded from the engine's own events.
    var liveState: [String: LiveState] = [:]

    public init(seats: [Seat], configuration: Configuration = .init()) {
        precondition(!seats.isEmpty, "a conversation needs at least one seat")
        self.seats = seats
        self.configuration = configuration

        // Built here rather than lazily. A `lazy var` whose closure assigns the continuation
        // hands the stream to whoever reads the property last, so a second reader takes it from
        // the first — which is how the API's token feed silently starved the engine's own
        // transcript feed. Built once in `init`, the continuation is stable and every reader
        // gets the same stream; the API servers subscribe through `observeEvents` rather than
        // competing for it.
        //
        // The event buffer is bounded: with no iterative reader, an unbounded stream retained
        // every token and every full prompt for the life of the process. See `events`.
        let (eventStream, eventSink) = AsyncStream.makeStream(
            of: TurnEvent.self, bufferingPolicy: .bufferingNewest(ProtocolLimits.eventBufferDepth))
        let (statusStream, statusSink) = AsyncStream.makeStream(
            of: RunStatus.self, bufferingPolicy: .bufferingNewest(1))
        let (transcriptStream, transcriptSink) = AsyncStream.makeStream(
            of: [Turn].self, bufferingPolicy: .bufferingNewest(1))
        self.events = eventStream
        self.statusUpdates = statusStream
        self.transcriptUpdates = transcriptStream
        // Assigned after every stored property has a value, which is when `self` may be used.
        self.eventContinuation = eventSink
        self.statusContinuation = statusSink
        self.transcriptContinuation = transcriptSink
    }

    public var specs: [AgentSpec] { seats.map(\.spec) }

    /// The topic, read and written by a front end. Set through `setTopic` rather than a
    /// plain setter so a running conversation can refuse it the way it refuses attachments.
    public var topic: String { conversation.topic }

    @discardableResult
    public func setTopic(_ value: String) -> Bool {
        guard startedTurns == 0, generationTask == nil else { return false }
        conversation.topic = value
        publishTranscript()
        return true
    }

    /// Start, or start over. What a front end's single Start button means.
    public func startOrRestart() {
        if isRunning || isPaused {
            stop()
        }
        if startedTurns > 0 {
            reset()
        }
        start()
    }

    /// Whether the last thing that happened was a failure, for a front end to display.
    public var lastError: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    /// Source material may only be added before the conversation starts, since it is
    /// context for the discussion rather than a message in it.
    public var canAttachFiles: Bool { startedTurns == 0 && generationTask == nil }

    /// Images are offered only when every seat can see them: a discussion where one
    /// participant cannot see the picture is worse than being told images are unavailable.
    public var allSeatsSupportVision: Bool {
        specs.allSatisfy { $0.visionSupport.allowsImages }
    }
    /// Watch the shared log.
    ///
    /// A callback rather than a stream, because there is more than one watcher — the HTTP API
    /// and the WebTransport server both need to know when the log changes — and an
    /// `AsyncStream` gives its single iterator to whoever takes it first. The second reader
    /// gets nothing at all, silently.
    ///
    /// Returns a token to remove the observer with.
    @discardableResult
    public func observeTranscript(_ body: @escaping ([Turn]) -> Void) -> UUID {
        let id = UUID()
        transcriptObservers[id] = body
        return id
    }

    public func stopObservingTranscript(_ id: UUID) {
        transcriptObservers[id] = nil
    }

    func publishEvent(_ event: TurnEvent) {
        // Fold the event into the live state before handing it on, so a front end that only
        // reads snapshots sees replies being written without having to consume the stream.
        record(event)
        eventContinuation?.yield(event)
        // And to every watcher, for the same reason as the transcript: more than one transport
        // consumes these, and a stream would serve only whichever asked first.
        for observer in eventObservers.values { observer(event) }
    }

    /// Watch tokens, tool calls and notes.
    ///
    /// A callback for the same reason as `observeTranscript`: the HTTP API and the
    /// WebTransport server both forward these, and an `AsyncStream` would give the lot to one
    /// of them and nothing to the other.
    @discardableResult
    public func observeEvents(_ body: @escaping (TurnEvent) -> Void) -> UUID {
        let id = UUID()
        eventObservers[id] = body
        return id
    }

    public func stopObservingEvents(_ id: UUID) {
        eventObservers[id] = nil
    }

    func setStatus(_ status: RunStatus) {
        self.status = status
        statusContinuation?.yield(status)
    }

    func releasePauseGate() {
        let continuation = pauseContinuation
        pauseContinuation = nil
        continuation?.resume()
    }

    func note(_ message: String) {
        notices.append(message)
        if notices.count > 80 { notices.removeFirst(notices.count - 80) }
        noticeContinuation?.yield(notices)
    }
}
