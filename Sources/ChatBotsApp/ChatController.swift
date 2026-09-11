// ChatBotsApp — view state bridging the actor-based conversation to SwiftUI
//
// The conversation engine is a @MainActor class that exposes AsyncStreams. This
// controller is the single place that consumes those streams and turns them into
// plain @Published values the views can bind to. Keeping that translation here means
// the views stay declarative and the engine stays testable without SwiftUI.

import ChatBotsCore
import Foundation
import SwiftUI

/// Live state of one seat's pane.
@MainActor
public final class AgentPaneState: ObservableObject, Identifiable {
    public let spec: AgentSpec
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

    public nonisolated var id: String { spec.id }

    init(spec: AgentSpec) {
        self.spec = spec
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

    // MARK: Internals

    public let engine: ConversationEngine
    private var pumpTasks: [Task<Void, Never>] = []

    public init(
        specs: [AgentSpec] = [.seatA(), .seatB()],
        configuration: ConversationEngine.Configuration = .init()
    ) {
        let registry = WebToolbox.makeRegistry()
        let panes = specs.map { AgentPaneState(spec: $0) }

        // One engine per seat = one independent model instance per seat. Swapping in a
        // different checkpoint later is a change to `specs`, nothing else.
        let seats = zip(specs, panes).map { spec, pane in
            ConversationEngine.Seat(
                spec: spec,
                engine: MLXEngine(spec: spec, toolRegistry: registry) { state in
                    Task { @MainActor in
                        pane.engineState = state
                    }
                }
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
            for pane in panes {
                if pane.spec.id == agentID {
                    pane.beginTurn()
                } else if pane.isGenerating {
                    pane.endTurn()
                }
            }

        case .turnFinished(let agentID, _, let stats):
            flush()
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

    public var contextEstimate: Int {
        turns.reduce(0) { $0 + max(1, $1.content.count / 4) }
    }
}
