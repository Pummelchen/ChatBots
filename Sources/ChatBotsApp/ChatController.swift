// ChatBotsApp — view state bridging the actor-based conversation to SwiftUI
//
// The conversation engine is a @MainActor class that exposes AsyncStreams. This
// controller is the single place that consumes those streams and turns them into
// plain @Published values the views can bind to. Keeping that translation here means
// the views stay declarative and the engine stays testable without SwiftUI.

import AppKit
import ChatBotsCore
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
    /// True once generation has finished but text is still being revealed. The live view is
    /// held until this clears, so nothing appears to be cut off mid-sentence, and the next
    /// speaker waits for it — which is what makes the hand-off look immediate rather than
    /// leaving a pause while the previous seat catches up.
    @Published public var isAwaitingDisplayClear = false
    /// True while the moderator is editing this seat's name.
    @Published public var isRenaming = false
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
    /// "Agent 1" and so on: the seat's kind, used when a name is cleared.
    public nonisolated let seatKind: String

    init(spec: AgentSpec, seatIndex: Int) {
        self.spec = spec
        self.id = spec.id
        self.seatIndex = seatIndex
        self.seatKind = spec.id
    }

    func beginTurn() {
        isGenerating = true
        // A new turn replaces the previous one's display, so any "wait for the tail to finish
        // appearing" state from that turn is over. Without this, a turn that started before the
        // previous turn's pacer had drained would be ended by `reveal` on its first tick, which
        // is reachable now that a turn's end is observed rather than never reported at all.
        isAwaitingDisplayClear = false
        liveText = ""
        liveBlocks = []
        liveReasoning = ""
        toolLog = []
        activity = "thinking…"
        scrollSignal += 1
    }

    /// Generation has stopped. The display may not have caught up.
    func finishGenerating() {
        isGenerating = false
        isAwaitingDisplayClear = true
    }

    /// Everything generated has now been shown.
    func endTurn() {
        isGenerating = false
        isAwaitingDisplayClear = false
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

    @Published public var topic: String {
        didSet { if !isApplyingRemoteState { saveSettings() } }
    }
    @Published public var moderatorDraft: String {
        didSet { saveSettings() }
    }
    /// Streams the models' thinking blocks into the panes (a view concern; whether the
    /// model thinks at all is per-seat, see `AgentSpec.thinking`).
    @Published public var showReasoning: Bool {
        didSet { if !isApplyingRemoteState { saveSettings() } }
    }

    // MARK: Outputs

    @Published public private(set) var turns: [Turn] = []
    @Published public private(set) var status: RunStatus = .idle
    @Published public private(set) var notices: [String] = []
    @Published public var errorBanner: String?
    /// What the engine has kept, drawn as a list the moderator can reopen.
    ///
    /// Held here rather than fetched by the view so the list survives the sheet being closed and
    /// reopened, and so there is one place that knows when it is out of date.
    @Published public internal(set) var savedConversations: [SavedConversationSummary] = []
    /// Which mode the room is in. The engine's to decide, like everything else about the
    /// conversation, so the app shows what it is told rather than what it last asked for.
    @Published public private(set) var mode: DiscussionMode = .entertainment
    /// How far a research session has got, or nil outside research.
    @Published public private(set) var research: APISnapshot.ResearchStatus?
    /// The finished report, with its markdown, when there is one.
    @Published public private(set) var report: APISnapshot.ReportSummary?
    /// The line-ups and scenarios the engine ships, for the picker.
    @Published public internal(set) var rosters: [Roster] = []
    @Published public internal(set) var scenarios: [Scenario] = []
    /// The audience's verdicts, by contribution id, and the scorecard. Both come from the
    /// engine so the app and the browser cannot show different scores.
    @Published public private(set) var votes: [String: String] = [:]
    @Published public private(set) var audience: [APISnapshot.AudienceEntry] = []

    public let panes: [AgentPaneState]

    /// Bumped when the single-thread view should follow the newest message. One signal for
    /// the whole thread rather than one per seat, because the thread is a single list.
    @Published public internal(set) var threadScrollSignal = 0

    // MARK: Internals

    /// The connection to the engine. The app is a client of one now rather than containing
    /// it, so this is the only way anything reaches a model.
    public internal(set) var client: WebTransportEngineClient?
    /// What the engine says it is doing, so the interface can show a failure rather than
    /// nothing happening.
    @Published public internal(set) var engineConnection: String?
    var pumpTasks: [Task<Void, Never>] = []
    /// True while a state from the engine is being applied, so the property observers do not
    /// mistake it for a user edit and save it back.
    private var isApplyingRemoteState = false
    /// The last state the engine reported. Read-only properties answer from here, so there is
    /// one source for what the engine currently thinks.
    /// The last whole state from the engine, for the views that show something the controller
    /// does not republish field by field.
    public private(set) var lastSnapshot: APISnapshot?

    /// Snapshots actually applied. A poll reads it before its request and again after, so a
    /// snapshot cannot be applied out of order behind one that landed while it was in flight.
    var appliedSnapshotCount = 0

    /// Called whenever anything the user set changes, so it can be written to disk.
    var onSettingsChanged: (() -> Void)?
    /// The moderator's identity as restored from settings, pushed to the engine when the
    /// connection comes up. The engine is a separate process and does not read the app's
    /// preferences, so somebody has to tell it.
    public internal(set) var restoredModerator = ModeratorIdentity()

    /// Documents restored from settings that the engine has not been given.
    ///
    /// Held so a relaunch cannot destroy them. The engine is a separate, freshly started
    /// process holding nothing, and the app cannot hand a stored document to it: a document the
    /// moderator added was read *by the engine*, and what this side saved is the engine's
    /// description of it, never the file. So they are shown and saved until the moderator
    /// re-adds the file, and `setAttachments` says which ones the models cannot currently see.
    var restoredAttachments: [AttachedDocument] = []
    /// The restore notice currently in the banner, so refreshing it never eats another message.
    var attachmentRestoreNotice: String?

    public init(
        specs: [AgentSpec] = AgentSpec.SeatRoster.specs(),
        initialTopic: String = ChatController.defaultTopic,
        initialModeratorDraft: String = "",
        initialShowReasoning: Bool = true,
        initialModerator: ModeratorIdentity = ModeratorIdentity()
    ) {
        self.topic = initialTopic
        self.moderatorDraft = initialModeratorDraft
        self.showReasoning = initialShowReasoning
        self.restoredModerator = initialModerator

        // No engine is built here any more. The seats are drawn from the given specs so the
        // window has something to show before the connection is up, and the engine's own
        // state replaces them as soon as the first snapshot arrives.
        self.panes = specs.enumerated().map {
            AgentPaneState(spec: $0.element, seatIndex: $0.offset)
        }
        startFlushLoop()
        observeSeatSettings()
    }

    /// Take a whole state from the engine.
    ///
    /// Deliberately does not touch the pane's visible text: the pacer owns that, and
    /// overwriting it mid-reveal would make the reply jump. Everything else is the engine's
    /// to decide.
    func apply(_ snapshot: APISnapshot) {
        // A snapshot the engine produced before one already applied must not be applied: it
        // would regress the transcript and the status to an older state. Snapshots reach the
        // controller down two paths — the push feed and the replies to commands and the poll —
        // and the reply path wakes through a task group, so a newer push can be applied first.
        guard !isStale(snapshot) else { return }
        appliedSnapshotCount += 1
        lastSnapshot = snapshot
        reconcileRestoredAttachments(with: snapshot)
        turns = Self.turns(from: snapshot.messages)
        if !snapshot.topic.isEmpty, topic != snapshot.topic {
            isApplyingRemoteState = true
            topic = snapshot.topic
            isApplyingRemoteState = false
        }
        status = RunStatus(
            label: snapshot.status, isRunning: snapshot.isRunning, isPaused: snapshot.isPaused,
            error: snapshot.error)
        notices = snapshot.notices
        if let error = snapshot.error { errorBanner = error }
        // Mode, progress and the report all come from the engine rather than being tracked
        // here, so switching mode in the browser moves the app too.
        mode = DiscussionMode(rawValue: snapshot.mode) ?? mode
        research = snapshot.research
        report = snapshot.report
        votes = Self.votes(from: snapshot.votes)
        audience = snapshot.audience

        // Seat settings are the engine's, so a change made in another front end appears here.
        applySeats(from: snapshot)
    }

    /// Whether `snapshot` was produced before the newest state already applied.
    ///
    /// The engine stamps every snapshot with a monotonic revision, and that orders two produced
    /// inside the same second — which its wall clock cannot, since `serverTime` is ISO-8601 to
    /// the second — and keeps ordering them when the system clock moves backwards. A snapshot
    /// from an engine that does not send a revision falls back to its clock, which is all there
    /// was before. The message log deliberately is *not* used as a tie-break: `reset`,
    /// `newConversation` and loading a kept conversation all legitimately shrink it, so a
    /// shorter log is a newer state as often as an older one.
    private func isStale(_ snapshot: APISnapshot) -> Bool {
        guard let lastSnapshot else { return false }
        return snapshot.isOlder(than: lastSnapshot)
    }

    // MARK: - Pacing

    /// Buffered token deltas for one seat.
    struct Delta {
        var text = ""
        var reasoning = ""
        var activity: String?
    }

    var pending: [String: Delta] = [:]
    private var flushTask: Task<Void, Never>?
    /// Reveals queued text at a steady rate instead of in model-sized bursts.
    var pacer = StreamPacerPool()
    /// Per-seat rate sampling, used to match the reveal rate to this hardware.
    var rateSamples: [String: (characters: Int, since: Date)] = [:]

    /// True while a seat still has generated text waiting to be shown. A turn is not
    /// visually finished until this is false, which is what lets the next speaker begin
    /// the moment this one stops appearing to type.
    public func isDisplaying(agentID: String) -> Bool {
        pacer.backlog(agentID: agentID) > 0
    }

    private func startFlushLoop() {
        // A steady 50 ms tick: fast enough that revealed text looks continuous, slow enough
        // that the transcript is not re-laid-out more than twenty times a second.
        let tick = 0.05
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.flush()
                self.reveal(elapsed: tick)
            }
        }
    }

    /// Release whatever text is due, and finish any turn whose text has now been fully
    /// shown.
    func reveal(elapsed: Double) {
        for release in pacer.drain(elapsed: elapsed) {
            guard let pane = pane(release.agentID) else { continue }
            switch release.channel {
            case StreamPacerPool.Channel.answer:
                pane.liveText += release.text
                // Keeps the per-frame layout cost proportional to one paragraph.
                pane.moveCompletedBlocksToBuffer()
            case StreamPacerPool.Channel.reasoning:
                pane.liveReasoning += release.text
            }
        }
        for pane in panes where pane.isAwaitingDisplayClear && !isDisplaying(agentID: pane.id) {
            pane.endTurn()
        }
    }

    func pane(_ agentID: String) -> AgentPaneState? {
        panes.first { $0.spec.id == agentID }
    }

    // MARK: - Settings

    /// Save the user's settings.
    ///
    /// Called from `didSet` on each bound property and from every seat change, so there is
    /// no "unsaved" state to lose. The store coalesces bursts.
    func saveSettings() {
        // Skip while the panes are still being built, when observation may fire early.
        guard isFullyInitialised else { return }
        onSettingsChanged?()
    }

    private var isFullyInitialised = false

    /// Seat settings live inside `AgentPaneState.spec`, which is mutated by the persona,
    /// thinking and backend controls rather than by a binding, so they are watched
    /// explicitly.
    private func observeSeatSettings() {
        for pane in panes {
            pane.$spec
                .dropFirst()
                .sink { [weak self] _ in self?.saveSettings() }
                .store(in: &settingsObservers)
        }
        isFullyInitialised = true
    }

    private var settingsObservers: [AnyCancellable] = []

    /// Current settings, for the store to write.
    var currentSeats: [AgentSpec] { panes.map(\.spec) }

    /// Flush any pending write, for termination.
    public func saveSettingsNow() {
        onSettingsChanged?()
    }

    deinit {
        flushTask?.cancel()
    }

    // MARK: - Derived

    public var canStart: Bool {
        !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !status.isActive
    }

    public var isRunning: Bool { status.isActive }

    /// Steering turns accepted but not yet read by any model.
    ///
    /// Judged from the transcript: a steering turn with no answer after it is still pending.
    /// The engine used to answer this directly; over the client the log is the only thing
    /// both ends share, and it is enough to answer the question.
    public var pendingSteeringIDs: Set<UUID> {
        var pending: Set<UUID> = []
        var answered = false
        for turn in turns.reversed() {
            if turn.kind == .chat { answered = true }
            if turn.kind == .steering, !answered { pending.insert(turn.id) }
        }
        return pending
    }

    /// Which seat a speaker id belongs to, or nil for the moderator and app turns.
    public func seatIndex(forSpeaker speakerID: String?) -> Int? {
        guard let speakerID else { return nil }
        return panes.first { $0.id == speakerID }?.seatIndex
    }

    /// How full the context is, for the footer. Includes the compaction threshold so the
    /// bar can show where the log will be condensed rather than the reader having to guess.
    public var contextUsage: (tokens: Int, window: Int, fraction: Double) {
        guard let snapshot = lastSnapshot else { return (0, 0, 0) }
        return (snapshot.contextTokens, snapshot.contextWindow, snapshot.contextFraction)
    }
}
