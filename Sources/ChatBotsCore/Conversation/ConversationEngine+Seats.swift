// ChatBotsCore — the seats, their engines and their live progress
//
// Split out of `ConversationEngine.swift`, which held the orchestrator, its turn loop, its
// transcript plumbing, its context bookkeeping and its research mode in one 1613-line file.
// A seat's checkpoint and backend are chosen here, and the per-seat state a front end draws
// is folded here; nothing changed but which file the code lives in.

import Foundation

extension ConversationEngine {

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
    struct LiveState {
        var isGenerating = false
        var text = ""
        var reasoning = ""
        var activity: String?
        var toolLog: [String] = []
        var stats: TurnStats?
    }

    /// Fold one engine event into the live state.
    func record(_ event: TurnEvent) {
        switch event {
        case .turnStarted(let agentID, _):
            liveState[agentID] = LiveState(isGenerating: true)
        case .token(let agentID, let text):
            liveState[agentID, default: LiveState()].text += text
        case .reasoning(let agentID, let text):
            liveState[agentID, default: LiveState()].reasoning += text
        case .toolCall(let agentID, let name, let query):
            liveState[agentID, default: LiveState()].activity = "\(name)(\(UTF8Text.prefix(query, 60)))"
        case .toolResult(let agentID, _, let summary, _, _):
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
        let previous = seats[index].spec
        let changedModel = previous.modelID != spec.modelID
        let changedEndpoint = previous.openAI != spec.openAI
        seats[index].spec = spec
        if changedModel {
            rebuildMLXEngine(at: index)
        }
        if changedEndpoint {
            rebuildOpenAIEngine(at: index)
        }
        if let engine = seatEngine(for: spec.id) {
            Task {
                await engine.setDisplayName(spec.displayName)
                await engine.setPersona(spec.personaID)
                await engine.setThinking(spec.thinking)
            }
        }
    }

    /// Give a seat a new OpenAI engine for its new endpoint, when it has one.
    ///
    /// A seat's `spec` is immutable for an engine's life and an engine's cached client holds a
    /// session for one endpoint — one connection pool and one TLS state. Writing a new base URL
    /// or key into the seat's spec and reporting it in the snapshot, without this, is what made
    /// the API sheet show an endpoint the requests were not going to. A seat that has no OpenAI
    /// engine keeps none, so an MLX-only seat still falls back to its MLX engine.
    private func rebuildOpenAIEngine(at index: Int) {
        guard seats[index].openAI != nil else { return }
        seats[index].openAI = configuration.makeOpenAIEngine(seats[index].spec)
        modelLoadFailures[seats[index].spec.id] = nil
    }

    /// Whether a turn is in flight — generating, preparing, or parked by a pause.
    ///
    /// Not the same question as `isRunning`, which a paused room answers "no": the checkpoint cannot
    /// be changed while a parked turn is waiting to resume on the engine it started with.
    public var hasTurnInFlight: Bool { generationTask != nil }

    /// Point one seat at a different checkpoint, and answer whether that changed anything.
    ///
    /// Refused while a turn is in flight: the engine being replaced is the one that turn is generating
    /// on — or will resume on — and releasing its weights underneath it would fail the turn for a
    /// reason the user did not ask for. A caller that wants to switch says so while the room is
    /// stopped.
    @discardableResult
    public func setModel(_ modelID: String, for agentID: String) -> Bool {
        let resolved = ModelCatalog.resolve(modelID)
        guard !resolved.isEmpty else { return false }
        guard !hasTurnInFlight else { return false }
        guard let index = seats.firstIndex(where: { $0.spec.id == agentID }) else { return false }
        var spec = seats[index].spec
        guard spec.modelID != resolved else { return false }
        spec.modelID = resolved
        // From the identifier, as a seat built from scratch does: the label is what a front end shows
        // for the seat, and leaving the old one would name the model that is no longer running.
        spec.modelShortName = ModelNames.shortName(resolved)
        updateSeat(spec)
        return true
    }

    /// Give a seat a new MLX engine for its new checkpoint, and let the old one go.
    ///
    /// The old engine is unloaded rather than merely replaced: it holds the whole checkpoint in
    /// memory, and two of these — 3 GB each, or 6 GB for the larger one — do not fit on the machines
    /// this app targets. `unload` is what releases the weights; the engine object itself is
    /// unreachable from here afterwards, so nothing else can hold it alive.
    private func rebuildMLXEngine(at index: Int) {
        let old = seats[index].mlx
        seats[index].mlx = configuration.makeMLXEngine(seats[index].spec)
        // The new checkpoint has not been tried yet, so the old model's failure is not this one's.
        // What it does get is a clean slate: the next load either clears it or sets its own.
        modelLoadFailures[seats[index].spec.id] = nil
        Task { await old.unload() }
    }

    /// Record whether a seat's model loaded, for the health check.
    ///
    /// Called from the load group next to the notice, so the room and the endpoint cannot disagree
    /// about what happened.
    func recordModelLoad(of seatID: String, failure: String?) {
        modelLoadFailures[seatID] = failure
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
}
