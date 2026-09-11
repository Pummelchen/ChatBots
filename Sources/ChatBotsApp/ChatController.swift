// ChatBotsApp — view state bridging the actor-based conversation to SwiftUI
//
// The conversation engine is a @MainActor class that exposes AsyncStreams. This
// controller is the single place that consumes those streams and turns them into
// plain @Published values the views can bind to. Keeping that translation here means
// the views stay declarative and the engine stays testable without SwiftUI.

import AppKit
import ChatBotsCore
import Foundation
import SwiftUI

/// Live state of one seat's pane.
@MainActor
public final class AgentPaneState: ObservableObject, Identifiable {
    @Published public var spec: AgentSpec
    @Published public var engineState: EngineState = .idle
    @Published public var isGenerating = false
    /// The still-growing final paragraph of the answer. Re-laying out a single
    /// *growing* `Text` on every update is what puts SwiftUI on a layout treadmill —
    /// at streaming rates the main thread never leaves the run-loop observer that
    /// flushes view updates. Only this tail changes per frame.
    @Published public var liveText = ""
    /// Paragraphs of the current answer that are already complete. They are appended
    /// once and never change again, so SwiftUI keeps them and their layout.
    @Published public var liveBlocks: [String] = []
    /// `<think>` text accumulated during the current turn (shown collapsed).
    @Published public var liveReasoning = ""
    /// Short line under the header: "searching…", token rate, last stats.
    @Published public var activity: String = ""
    @Published public var lastStats: TurnStats?
    @Published public var toolLog: [String] = []
    /// Bumped when the transcript should jump to the newest entry. A counter rather than
    /// a flag, so a redraw with an unchanged value never re-scrolls.
    @Published public var scrollSignal = 0

    /// Stable identity. `spec.id` is captured once because the spec is now mutable
    /// (the thinking level changes from the pane) and this must stay nonisolated.
    public nonisolated let id: String
    /// Position in the conversation, driving the seat's colour and symbol. Stable for the
    /// life of the pane, and independent of how many seats exist.
    public nonisolated let seatIndex: Int

    init(spec: AgentSpec, seatIndex: Int) {
        self.spec = spec
        self.id = spec.id
        self.seatIndex = seatIndex
    }

    func beginTurn() {
        isGenerating = true
        liveText = ""
        liveBlocks = []
        liveReasoning = ""
        toolLog = []
        activity = "thinking…"
        scrollSignal += 1
    }

    func endTurn() {
        isGenerating = false
        liveText = ""
        liveBlocks = []
        liveReasoning = ""
        activity = ""
        scrollSignal += 1
    }

    /// Move every complete paragraph of the streaming answer out of the tail.
    ///
    /// A block is "complete" once a blank line follows it, so it can be frozen. Text
    /// after the last blank line is still being written and stays in `liveText`.
    func moveCompletedBlocksToBuffer() {
        guard liveText.contains("\n\n") else { return }
        let parts = liveText.components(separatedBy: "\n\n")
        guard parts.count > 1 else { return }
        let complete = parts.dropLast().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !complete.isEmpty else { return }
        liveBlocks.append(contentsOf: complete)
        liveText = parts.last ?? ""
    }

    var statusText: String {
        switch engineState {
        case .idle: isGenerating ? "starting…" : "not loaded"
        case .loading(let progress): "loading \(Int(progress * 100))%"
        case .ready: isGenerating ? (activity.isEmpty ? "generating…" : activity) : "ready"
        case .failed(let message): "failed: \(message)"
        }
    }
}

@MainActor
public final class ChatController: ObservableObject {

    // MARK: Configuration

    public static let defaultTopic = "Why are eggs not round?"

    // MARK: Inputs

    @Published public var topic: String = ChatController.defaultTopic
    @Published public var moderatorDraft: String = ""
    /// Streams the models' thinking blocks into the panes (a view concern; whether the
    /// model thinks at all is per-seat, see `AgentSpec.reasoning`).
    @Published public var showReasoning: Bool = true

    // MARK: Outputs

    @Published public private(set) var turns: [Turn] = []
    @Published public private(set) var status: RunStatus = .idle
    @Published public private(set) var notices: [String] = []
    @Published public var errorBanner: String?

    public let panes: [AgentPaneState]

    /// Bumped when the single-thread view should follow the newest message. One signal for
    /// the whole thread rather than one per seat, because the thread is a single list.
    @Published public private(set) var threadScrollSignal = 0

    // MARK: Internals

    public let engine: ConversationEngine
    private var pumpTasks: [Task<Void, Never>] = []

    public init(
        specs: [AgentSpec] = AgentSpec.SeatRoster.specs(),
        configuration: ConversationEngine.Configuration = .init()
    ) {
        let registry = WebToolbox.makeRegistry()
        let panes = specs.enumerated().map { AgentPaneState(spec: $0.element, seatIndex: $0.offset) }

        // One engine per seat = one independent model instance per seat. Swapping in a
        // different checkpoint later is a change to `specs`, nothing else.
        let seats = zip(specs, panes).map { spec, pane in
            // Both backends are constructed up front: an MLX seat keeps its weights loaded
            // even while the OpenAI backend is selected, and vice versa.
            let stateHandler: @Sendable (EngineState) -> Void = { state in
                Task { @MainActor in
                    pane.engineState = state
                }
            }
            return ConversationEngine.Seat(
                spec: spec,
                mlx: MLXEngine(spec: spec, toolRegistry: registry, onStateChange: stateHandler),
                openAI: OpenAIResponsesEngine(spec: spec, onStateChange: stateHandler)
            )
        }

        self.panes = panes
        self.engine = ConversationEngine(seats: seats, configuration: configuration)
        startPumps()
        startFlushLoop()
    }

    deinit {
        flushTask?.cancel()
    }

    // MARK: - Stream consumption

    private func startPumps() {
        pumpTasks.append(
            Task { [weak self] in
                guard let stream = self?.engine.transcriptUpdates else { return }
                for await turns in stream {
                    guard let self else { return }
                    self.turns = turns
                }
            }
        )

        pumpTasks.append(
            Task { [weak self] in
                guard let stream = self?.engine.statusUpdates else { return }
                for await status in stream {
                    guard let self else { return }
                    self.status = status
                    if !status.isActive {
                        for pane in self.panes { pane.endTurn() }
                    }
                }
            }
        )

        pumpTasks.append(
            Task { [weak self] in
                guard let stream = self?.engine.noticeUpdates else { return }
                for await notices in stream {
                    guard let self else { return }
                    self.notices = notices
                }
            }
        )

        pumpTasks.append(
            Task { [weak self] in
                guard let stream = self?.engine.events else { return }
                for await event in stream {
                    guard let self else { return }
                    self.apply(event)
                }
            }
        )
    }

    private func apply(_ event: TurnEvent) {
        switch event {
        // Streaming text is buffered and published on a timer. Republishing a growing
        // string (and re-laying-out the transcript) for every token is what makes a
        // streaming UI stutter; a turn finishes in well under a frame's worth of tokens
        // at these rates either way.
        case .token(let agentID, let text):
            pending[agentID, default: Delta()].text += text

        case .reasoning(let agentID, let text):
            pending[agentID, default: Delta()].reasoning += text

        case .toolCall(let agentID, let name, let query):
            pending[agentID, default: Delta()].activity = "\(name)(\(query.prefix(48)))…"

        case .toolResult(let agentID, let name, let summary, _):
            pending[agentID, default: Delta()].activity = "reading results…"
            pane(agentID)?.toolLog.append("\(name) → \(summary)")

        case .toolFailure(let agentID, let name, let message):
            pane(agentID)?.toolLog.append("\(name) failed: \(message)")

        case .turnStarted(let agentID, _):
            flush()  // the previous turn's tail must land before its row is cleared
            threadScrollSignal += 1
            for pane in panes {
                if pane.spec.id == agentID {
                    pane.beginTurn()
                } else if pane.isGenerating {
                    pane.endTurn()
                }
            }

        case .turnFinished(let agentID, _, let stats):
            flush()
            threadScrollSignal += 1
            if let pane = pane(agentID) {
                pane.lastStats = stats
                pane.endTurn()
            }

        case .turnFailed(_, let message):
            flush()
            errorBanner = message
        }
    }

    /// Buffered token deltas for one seat.
    private struct Delta {
        var text = ""
        var reasoning = ""
        var activity: String?
    }

    private var pending: [String: Delta] = [:]
    private var flushTask: Task<Void, Never>?

    /// Applies buffered deltas to the panes, in one published update per seat.
    private func flush() {
        guard !pending.isEmpty else { return }
        let buffered = pending
        pending.removeAll(keepingCapacity: true)

        for (agentID, delta) in buffered {
            guard let pane = pane(agentID) else { continue }
            if !delta.reasoning.isEmpty { pane.liveReasoning += delta.reasoning }
            if !delta.text.isEmpty {
                pane.liveText += delta.text
                // Keeps the per-frame layout cost proportional to one paragraph rather
                // than to the whole answer.
                pane.moveCompletedBlocksToBuffer()
            }
            if let activity = delta.activity { pane.activity = activity }
        }
    }

    private func startFlushLoop() {
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.flush()
            }
        }
    }

    private func pane(_ agentID: String) -> AgentPaneState? {
        panes.first { $0.spec.id == agentID }
    }

    // MARK: - Controls

    public func startOrRestart() {
        errorBanner = nil
        if status.isActive {
            engine.stop()
        }
        if !turns.isEmpty {
            engine.reset()
        }
        engine.start(topic: topic)
    }

    public func togglePause() {
        if status.isPaused {
            engine.resume()
        } else {
            engine.pause()
        }
    }

    public func stop() {
        engine.stop()
        for pane in panes { pane.endTurn() }
    }

    public func reset() {
        engine.reset()
        errorBanner = nil
    }

    public func sendModeratorMessage() {
        let text = moderatorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        engine.steer(text)
        moderatorDraft = ""
    }

    /// Change one seat's thinking level. Applies from its next turn.
    public func setThinking(_ mode: ThinkingMode, for agentID: String) {
        guard var spec = engine.specs.first(where: { $0.id == agentID }) else { return }
        spec.thinking = mode
        if let seat = engine.allSeats.first(where: { $0.spec.id == agentID }) as? MLXEngine {
            Task { await seat.setThinking(mode) }
        }
        if let pane = pane(agentID) {
            pane.spec = spec
        }
    }

    /// The whole conversation as plain text, for Edit ▸ Copy Conversation.
    ///
    /// On-screen selection is not available in the panes (see `AppKitScrollView`), so
    /// this is the supported way to lift the transcript out of the app.
    public func transcriptAsText() -> String {
        var lines: [String] = ["# \(topic)", ""]
        for turn in engine.displayTurns {
            switch turn.kind {
            case .topic, .steering:
                lines.append("**\(turn.speakerName):** \(turn.content)")
            case .introduction:
                continue
            case .summary:
                lines.append("> **[condensed earlier discussion]** \(turn.content)")
            case .tool:
                lines.append("> tool → \(turn.content)")
            case .chat:
                lines.append("**\(turn.speakerName):** \(turn.content)")
            }
            lines.append("")
        }
        if let stats = panes.compactMap(\.lastStats).first {
            lines.append("— \(Format.rate(stats))")
        }
        return lines.joined(separator: "\n")
    }

    public func copyConversation() {
        let text = transcriptAsText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Change one seat's style. Applies from its next turn.
    public func setPersona(_ personaID: String, for agentID: String) {
        guard var spec = engine.specs.first(where: { $0.id == agentID }) else { return }
        spec.personaID = personaID
        if let seat = engine.allSeats.first(where: { $0.spec.id == agentID }) as? MLXEngine {
            Task { await seat.setPersona(personaID) }
        }
        if let pane = pane(agentID) {
            pane.spec = spec
        }
    }

    /// Point one seat at a backend. Only offered before the conversation starts, because
    /// switching mid-thread would change a participant's identity part-way through.
    public func setBackend(_ backend: AgentSpec.Backend, for agentID: String) {
        engine.setBackend(backend, for: agentID)
        guard var spec = engine.specs.first(where: { $0.id == agentID }) else { return }
        spec.backend = backend
        pane(agentID)?.spec = spec
    }

    /// Point one seat at a different server or model id.
    public func setEndpoint(_ endpoint: OpenAIEndpoint, for agentID: String) {
        engine.setEndpoint(endpoint, for: agentID)
        guard var spec = engine.specs.first(where: { $0.id == agentID }) else { return }
        spec.openAI = endpoint
        pane(agentID)?.spec = spec
    }

    /// Push every seat's configured endpoint into its engine.
    ///
    /// Called whenever the endpoint settings change and once at launch, so a seat is ready
    /// before it is asked for a turn.
    func applyAPIEndpoints(_ store: APIEndpointStore) {
        for (index, pane) in panes.enumerated() {
            engine.setEndpoint(store.endpoint(forSeat: index), for: pane.id)
        }
    }

    /// Route every seat through the API, or back to the local models.
    ///
    /// The point of the API backend is that local weights need not be involved at all, so
    /// this is a single switch rather than one per seat.
    func useAPIForAllSeats(_ useAPI: Bool, store: APIEndpointStore) {
        for pane in panes {
            setBackend(useAPI ? .openAIResponses : .mlx, for: pane.id)
        }
        applyAPIEndpoints(store)
    }

    /// True when no seat is using the local MLX models.
    public var isCloudOnly: Bool {
        !panes.isEmpty && panes.allSatisfy { $0.spec.backend == .openAIResponses }
    }

    public func warmUp(_ agentID: String) {
        errorBanner = nil
        guard let seatEngine = engine.seatEngine(for: agentID) else { return }
        Task {
            do {
                try await seatEngine.load()
            } catch {
                await MainActor.run { self.errorBanner = error.localizedDescription }
            }
        }
    }

    // MARK: - Derived

    public var canStart: Bool {
        !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !status.isActive
    }

    public var isRunning: Bool { status.isActive }

    /// Steering turns accepted but not yet read by any model.
    public var pendingSteeringIDs: Set<UUID> {
        Set(engine.queuedSteering.map(\.id))
    }

    /// Which seat a speaker id belongs to, or nil for the moderator and app turns.
    public func seatIndex(forSpeaker speakerID: String?) -> Int? {
        guard let speakerID else { return nil }
        return panes.first { $0.id == speakerID }?.seatIndex
    }

    public var contextEstimate: Int {
        turns.reduce(0) { $0 + max(1, $1.content.count / 4) }
    }

    /// How full the context is, for the footer. Includes the compaction threshold so the
    /// bar can show where the log will be condensed rather than the reader having to guess.
    public var contextUsage: (tokens: Int, window: Int, fraction: Double) {
        engine.contextUsage
    }

    /// Where the log gets condensed, for display.
    public var compactThreshold: Double { engine.configuration.compactThreshold }

    /// Condense the log now, rather than waiting for the threshold.
    public func compactNow() {
        errorBanner = nil
        engine.compactNow()
    }
}
