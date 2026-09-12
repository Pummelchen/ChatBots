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

    private var eventContinuation: AsyncStream<TurnEvent>.Continuation!
    private var statusContinuation: AsyncStream<RunStatus>.Continuation!
    private var transcriptContinuation: AsyncStream<[Turn]>.Continuation!
    /// Where the conversation is kept between runs. Set by whoever creates the engine, so the
    /// engine itself does not decide where files live.
    public var conversationStore: ConversationStore?
    /// Identifies this conversation across saves, so growing it updates one record rather than
    /// adding another every turn.
    public private(set) var conversationID = UUID()
    /// When it began, for the record.
    private var conversationStartedAt = Date.now

    /// Everyone watching the log. See `observeTranscript`.
    private var transcriptObservers: [UUID: ([Turn]) -> Void] = [:]
    /// Everyone watching the output. See `observeEvents`.
    private var eventObservers: [UUID: (TurnEvent) -> Void] = [:]

    /// Every token, tool call and note, in order.
    /// Every token, tool call and note, in order.
    ///
    /// Built once, in `init`, and never rebuilt. It was a `lazy var` whose closure assigned
    /// the continuation, which meant *reading the property a second time replaced the
    /// continuation* — so a second consumer silently took the stream away from the first, and
    /// the first received nothing more. Two subscribers are exactly what this is for: the
    /// HTTP API forwards these events to its clients while the engine uses them itself.
    public private(set) var events: AsyncStream<TurnEvent>

    /// The run status as it changes. Built once; see `events` for why.
    public private(set) var statusUpdates: AsyncStream<RunStatus>

    /// The shared log whenever it changes. Built once; see `events` for why.
    public private(set) var transcriptUpdates: AsyncStream<[Turn]>

    // MARK: Internals

    public var configuration: Configuration
    private var seats: [Seat]

    private var seatCursor = 0
    /// Who the human moderator is, for the room and for the transcript.
    public var moderator = ModeratorIdentity()
    private var turnsCompleted = 0
    /// Prompt tokens the last completed turn actually sent, and how much of that was
    /// transcript text — together they let the next prompt be predicted rather than
    /// guessed. Set from `TurnStats.promptTokens`.
    private var measuredPromptTokens: Int?
    /// The name the seat currently speaking goes by, so its reply is logged under the name
    /// it was spoken under rather than the seat's internal id. Captured per turn, which is
    /// what lets a rename change future turns without rewriting history.
    private var currentSpeakerName: String?
    private var lastMeasuredDialogueTokens = 0
    /// Turns that have begun generating (unlike `turnsCompleted`, counts the current one).
    public private(set) var startedTurns = 0
    private var generationTask: Task<Void, Never>?
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    public init(seats: [Seat], configuration: Configuration = .init()) {
        precondition(!seats.isEmpty, "a conversation needs at least one seat")
        self.seats = seats
        self.configuration = configuration

        // Built here rather than lazily. A `lazy var` whose closure assigns the continuation
        // hands the stream to whoever reads the property last, so a second subscriber takes
        // it from the first — which is how the API's token feed silently starved the engine's
        // own transcript feed. Built once in `init`, every reader gets the same stream, which
        // is what makes it safe for the API and the engine to both listen.
        let (eventStream, eventSink) = AsyncStream.makeStream(
            of: TurnEvent.self, bufferingPolicy: .unbounded)
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

    /// What each seat is doing right now, for the live panes.
    public struct LiveSeat: Sendable {
        public var id: String
        public var isGenerating: Bool
        public var text: String
        public var reasoning: String
        public var activity: String?
        public var toolLog: [String]
        public var stats: TurnStats?
    }

    /// The live view is held while the answer is still being revealed, so a front end shows
    /// the whole reply rather than cutting it off when generation reports finished.
    public var liveSeats: [LiveSeat] {
        seats.map { seat in
            let live = liveState[seat.spec.id] ?? LiveState()
            return LiveSeat(
                id: seat.spec.id,
                isGenerating: live.isGenerating,
                text: live.text,
                reasoning: live.reasoning,
                activity: live.activity,
                toolLog: live.toolLog,
                stats: live.stats
            )
        }
    }

    /// Per-seat progress, rebuilt from the engine's own events.
    ///
    /// It lives here rather than in each front end so that "what is this seat doing right
    /// now" has one answer. The SwiftUI app and the web page read the same value, which is
    /// what let the GUI's own copy of this be removed.
    private struct LiveState {
        var isGenerating = false
        var text = ""
        var reasoning = ""
        var activity: String?
        var toolLog: [String] = []
        var stats: TurnStats?
    }

    private var liveState: [String: LiveState] = [:]

    /// Fold one engine event into the live state.
    private func record(_ event: TurnEvent) {
        switch event {
        case .turnStarted(let agentID, _):
            liveState[agentID] = LiveState(isGenerating: true)
        case .token(let agentID, let text):
            liveState[agentID, default: LiveState()].text += text
        case .reasoning(let agentID, let text):
            liveState[agentID, default: LiveState()].reasoning += text
        case .toolCall(let agentID, let name, let query):
            liveState[agentID, default: LiveState()].activity = "\(name)(\(UTF8Text.prefix(query, 60)))"
        case .toolResult(let agentID, _, let summary, _):
            liveState[agentID, default: LiveState()].toolLog.append(summary)
            liveState[agentID]?.activity = nil
        case .toolFailure(let agentID, _, let message):
            liveState[agentID, default: LiveState()].toolLog.append("failed: \(message)")
            liveState[agentID]?.activity = nil
        case .turnFinished(let agentID, _, let stats):
            liveState[agentID]?.isGenerating = false
            liveState[agentID]?.stats = stats
            liveState[agentID]?.activity = nil
        case .turnFailed(let agentID, let message):
            liveState[agentID]?.isGenerating = false
            liveState[agentID]?.activity = "failed: \(message)"
        }
    }

    /// Replace one seat's configuration and tell its engine, so a change applies from that
    /// seat's next turn rather than only being recorded.
    public func updateSeat(_ spec: AgentSpec) {
        guard let index = seats.firstIndex(where: { $0.spec.id == spec.id }) else { return }
        seats[index].spec = spec
        if let engine = seatEngine(for: spec.id) {
            Task {
                await engine.setDisplayName(spec.displayName)
                await engine.setPersona(spec.personaID)
                await engine.setThinking(spec.thinking)
            }
        }
    }

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
    /// Begin a research session, if the mode calls for one.
    ///
    /// Started once per conversation and then carried, so restarting does not reset a budget
    /// the moderator already spent — a session that reset its clock on every Start would never
    /// reach its end condition.
    private func beginResearchSessionIfNeeded() {
        guard !seats.isEmpty, seats[0].spec.mode == .research else { return }
        guard conversation.research == nil else { return }
        let budget = configuration.researchBudget
            ?? ResearchBudget.preset(.standard)
        conversation.research = ResearchSession(budget: budget)
        note("Research budget: \(budget.depth.label) — \(budget.depth.summary), "
            + "\(budget.maxRounds) contributions, \(budget.maxSearches) searches.")
    }

    public func start(topic: String? = nil) {
        beginResearchSessionIfNeeded()
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
    /// True while a conversation is under way, paused included — a paused conversation is
    /// still one that has started.
    public var isRunning: Bool { status.isActive }
    public var isPaused: Bool { status.isPaused }

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

    /// Condense the log on demand.
    ///
    /// Runs whether or not the threshold has been reached, which is what makes it usable as
    /// a "make room now" control before a long prompt of your own.
    public func compactNow() {
        guard generationTask == nil else {
            note("Finish or stop the current turn before compacting.")
            return
        }
        guard let seat = seats.first else { return }
        Task { [weak self] in
            guard let self else { return }
            let compacted = await self.compactIfNeeded(using: seat, force: true)
            if !compacted { self.note("Nothing to condense yet.") }
        }
    }


    /// Forget the conversation, keeping the configuration.
    ///
    /// The rule is what a conversation *accumulated* goes and what the moderator *chose* stays:
    /// the topic, the seats and the attachments are settings, and the transcript, the social
    /// state, the investigation's budget, its report and the audience's votes all belong to the
    /// conversation being cleared.
    ///
    /// Getting this wrong was not cosmetic. `research` surviving a reset meant a finished
    /// investigation kept its latched stop reason, so **Clear then Start did nothing at all**:
    /// the new run found a session that was already finished and wrote a second report without
    /// a single turn. A stale report also stayed on screen over an empty transcript.
    public func reset() {
        stop()
        conversation.turns = []
        conversation.conflict = ConflictState()
        conversation.research = nil
        conversation.report = nil
        conversation.votes = []
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
            speakerName: moderator.speakerName,
            kind: .steering,
            content: trimmed
        )

        if status.isActive {
            queuedSteering.append(turn)
            publishTranscript()  // visible immediately, marked pending by the UI
            note("Queued — \(nextSpeakerID()) will pick it up at the next turn boundary.")
        } else {
            // Into the log and *not* into the queue. The queue is "not yet delivered to the
            // models"; this turn is in the log they are about to be given, so queueing it as well
            // delivered it twice — once now and once when the queue was drained at the first turn
            // boundary. The duplicate reached the prompt, where it read as the moderator saying
            // the same thing twice.
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

    /// Who speaks next.
    ///
    /// Entertainment rotates, and rotation is the right answer there: a show where the app
    /// decides who is worth hearing is a show being edited. Research does not rotate. The
    /// moderator has a job — deciding what the investigation still owes and who is equipped to
    /// supply it — and a rotation means a question needing the Statistician hears from whoever
    /// is next instead, which is how a session spends its budget and still does not answer.
    ///
    /// The direction is logged as its own kind of turn, so it reaches the seat in the prompt
    /// *and* is visible in the transcript. A decision that steers the conversation but is
    /// invisible in the record would make the investigation impossible to review afterwards.
    private func nextSeat() -> Seat {
        let rotation = seats[seatCursor % seats.count]
        guard conversation.research != nil else { return rotation }

        let direction = ResearchReading.read(seats: specs, turns: conversation.turns).direction()
        guard
            let seatID = direction.seatID,
            let directed = seats.first(where: { $0.spec.id == seatID })
        else {
            // Nothing outstanding. Saying so is the honest answer, and it is worth a line:
            // otherwise "the moderator had nothing to direct" and "the moderator is not
            // implemented" look identical from the outside.
            note("Research Moderator: \(direction.reason).")
            return rotation
        }

        note("Research Moderator → \(directed.spec.displayName): \(direction.reason).")
        conversation.turns.append(
            Turn(
                sequence: nextSequence(),
                speakerID: nil,
                speakerName: "Research Moderator",
                kind: .direction,
                content: direction.instruction
            )
        )
        publishTranscript()
        return directed
    }

    /// Write the report that ends a research session.
    ///
    /// The **moderator** writes it, because that is what the role is for: it has read every
    /// contribution and its job is to organise, not to add. If no moderator seat is present —
    /// a two-seat run configured with two analysts — the first seat is asked instead, since a
    /// report is the deliverable and producing none would waste the whole session. The
    /// substitution is noted rather than silent.
    private func writeReport(reason: ResearchStop) async {
        guard let session = conversation.research else { return }

        let moderator =
            seats.first { $0.spec.personaID == AnalystLibrary.moderatorID }
            ?? seats.first
        guard let moderator else { return }
        if moderator.spec.personaID != AnalystLibrary.moderatorID {
            note("No Research Moderator among the seats, so \(moderator.spec.displayName) is writing the report.")
        }

        let transcript = conversation.turns
            .filter { $0.kind == .chat || $0.kind == .tool || $0.kind == .topic }
            .map { turn -> String in
                let who = turn.kind == .tool ? "TOOL" : turn.speakerName
                return "[\(who)] \(turn.content)"
            }
            .joined(separator: "\n\n")

        let prompt = ResearchReporting.synthesisPrompt(
            question: conversation.topic,
            participants: seats.map { $0.spec.displayName },
            stopReason: reason.explanation,
            transcript: transcript)

        note("Writing the report…")
        let text: String
        do {
            text = try await moderator.engine.generate(
                messages: [
                    .init(
                        role: .system,
                        content: "You are the Research Moderator. You organise findings precisely and add none of your own."),
                    .init(role: .user, content: prompt),
                ],
                tools: [], onToolCall: { _, _ in }, onEvent: { _ in })
        } catch {
            note("The report could not be written: \(error.localizedDescription)")
            return
        }

        let report = ResearchReporting.parse(
            text,
            question: conversation.topic,
            participants: seats.map { $0.spec.displayName },
            stopReason: reason.explanation,
            budgetSummary: "\(session.budget.depth.label) (\(session.budget.depth.summary))",
            rounds: session.rounds,
            searches: session.searches)

        conversation.report = report
        conversation.turns.append(
            Turn(
                sequence: nextSequence(),
                speakerName: "Research Moderator",
                kind: .report,
                content: report.markdown()
            )
        )
        publishTranscript()

        if !report.isLabelled {
            note("The report came back without claim labels, so treat every statement as unverified.")
        }
        if !report.missingSections.isEmpty {
            note("The report did not cover: \(report.missingSections.joined(separator: ", ")).")
        }
        note("Report ready — \(report.labelledStatements) labelled claims.")
    }

    private func runLoop() async {
        while !Task.isCancelled {
            if status.isPaused {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    pauseContinuation = continuation
                }
            }
            if Task.isCancelled { break }

            // A research session stops when its budget says so, and writes its report on the
            // way out. Checked before another turn is planned, so a finished investigation
            // does not spend one more contribution restating what it already concluded.
            if let session = conversation.research, session.isFinished() {
                let reason = session.evaluate()
                note("Research finished — \(reason.explanation)")
                await writeReport(reason: reason)
                setStatus(.limitReached)
                break
            }

            // And it stops when the moderator has nothing left to point at, whether or not the
            // budget would have allowed more. The moderator's own decision criteria say it
            // concludes when the sub-questions are addressed and further work would not move
            // the answer; that is a better reason to stop than a clock, and it is the whole
            // point of having a moderator rather than a timer. Guarded on `rounds > 0` so a
            // session cannot conclude before anyone has spoken.
            if let session = conversation.research, session.rounds > 0,
                !ResearchReading.read(seats: specs, turns: conversation.turns).hasOpenWork
            {
                conversation.research?.finish(.answered)
                let reason = ResearchStop.answered
                note("Research finished — \(reason.explanation)")
                await writeReport(reason: reason)
                setStatus(.limitReached)
                break
            }

            if turnsCompleted >= configuration.maxTurns {
                note(
                    "Turn limit (\(configuration.maxTurns)) reached — steer, raise the limit, or clear."
                )
                setStatus(.limitReached)
                break
            }

            let seat = nextSeat()
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
        // Reclaim context before composing this turn, so the seat that is about to speak
        // is the one whose window is measured and whose style shapes the digest. Only the
        // *automatic* path consults the switch; `compactNow` calls this directly.
        if configuration.autoCompact {
            await compactIfNeeded(using: seat)
        }

        let pending = drainSteering()
        for turn in pending {
            conversation.turns.append(turn)
        }
        if !pending.isEmpty {
            publishTranscript()
        }

        // Built from the engine's live configuration, not the spec captured at
        // construction, so a persona or thinking change made in the UI takes effect here.
        // The source material reaches a seat through two channels: text goes into the
        // prompt, images go to the engine. Both are refreshed each turn so adding a file
        // before the conversation starts is enough.
        await seat.engine.setAttachments(conversation.attachments)
        let liveSpec = await seat.engine.currentSpec
        currentSpeakerName = liveSpec.displayName
        let prompt = PromptBuilder.prompt(
            for: liveSpec,
            others: seats.map(\.spec).filter { $0.id != liveSpec.id },
            conversation: conversation,
            moderator: moderator
        )

        startedTurns += 1
        publishEvent(.turnStarted(agentID: seat.spec.id, prompt: prompt))

        let tools: [any ToolProvider] = seat.spec.webSearchEnabled ? WebToolbox.tools : []
        let engine = seat.engine
        let agentID = seat.spec.id

        do {
            let text = try await engine.generate(
                messages: prompt,
                tools: tools,
                onToolCall: { [weak self] name, argument in
                    await self?.publishEvent(
                        .toolCall(agentID: agentID, name: name, query: argument))
                },
                onEvent: { [weak self] event in
                    await self?.publishEvent(event)
                    await self?.handle(event, from: agentID)
                }
            )
            _ = text  // `.turnFinished` already carried the final text
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            note("\(agentID) error: \(error.localizedDescription)")
            publishEvent(.turnFailed(agentID: agentID, message: error.localizedDescription))
        }
    }

    /// Fold an engine event into the shared log, then forward it to the UI.
    private func handle(_ event: TurnEvent, from agentID: String) {
        switch event {
        case .turnFinished(let id, let text, let stats):
            if stats.promptTokens > 0 {
                measuredPromptTokens = stats.promptTokens
                lastMeasuredDialogueTokens = conversation.dialogueTurns
                    .reduce(0) { $0 + max(1, $1.content.count / 4) }
            }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                note("\(id) produced no text (stop: \(stats.stopReason)).")
            } else {
                let sequence = nextSequence()
                conversation.turns.append(
                    Turn(
                        sequence: sequence,
                        speakerID: id,
                        speakerName: currentSpeakerName ?? id,
                        kind: .chat,
                        content: clean
                    )
                )
                // Read the turn for social signals, so the next speaker reacts to what was
                // actually said rather than to a transcript it has to re-derive. Only in
                // entertainment: a research seat is judged on method and evidence, and
                // importing grudges into it would be the modes sharing a philosophy.
                // The handler is given an id, not the seat, so the mode is looked up here.
                let speakerMode = seats.first { $0.spec.id == id }?.spec.mode ?? .entertainment
                if speakerMode == .research {
                    // A contribution that brought evidence, changed a position or answered a
                    // challenge is progress; one that restated a position is not. A run of
                    // those is what convergence means.
                    let added = ConflictReader.signals(
                        in: clean, from: id, others: seats.map(\.spec.id), addressing: nil
                    ).contains { $0.kind == .newEvidence || $0.kind == .positionChange }
                    let searchesThisTurn = conversation.turns.last {
                        $0.kind == .tool && $0.speakerID == id && $0.sequence > sequence - 4
                    } != nil ? 1 : 0
                    conversation.research?.record(
                        searchCount: searchesThisTurn, addedSomething: added)
                }
                if speakerMode == .entertainment {
                    let everyone = seats.map(\.spec.id)
                    let signals = ConflictReader.signals(
                        in: clean,
                        from: id,
                        others: everyone,
                        // Aimed at whoever spoke last, which is who the message is answering.
                        addressing: conversation.turns.dropLast().last { $0.kind == .chat }?.speakerID
                    )
                    conversation.conflict.apply(
                        signals: signals,
                        from: id,
                        others: everyone,
                        sequence: sequence,
                        summary: ConflictReader.summary(of: clean)
                    )
                }
                publishTranscript()
            }
            publishEvent(event)

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
            publishEvent(event)

        case .toolFailure(let id, let name, let message):
            note("\(id) tool \(name) failed: \(message)")
            publishEvent(event)

        default:
            publishEvent(event)
        }
    }

    // MARK: - Transcript plumbing

    /// Insert turns directly, without running a model.
    ///
    /// For laying out the interface against a realistic conversation — screen captures, and
    /// checking a long reply renders — without waiting for a model to produce one. It is
    /// deliberately not reachable from any route: the API has no endpoint that fabricates a
    /// conversation, so nothing a user can press will put words in a participant's mouth.
    public func seed(_ turns: [Turn]) {
        guard generationTask == nil else { return }
        for turn in turns {
            var copy = turn
            copy.sequence = nextSequence()
            conversation.turns.append(copy)
        }
        publishTranscript()
    }

    /// Set the source material seats should read. Rejected once a conversation is running,
    /// since the material is context for the discussion rather than a message in it.
    @discardableResult
    public func setAttachments(_ documents: [AttachedDocument]) -> Bool {
        // Allowed *before* a conversation starts, and refused once one has. The task is
        // non-nil only while a turn is running, so requiring it to be nil would have made
        // this succeed precisely in the case it is meant to refuse and fail otherwise.
        guard turnsCompleted == 0, generationTask == nil else { return false }
        conversation.attachments = documents
        publishTranscript()
        return true
    }

    /// The research session, for a front end to show progress.
    public var researchSession: ResearchSession? { conversation.research }

    /// The report a finished session produced.
    public func researchReport() -> ResearchReport? { conversation.report }

    /// A status line for the session, or nil outside research.
    public func researchStatus() -> APISnapshot.ResearchStatus? {
        guard let session = conversation.research else { return nil }
        let reason = session.evaluate()
        return APISnapshot.ResearchStatus(
            depth: session.budget.depth.label,
            budgetSummary: session.budget.depth.summary,
            rounds: session.rounds,
            maxRounds: session.budget.maxRounds,
            searches: session.searches,
            maxSearches: session.budget.maxSearches,
            remainingMinutes: Int(session.remaining() / 60),
            statusLine: session.statusLine(),
            isFinished: reason.isFinished,
            stopReason: reason == .running ? nil : reason.explanation)
    }

    /// Switch the whole room between entertainment and research.
    ///
    /// Reseats every persona, because the two libraries are not interchangeable: a seat
    /// holding "The Villain" has no meaning in a research session, and resolving it to a
    /// default silently would leave the picker showing something the seat is not using.
    /// Refused once the conversation has started, since the log was written against the
    /// personas it began with.
    @discardableResult
    public func setMode(_ mode: DiscussionMode) -> Bool {
        guard startedTurns == 0, generationTask == nil else { return false }
        for index in seats.indices {
            seats[index].spec.mode = mode
            if !mode.owns(personaID: seats[index].spec.personaID) {
                seats[index].spec.personaID = mode.defaultPersonaID(forSeat: index)
            }
            let spec = seats[index].spec
            if let engine = seatEngine(for: spec.id) {
                Task { await engine.setPersona(spec.personaID) }
            }
        }
        // A research run needs a session; an entertainment one must not have a budget
        // counting against it.
        if mode == .research {
            conversation.research = ResearchSession(
                budget: configuration.researchBudget ?? .preset(.standard))
        } else {
            conversation.research = nil
        }
        note("Mode set to \(mode.label) — \(mode.summary)")
        publishTranscript()
        return true
    }

    /// Set the research budget before the investigation starts.
    ///
    /// Refused once it is running: the budget is what the session is being measured against,
    /// and changing it midway would make the progress meaningless.
    @discardableResult
    public func setResearchBudget(_ depth: ResearchBudget.Depth) -> Bool {
        guard startedTurns == 0, generationTask == nil else { return false }
        guard seats.contains(where: { $0.spec.mode == .research }) else { return false }
        let budget = ResearchBudget.preset(depth)
        configuration.researchBudget = budget
        conversation.research = ResearchSession(budget: budget)
        note("Research budget set to \(depth.label) — \(depth.summary).")
        return true
    }

    /// The source material currently attached.
    public var attachments: [AttachedDocument] { conversation.attachments }

    /// Rough prompt size and how full the tightest seat's window is.
    ///
    /// Measured from the last prompt a seat actually received, not from the transcript's
    /// own text. That distinction matters: the system prompt, the persona and the opening
    /// brief are rendered into every prompt and account for roughly nine hundred tokens
    /// before a single turn of conversation — enough that estimating from transcript text
    /// alone made the threshold unreachable. The transcript estimate is used only until a
    /// first turn has run.
    public var contextUsage: (tokens: Int, window: Int, fraction: Double) {
        let dialogue = conversation.dialogueTurns.reduce(0) { $0 + max(1, $1.content.count / 4) }
            + PromptBuilder.attachmentCharacters(conversation.attachments) / 4
        // A completed turn's prompt is the closest thing to ground truth available, plus
        // the prompt for the turn being composed now.
        let measured = measuredPromptTokens.map { $0 + dialogue - lastMeasuredDialogueTokens } ?? dialogue
        let tokens = max(dialogue, measured)
        let window = seats.map(\.spec.contextWindow).min() ?? AgentSpec.defaultContextWindow
        let fraction = window > 0 ? Double(tokens) / Double(window) : 0
        return (tokens, window, fraction)
    }

    /// The log the UI should draw: delivered turns plus any not-yet-delivered steering.
    public var displayTurns: [Turn] {
        (conversation.turns + queuedSteering).sorted { $0.sequence < $1.sequence }
    }

    /// Write the opening: the question, and the brief that explains the rules.
    ///
    /// Written once and idempotently, so restarting a stopped conversation does not write a
    /// second brief — and so a conversation *started* by the moderator typing a message still
    /// gets one. The previous version bailed out entirely if the log already held a steering
    /// turn, which meant the "type a message to begin" path had no brief at all: the seats were
    /// given a question and no rules, no roster and no statement of what the conversation was.
    ///
    /// No topic turn is written in that case, because the message that started the conversation
    /// *is* the question; writing both would show it twice, which is the bug this replaced.
    private func seedOpeningTurns() {
        let alreadyAsked = conversation.turns.contains {
            $0.kind == .topic || $0.kind == .steering
        }
        if !alreadyAsked {
            conversation.turns.append(
                Turn(
                    sequence: nextSequence(),
                    speakerName: moderator.speakerName,
                    kind: .topic,
                    content: conversation.topic
                )
            )
        }

        if !conversation.turns.contains(where: { $0.kind == .introduction }) {
            let intro = PromptBuilder.introduction(
                specs: specs, topic: conversation.topic, moderator: moderator)
            conversation.turns.append(
                Turn(
                    sequence: nextSequence(),
                    speakerName: "System",
                    kind: .introduction,
                    content: intro
                )
            )
        }
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

    /// Condense older turns when the log approaches the context window.
    ///
    /// This replaces dropping the oldest entries, which silently destroyed the beginning of
    /// the discussion. A digest keeps the thread's conclusions, positions and open
    /// questions at a fraction of the tokens.
    ///
    /// Returns true when compaction ran, so the caller can tell that the transcript has
    /// been rewritten underneath it.
    @discardableResult
    func compactIfNeeded(using seat: Seat, force: Bool = false) async -> Bool {
        _ = force  // an explicit call always runs; see `compactNow`

        let spec = await seat.engine.currentSpec
        let window = spec.contextWindow > 0 ? spec.contextWindow : AgentSpec.defaultContextWindow
        let usage = contextUsage
        let tokens = usage.tokens
        let fraction = Double(tokens) / Double(window)
        guard force || fraction >= configuration.compactThreshold else { return false }

        let dialogue = conversation.turns.filter { $0.kind != .tool }
        guard dialogue.count > configuration.compactKeepRecentTurns + 2 else {
            // Too little to condense usefully — the window is simply small for this topic.
            note(
                "Prompt is \(tokens) tokens of a \(window)-token window but there is not enough history to condense yet.")
            return false
        }

        let pinned = Set(
            dialogue.filter { $0.kind == .topic || $0.kind == .introduction || $0.kind == .summary }
                .map(\.id))
        let older = dialogue.dropLast(configuration.compactKeepRecentTurns).filter { !pinned.contains($0.id) }
        guard !older.isEmpty else { return false }

        let previous = conversation.summaryTurn?.content
        let prompt = PromptBuilder.compactionPrompt(
            for: spec, turns: Array(older), topic: conversation.topic, previousSummary: previous)

        note(
            "Context \(Int(fraction * 100))% full — condensing \(older.count) older entries with \(spec.id).")

        let digest: String
        do {
            digest = try await seat.engine.compact(
                prompt: prompt, maxTokens: configuration.compactSummaryTokens)
        } catch {
            note("Compaction with \(spec.id) failed: \(error.localizedDescription)")
            return false
        }
        guard !digest.isEmpty else {
            note("Compaction with \(spec.id) returned nothing; the log is unchanged.")
            return false
        }

        // Replace: drop whatever was condensed, drop any previous summary (it is folded
        // into the new one), and keep the rest in order.
        let removedIDs = Set(older.map(\.id))
        var replacement = conversation.turns.filter { turn in
            turn.kind != .summary && !removedIDs.contains(turn.id)
        }
        let condensed = Turn(
            sequence: 0,
            speakerName: "Condensed",
            kind: .summary,
            content: digest
        )
        // The digest belongs *after* the opening, not in front of it: the topic and brief
        // are the frame the digest summarises, and a model reading the digest first would
        // meet the discussion's conclusions before its subject.
        let pinnedPrefixCount = replacement.prefix { $0.kind == .topic || $0.kind == .introduction }.count
        replacement.insert(condensed, at: pinnedPrefixCount)
        // Renumber so ordering stays obvious and unique.
        replacement = replacement.enumerated().map { index, turn in
            var copy = turn
            copy.sequence = index + 1
            return copy
        }
        conversation.turns = replacement
        publishTranscript()
        note(
            "Condensed \(older.count) entries into \(digest.count / 4) tokens; context is now about \(contextUsage.tokens) tokens.")
        return true
    }

    private func publishTranscript() {
        transcriptContinuation?.yield(displayTurns)
        let turns = displayTurns
        for observer in transcriptObservers.values { observer(turns) }
        saveConversation()
    }

    /// Keep the conversation on disk.
    ///
    /// Called whenever the log changes, which is once per turn — often enough that nothing
    /// meaningful is lost if the app is closed, and rare enough that it is not writing during
    /// generation. The whole conversation is written each time rather than appended to,
    /// because a record that can be rewritten is a record that cannot be left half-appended.
    private func saveConversation() {
        guard let store = conversationStore, !conversation.turns.isEmpty else { return }
        let record = StoredConversation(
            id: conversationID,
            conversation: conversation,
            seats: specs,
            startedAt: conversationStartedAt,
            endReason: status.isActive ? nil : status.label)
        _ = store.save(record)
    }

    /// Replace this conversation with a saved one.
    ///
    /// The seats are *not* taken from the record: who is in the room is a current choice, and
    /// a conversation read from a file should not change it. What comes back is the topic and
    /// the transcript — the conversation itself.
    @discardableResult
    public func load(_ record: StoredConversation) -> Bool {
        guard !isRunning else { return false }
        reset()
        conversation = record.conversation()
        // A loaded conversation keeps the identity it was saved under, so continuing it
        // updates that record rather than starting a second one.
        conversationID = record.id
        conversationStartedAt = record.startedAt
        publishTranscript()
        setStatus(.idle)
        return true
    }

    // MARK: - The audience

    /// Cast, change or withdraw the audience's verdict on one contribution.
    ///
    /// Returns false for a turn that is not a contribution: voting on the topic, on a tool
    /// result or on the moderator's own assignment would put a score against something nobody
    /// argued, and the scorecard is meant to be a judgement of the argument.
    @discardableResult
    public func castVote(turnID: UUID, verdict: AudienceVote.Verdict?) -> Bool {
        guard let turn = conversation.turns.first(where: { $0.id == turnID }),
            turn.kind == .chat, let seatID = turn.speakerID
        else { return false }
        if let verdict {
            conversation.audience.cast(verdict, for: turnID, seatID: seatID)
        } else {
            conversation.audience.withdraw(turnID: turnID)
        }
        // Written immediately rather than at the next turn: a vote is the audience's work, and
        // losing it because the window was closed before the next contribution would be the
        // same class of loss as losing the transcript.
        saveConversation()
        publishTranscript()
        return true
    }

    public func clearVotes() {
        conversation.audience.clear()
        saveConversation()
        publishTranscript()
    }

    /// The audience's scorecard.
    public var audience: AudienceScorecard { conversation.audience }

    /// Start a new conversation, with a new identity on disk.
    public func startNewConversation() {
        reset()
        conversationID = UUID()
        conversationStartedAt = .now
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

    private func publishEvent(_ event: TurnEvent) {
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

    /// The tools this app knows how to offer.
    ///
    /// Listed regardless of whether a key is configured, deliberately. Whether a seat is
    /// offered tools at all is the seat's own `webSearchEnabled`, and that has to stay a
    /// property of the seat rather than of the machine — otherwise the same conversation
    /// behaves differently on a clone with a `.secrets.env` and one without, which is exactly
    /// the kind of hidden condition that is hard to reason about. Whether a search can
    /// actually run is decided where it matters: the opening brief says search is unavailable
    /// when there is no key, and the client refuses with a readable reason rather than sending
    /// an empty token.
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
