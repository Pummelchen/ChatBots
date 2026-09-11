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
        /// Approximate prompt-token ceiling. Oldest chatter is dropped above it.
        public var softContextLimit: Int = 40_000

        public init() {}
    }

    /// One seat: its configuration plus one engine per backend.
    ///
    /// Both engines are held even though only one is used at a time, so a seat can switch
    /// backend without losing the loaded MLX weights or re-resolving the endpoint.
    public struct Seat: Sendable {
        public var spec: AgentSpec
        public let mlx: (any LLMEngine)?
        public let openAI: (any LLMEngine)?

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

        /// The engine the spec currently selects.
        public var engine: any LLMEngine {
            switch spec.backend {
            case .mlx: mlx ?? openAI!
            case .openAIResponses: openAI ?? mlx!
            }
        }
    }

    // MARK: Observable state

    public private(set) var conversation = Conversation(topic: "")
    public private(set) var status: RunStatus = .idle
    /// Steering accepted but not yet appended to the shared log.
    public private(set) var queuedSteering: [Turn] = []
    /// Non-fatal notices, newest last. The UI drains these into a running commentary.
    public private(set) var notices: [String] = []
    private var noticeContinuation: AsyncStream<[String]>.Continuation?

    /// Notices as they happen.
    public private(set) lazy var noticeUpdates: AsyncStream<[String]> = {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.noticeContinuation = continuation
        }
    }()

    // MARK: Streams

    private var eventContinuation: AsyncStream<TurnEvent>.Continuation?
    private var statusContinuation: AsyncStream<RunStatus>.Continuation?
    private var transcriptContinuation: AsyncStream<[Turn]>.Continuation?

    /// Every token, tool call and note, in order.
    public private(set) lazy var events: AsyncStream<TurnEvent> = {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            self.eventContinuation = continuation
        }
    }()

    public private(set) lazy var statusUpdates: AsyncStream<RunStatus> = {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.statusContinuation = continuation
        }
    }()

    public private(set) lazy var transcriptUpdates: AsyncStream<[Turn]> = {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.transcriptContinuation = continuation
        }
    }()

    // MARK: Internals

    public let configuration: Configuration
    private var seats: [Seat]

    private var seatCursor = 0
    private var turnsCompleted = 0
    /// Turns that have begun generating (unlike `turnsCompleted`, counts the current one).
    public private(set) var startedTurns = 0
    private var generationTask: Task<Void, Never>?
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    public init(seats: [Seat], configuration: Configuration = .init()) {
        precondition(!seats.isEmpty, "a conversation needs at least one seat")
        self.seats = seats
        self.configuration = configuration
    }

    public var specs: [AgentSpec] { seats.map(\.spec) }

    /// Every seat, in speaking order.
    public var allSeats: [Seat] { seats }

    /// The engine behind a seat. Used by the UI for warm-up and diagnostics; the turn
    /// loop itself goes through `runTurn` so it can tag events with the speaker.
    public func seatEngine(for agentID: String) -> (any LLMEngine)? {
        seats.first { $0.spec.id == agentID }?.engine
    }

    /// The MLX engine for a seat, regardless of which backend is selected. The UI warms
    /// weights through this.
    public func mlxEngine(for agentID: String) -> (any LLMEngine)? {
        seats.first { $0.spec.id == agentID }?.mlx
    }

    /// Point a seat at a backend. Takes effect on its next turn.
    public func setBackend(_ backend: AgentSpec.Backend, for agentID: String) {
        guard let index = seats.firstIndex(where: { $0.spec.id == agentID }) else { return }
        seats[index].spec.backend = backend
    }

    /// Change a seat's endpoint. Takes effect on its next turn.
    public func setEndpoint(_ endpoint: OpenAIEndpoint, for agentID: String) {
        guard let index = seats.firstIndex(where: { $0.spec.id == agentID }) else { return }
        seats[index].spec.openAI = endpoint
    }

    public var isLoopRunning: Bool { generationTask != nil }

    /// Await the current loop. Used by headless callers and tests to observe the
    /// conversation without polling.
    public func waitUntilFinished() async {
        await generationTask?.value
    }

    // MARK: - Commands

    public func send(_ command: EngineCommand) {
        switch command {
        case .start: start()
        case .pause: pause()
        case .resume: resume()
        case .stop: stop()
        case .steer(let text): steer(text)
        case .reset: reset()
        }
    }

    /// Begin (or restart after a stop) with the given topic. Every seat is loaded
    /// first, so the first turn is not also a model download.
    public func start(topic: String? = nil) {
        if let topic {
            conversation.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !conversation.topic.isEmpty else {
            setStatus(.failed(ChatBotsError.emptyTopic.localizedDescription))
            return
        }
        guard generationTask == nil else { return }

        seedOpeningTurns()
        setStatus(.preparing)

        let seats = self.seats
        generationTask = Task { [weak self] in
            // Load all seats concurrently — they are independent model instances.
            await withTaskGroup(of: Void.self) { group in
                for seat in seats {
                    group.addTask {
                        do {
                            try await seat.engine.load()
                        } catch {
                            await self?.note(
                                "\(seat.spec.id) failed to load: \(error.localizedDescription)")
                        }
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            await self.runLoop()
        }
    }

    /// Pause between turns. A turn already generating is allowed to finish.
    public func pause() {
        guard generationTask != nil else { return }
        guard !status.isPaused else { return }
        setStatus(.paused)
    }

    public func resume() {
        guard generationTask != nil else { return }
        guard status.isPaused else { return }
        let continuation = pauseContinuation
        pauseContinuation = nil
        setStatus(.running(turn: turnsCompleted + 1))
        continuation?.resume()
    }

    /// Stop the loop. Loaded weights stay resident so restarting is instant.
    public func stop() {
        generationTask?.cancel()
        generationTask = nil
        releasePauseGate()
        setStatus(.stopped)
    }

    public func reset() {
        stop()
        conversation.turns = []
        queuedSteering = []
        notices = []
        noticeContinuation?.yield([])
        turnsCompleted = 0
        startedTurns = 0
        seatCursor = 0
        publishTranscript()
        setStatus(.idle)
        note("Conversation cleared.")
    }

    /// Inject a human message into the shared log.
    ///
    /// Mid-turn, the text is queued and appended once, at the next turn boundary, so
    /// the next speaker sees it. Idle, it is appended immediately and the loop starts.
    public func steer(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let turn = Turn(
            sequence: nextSequence(),
            speakerName: "Moderator",
            kind: .steering,
            content: trimmed
        )

        if status.isActive {
            queuedSteering.append(turn)
            publishTranscript()  // visible immediately, marked pending by the UI
            note("Queued — \(nextSpeakerID()) will pick it up at the next turn boundary.")
        } else {
            queuedSteering.append(turn)
            conversation.turns.append(turn)
            publishTranscript()
            if generationTask == nil, status != .stopped {
                // Steering an untouched conversation is how you start it: the message
                // becomes the topic, so the opening brief is generated around it.
                if conversation.topic.isEmpty {
                    conversation.topic = trimmed
                }
                start()
            } else if status.isPaused {
                note("Appended to the log. Press Resume to let the models answer it.")
            }
        }
    }

    // MARK: - Turn loop

    private func runLoop() async {
        while !Task.isCancelled {
            if status.isPaused {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    pauseContinuation = continuation
                }
            }
            if Task.isCancelled { break }

            if turnsCompleted >= configuration.maxTurns {
                note(
                    "Turn limit (\(configuration.maxTurns)) reached — steer, raise the limit, or clear."
                )
                setStatus(.limitReached)
                break
            }

            let seat = seats[seatCursor % seats.count]
            setStatus(.running(turn: turnsCompleted + 1))
            await runTurn(seat: seat)
            if Task.isCancelled { break }

            seatCursor += 1
            turnsCompleted += 1

            if configuration.pace > .zero {
                try? await Task.sleep(for: configuration.pace)
            }
        }

        generationTask = nil
        if status.isActive {
            setStatus(.stopped)
        }
    }

    private func runTurn(seat: Seat) async {
        // Deliver anything the moderator typed since the last turn. These enter the
        // shared log here — once — which is why mid-turn steering can never be
        // duplicated or shown to only one seat.
        let pending = drainSteering()
        for turn in pending {
            conversation.turns.append(turn)
        }
        if !pending.isEmpty {
            publishTranscript()
        }

        // Built from the engine's live configuration, not the spec captured at
        // construction, so a persona or thinking change made in the UI takes effect here.
        let liveSpec = await seat.engine.currentSpec
        let prompt = PromptBuilder.prompt(
            for: liveSpec,
            others: seats.map(\.spec).filter { $0.id != liveSpec.id },
            conversation: conversation
        )

        startedTurns += 1
        publish(.turnStarted(agentID: seat.spec.id, prompt: prompt))

        let tools: [any ToolProvider] = seat.spec.webSearchEnabled ? WebToolbox.tools : []
        let engine = seat.engine
        let agentID = seat.spec.id

        do {
            let text = try await engine.generate(
                messages: prompt,
                tools: tools,
                onToolCall: { [weak self] name, argument in
                    await self?.publish(
                        .toolCall(agentID: agentID, name: name, query: argument))
                },
                onEvent: { [weak self] event in
                    await self?.handle(event, from: agentID)
                }
            )
            _ = text  // `.turnFinished` already carried the final text
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            note("\(agentID) error: \(error.localizedDescription)")
            publish(.turnFailed(agentID: agentID, message: error.localizedDescription))
        }
    }

    /// Fold an engine event into the shared log, then forward it to the UI.
    private func handle(_ event: TurnEvent, from agentID: String) {
        switch event {
        case .turnFinished(let id, let text, let stats):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                note("\(id) produced no text (stop: \(stats.stopReason)).")
            } else {
                conversation.turns.append(
                    Turn(
                        sequence: nextSequence(),
                        speakerID: id,
                        speakerName: id,
                        kind: .chat,
                        content: clean
                    )
                )
                trimIfNeeded()
                publishTranscript()
            }
            publish(event)

        case .toolResult(let id, let name, let summary, let detail):
            conversation.turns.append(
                Turn(
                    sequence: nextSequence(),
                    speakerID: id,
                    speakerName: id,
                    kind: .tool,
                    content: "\(name): \(summary)",
                    toolDetail: detail
                )
            )
            publishTranscript()
            publish(event)

        case .toolFailure(let id, let name, let message):
            note("\(id) tool \(name) failed: \(message)")
            publish(event)

        default:
            publish(event)
        }
    }

    // MARK: - Transcript plumbing

    /// The log the UI should draw: delivered turns plus any not-yet-delivered steering.
    public var displayTurns: [Turn] {
        (conversation.turns + queuedSteering).sorted { $0.sequence < $1.sequence }
    }

    private func seedOpeningTurns() {
        guard !conversation.turns.contains(where: { $0.kind == .steering }) else { return }
        guard !conversation.turns.contains(where: { $0.kind == .topic }) else { return }
        let topicTurn = Turn(
            sequence: nextSequence(),
            speakerName: "Moderator",
            kind: .topic,
            content: conversation.topic
        )
        conversation.turns.append(topicTurn)

        let intro = PromptBuilder.introduction(specs: specs, topic: conversation.topic)
        conversation.turns.append(
            Turn(
                sequence: nextSequence(),
                speakerName: "System",
                kind: .introduction,
                content: intro
            )
        )
        publishTranscript()
    }

    private func nextSequence() -> Int {
        let delivered = conversation.turns.map(\.sequence).max() ?? 0
        let queued = queuedSteering.map(\.sequence).max() ?? 0
        return max(delivered, queued) + 1
    }

    private func nextSpeakerID() -> String {
        seats[seatCursor % seats.count].spec.id
    }

    private func drainSteering() -> [Turn] {
        let pending = queuedSteering
        queuedSteering = []
        return pending
    }

    /// Drop the oldest chatter when the shared log approaches the context window.
    /// Topic and introduction are pinned.
    private func trimIfNeeded() {
        let total = conversation.dialogueTurns.reduce(0) { $0 + max(1, $1.content.count / 4) }
        guard total > configuration.softContextLimit else { return }

        var kept: [Turn] = []
        var budget = configuration.softContextLimit / 2
        for turn in conversation.turns.reversed() {
            if turn.kind == .topic || turn.kind == .introduction || turn.kind == .steering {
                kept.append(turn)
                continue
            }
            let cost = max(1, turn.content.count / 4)
            if budget - cost >= 0 {
                budget -= cost
                kept.append(turn)
            }
        }
        let trimmed = Array(kept.reversed())
        if trimmed.count != conversation.turns.count {
            note(
                "Context nearly full — dropped the oldest \(conversation.turns.count - trimmed.count) entries."
            )
            conversation.turns = trimmed
        }
    }

    private func publishTranscript() {
        transcriptContinuation?.yield(displayTurns)
    }

    private func publish(_ event: TurnEvent) {
        eventContinuation?.yield(event)
    }

    private func setStatus(_ status: RunStatus) {
        self.status = status
        statusContinuation?.yield(status)
    }

    private func releasePauseGate() {
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

/// The web tools handed to a seat. One client, shared by every seat.
public enum WebToolbox {
    public static let client = TavilyClient()

    public static let tools: [any ToolProvider] = [
        WebSearchTool(client: client, maxResults: 5),
        FetchPageTool(client: client, maxCharacters: 6_000),
    ]

    /// A registry so an engine can resolve a model's tool call to a live provider.
    public static func makeRegistry() -> ToolRegistry {
        let registry = ToolRegistry()
        for tool in tools { registry.register(tool) }
        return registry
    }
}
