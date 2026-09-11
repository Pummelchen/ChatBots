// ChatBotsApp — view state bridging the actor-based conversation to SwiftUI
//
// The conversation engine is a @MainActor class that exposes AsyncStreams. This
// controller is the single place that consumes those streams and turns them into
// plain @Published values the views can bind to. Keeping that translation here means
// the views stay declarative and the engine stays testable without SwiftUI.

import AppKit
import ChatBotsCore
import Combine
import UniformTypeIdentifiers
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

    public let panes: [AgentPaneState]

    /// Bumped when the single-thread view should follow the newest message. One signal for
    /// the whole thread rather than one per seat, because the thread is a single list.
    @Published public private(set) var threadScrollSignal = 0

    // MARK: Internals

    /// The connection to the engine. The app is a client of one now rather than containing
    /// it, so this is the only way anything reaches a model.
    public private(set) var client: WebTransportEngineClient?
    /// What the engine says it is doing, so the interface can show a failure rather than
    /// nothing happening.
    @Published public private(set) var engineConnection: String?
    private var pumpTasks: [Task<Void, Never>] = []
    /// True while a state from the engine is being applied, so the property observers do not
    /// mistake it for a user edit and save it back.
    private var isApplyingRemoteState = false
    /// The last state the engine reported. Read-only properties answer from here, so there is
    /// one source for what the engine currently thinks.
    private var lastSnapshot: APISnapshot?

    /// Called whenever anything the user set changes, so it can be written to disk.
    var onSettingsChanged: (() -> Void)?

    public init(
        specs: [AgentSpec] = AgentSpec.SeatRoster.specs(),
        configuration: ConversationEngine.Configuration = .init(),
        initialTopic: String = ChatController.defaultTopic,
        initialModeratorDraft: String = "",
        initialShowReasoning: Bool = true
    ) {
        self.topic = initialTopic
        self.moderatorDraft = initialModeratorDraft
        self.showReasoning = initialShowReasoning

        // No engine is built here any more. The seats are drawn from the given specs so the
        // window has something to show before the connection is up, and the engine's own
        // state replaces them as soon as the first snapshot arrives.
        self.panes = specs.enumerated().map {
            AgentPaneState(spec: $0.element, seatIndex: $0.offset)
        }
        startFlushLoop()
        observeSeatSettings()
    }

    // MARK: - Connecting

    /// Attach to an engine and start drawing from it.
    ///
    /// Called once the supervisor reports an engine answering. Everything the interface shows
    /// comes from here: the transcript, the status, the seat settings, the statistics and the
    /// streamed output.
    public func connect(host: String = "127.0.0.1", port: UInt16) async {
        disconnect()

        var configuration = WebTransportEngineClient.Configuration()
        configuration.host = host
        configuration.port = port
        let client = WebTransportEngineClient(configuration: configuration)
        self.client = client

        // The event stream delivers states and output fragments; it is started before the
        // first request so nothing that happens in between is missed.
        var lastError: String?
        for attempt in 0..<8 {
            do {
                try await client.connect()
                lastError = nil
                break
            } catch {
                lastError = error.localizedDescription
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        guard client.isConnected else {
            engineConnection = lastError ?? "Could not reach the engine."
            return
        }
        engineConnection = nil

        // The current state first, so the interface is correct before any event arrives.
        if let snapshot = try? await client.state() {
            apply(snapshot)
        }
        startPumps()

        // A safety net, not the primary path.
        //
        // Pushed states should arrive whenever the log changes, and they are what keeps the
        // transcript live. But a push that silently fails leaves a window that looks
        // connected and never updates — the worst kind of failure, because nothing is
        // obviously wrong. Polling is cheap here (one small request a second on loopback) and
        // it turns that into a slow refresh rather than a frozen window.
        pumpTasks.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    if let snapshot = try? await client.state() {
                        self.apply(snapshot)
                    }
                    // A reader that stopped is why the window would otherwise never update.
                    if let error = client.readerError {
                        self.engineConnection = "Live updates stopped: \(error)"
                    }
                }
            }
        )
    }

    /// Stop drawing from the engine. The engine itself is the supervisor's business.
    public func disconnect() {
        for task in pumpTasks { task.cancel() }
        pumpTasks.removeAll()
        if let client {
            Task { await client.disconnect() }
        }
        client = nil
    }

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

    // MARK: - Stream consumption

    private func startPumps() {
        // Two pumps, because the engine sends two shapes of thing: a whole state whenever
        // something changes, and fragments of output as a model writes.
        //
        // The state is authoritative and slow-moving; the fragments are fast and partial. The
        // transcript, the statistics and the seat settings come from states, so they cannot
        // drift. The visible text comes from fragments, so it arrives as it is written rather
        // than in whole answers — which is what the pacing below turns into a smooth reveal.
        pumpTasks.append(
            Task { [weak self] in
                guard let client = self?.client, let events = client.events else { return }
                for await event in events {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .state(let snapshot):
                        self.apply(snapshot)
                    case .output(let delta):
                        self.apply(delta)
                    }
                }
            }
        )
    }

    /// Take a whole state from the engine.
    ///
    /// Deliberately does not touch the pane's visible text: the pacer owns that, and
    /// overwriting it mid-reveal would make the reply jump. Everything else is the engine's
    /// to decide.
    private func apply(_ snapshot: APISnapshot) {
        lastSnapshot = snapshot
        turns = snapshot.messages.map { message in
            Turn(
                id: UUID(uuidString: message.id) ?? UUID(),
                sequence: message.sequence,
                speakerID: message.speakerID,
                speakerName: message.speaker,
                kind: Turn.Kind(rawValue: message.kind) ?? .chat,
                content: message.text,
                toolDetail: message.toolDetail,
                timestamp: message.timestamp)
        }
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

        // Seat settings are the engine's, so a change made in another front end appears here.
        for (index, seat) in snapshot.seats.enumerated() where index < panes.count {
            let pane = panes[index]
            if pane.spec.displayName != seat.name { pane.spec.displayName = seat.name }
            if let personaID = seat.personaID, pane.spec.personaID != personaID {
                pane.spec.personaID = personaID
            }
            if pane.spec.thinking.rawValue != seat.thinking,
                let thinking = ThinkingMode(rawValue: seat.thinking)
            {
                pane.spec.thinking = thinking
            }
            if let backend = AgentSpec.Backend(rawValue: seat.backend) {
                pane.spec.backend = backend
            }
            // Statistics arrive with the live view, and are kept until the next turn starts.
            if let stats = snapshot.live.first(where: { $0.seatID == seat.id })?.stats {
                pane.lastStats = stats
                if let activity = snapshot.live.first(where: { $0.seatID == seat.id })?.activity {
                    pane.activity = activity
                }
            }
            // The client cannot see whether weights are loaded, only whether anything is
            // being produced. `ready` is the honest description of "the engine is answering".
            pane.engineState = .ready
        }
    }

    /// Take one fragment of streamed output.
    ///
    /// Converted into the same event the in-process engine used to deliver, so the pacing,
    /// the block handling and the rate sampling below are unchanged.
    private func apply(_ delta: APISnapshot.OutputDelta) {
        switch delta.kind {
        case "token":
            apply(.token(agentID: delta.agentID, text: delta.text))
        case "reasoning":
            apply(.reasoning(agentID: delta.agentID, text: delta.text))
        case "tool":
            // Sent as one string because a fragment has one text field; split back into the
            // name and the query the display logic expects.
            let parts = delta.text.split(separator: "(", maxSplits: 1)
            apply(
                .toolCall(
                    agentID: delta.agentID,
                    name: String(parts.first ?? ""),
                    query: parts.count > 1
                        ? String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: ")"))
                        : ""))
        case "started":
            // The prompt itself is not sent to a client — it is the engine's rendering of the
            // log and can be enormous. The pacer only needs to know a turn has begun.
            pane(delta.agentID)?.beginTurn()
        default:
            break
        }
    }

    private func apply(_ event: TurnEvent) {
        switch event {
        // Streaming text is buffered and published on a timer. Republishing a growing
        // string (and re-laying-out the transcript) for every token is what makes a
        // streaming UI stutter; a turn finishes in well under a frame's worth of tokens
        // at these rates either way.
        case .token(let agentID, let text):
            // Straight into the pacer: what arrives is queued, not shown. The queue is what
            // absorbs a burst, and what builds the backfill that hides the next turn's wait.
            pacer.enqueue(text, agentID: agentID, channel: StreamPacerPool.Channel.answer)
            sampleGenerationRate(agentID: agentID, characters: text.count)

        case .reasoning(let agentID, let text):
            pacer.enqueue(text, agentID: agentID, channel: StreamPacerPool.Channel.reasoning)
            sampleGenerationRate(agentID: agentID, characters: text.count)

        case .toolCall(let agentID, let name, let query):
            // `prefix` on a String counts grapheme clusters, so a query full of emoji or
            // CJK is shortened without being cut mid-character.
            pending[agentID, default: Delta()].activity = "\(name)(\(UTF8Text.prefix(query, 48)))"

        case .toolResult(let agentID, let name, let summary, _):
            pending[agentID, default: Delta()].activity = "reading results…"
            pane(agentID)?.toolLog.append("\(name) → \(summary)")

        case .toolFailure(let agentID, let name, let message):
            pane(agentID)?.toolLog.append("\(name) failed: \(message)")

        case .turnStarted(let agentID, _):
            flush()  // the previous turn's tail must land before its row is cleared
            threadScrollSignal += 1
            // A new turn on this seat invalidates anything still queued for the last one.
            pacer.clear(agentID: agentID)
            rateSamples[agentID] = nil
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
                // Keep the live text on screen until the pacer has revealed all of it.
                pane.finishGenerating()
                if !isDisplaying(agentID: pane.id) { pane.endTurn() }
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
    /// Reveals queued text at a steady rate instead of in model-sized bursts.
    private let pacer = StreamPacerPool()
    /// Per-seat rate sampling, used to match the reveal rate to this hardware.
    private var rateSamples: [String: (characters: Int, since: Date)] = [:]

    /// True while a seat still has generated text waiting to be shown. A turn is not
    /// visually finished until this is false, which is what lets the next speaker begin
    /// the moment this one stops appearing to type.
    public func isDisplaying(agentID: String) -> Bool {
        pacer.backlog(agentID: agentID) > 0
    }

    /// True while any seat is still revealing text.
    public var isDisplayingAnything: Bool { pacer.isDraining }

    /// Characters per second this conversation's models actually produce, for display.
    public private(set) var measuredGenerationRate: Double = 0

    /// Applies buffered *non-text* deltas to the panes.
    ///
    /// Streamed text no longer passes through here: it goes into the pacer, which releases
    /// it at a steady rate. This only carries the cheap state changes.
    private func flush() {
        guard !pending.isEmpty else { return }
        let buffered = pending
        pending.removeAll(keepingCapacity: true)

        for (agentID, delta) in buffered {
            guard let pane = pane(agentID) else { continue }
            if let activity = delta.activity { pane.activity = activity }
        }
    }

    /// Record how fast this seat is producing characters, so the reveal rate can match it.
    ///
    /// Sampled over a window rather than per token, because per-token arrival is bursty by
    /// nature and would make the reveal rate jitter with it.
    private func sampleGenerationRate(agentID: String, characters: Int) {
        let now = Date.now
        guard var sample = rateSamples[agentID] else {
            rateSamples[agentID] = (characters, now)
            return
        }
        sample.characters += characters
        let elapsed = now.timeIntervalSince(sample.since)
        guard elapsed >= 0.5 else {
            rateSamples[agentID] = sample
            return
        }
        let rate = Double(sample.characters) / elapsed
        rateSamples[agentID] = (0, now)
        measuredGenerationRate = rate
        pacer.observe(agentID: agentID, charactersPerSecond: rate)
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
    private func reveal(elapsed: Double) {
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

    private func pane(_ agentID: String) -> AgentPaneState? {
        panes.first { $0.spec.id == agentID }
    }

    // MARK: - Controls

    public func startOrRestart() {
        errorBanner = nil
        // Stop and reset first when there is something to clear, then start. The engine
        // refuses to start without a topic, so the topic is set before the start rather than
        // being assumed to have arrived already.
        run { client in
            if self.status.isActive { _ = try await client.send(.stop) }
            if !self.turns.isEmpty { _ = try await client.send(.reset) }
            _ = try await client.send(.setTopic(self.topic))
            _ = try await client.send(.start)
        }
    }

    public func togglePause() {
        run { client in
            _ = try await client.send(self.status.isPaused ? .resume : .pause)
        }
    }

    public func stop() {
        run { client in _ = try await client.send(.stop) }
        // An explicit stop means stop: drop whatever is still queued rather than continuing
        // to type it out.
        for pane in panes {
            pacer.clear(agentID: pane.id)
            pane.endTurn()
        }
    }

    public func reset() {
        run { client in _ = try await client.send(.reset) }
        // Drop anything still queued for display: a fresh conversation must not begin by
        // revealing the tail of the one that was just cleared.
        for pane in panes {
            pacer.clear(agentID: pane.id)
            pane.endTurn()
        }
        rateSamples.removeAll()
        errorBanner = nil
    }

    public func sendModeratorMessage() {
        let text = moderatorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        run { client in _ = try await client.send(.steer(text)) }
        moderatorDraft = ""
    }

    /// Change one seat's thinking level. Applies from its next turn.
    public func setThinking(_ mode: ThinkingMode, for agentID: String) {
        run { client in
            _ = try await client.send(
                .updateSeat(.init(seatID: agentID, thinking: mode)))
        }
    }

    /// Send one command and apply whatever the engine answers with.
    ///
    /// Every command answers with the whole state, so the interface never has to guess what
    /// changed — and a refusal arrives the same way as a success, carrying the reason.
    private func run(_ body: @escaping (WebTransportEngineClient) async throws -> Void) {
        guard let client else {
            engineConnection = "Not connected to the engine."
            return
        }
        Task { [weak self] in
            do {
                try await body(client)
            } catch {
                self?.engineConnection = error.localizedDescription
            }
        }
    }

    /// The whole conversation as plain text.
    ///
    /// One shared log walked once, so each message appears exactly once — including the
    /// messages the two seats addressed to each other, which are the conversation rather
    /// than duplicates of it. Timestamps are the format the moderator asked for.
    public func transcriptAsText(exportedAt: Date = Date.now) -> String {
        TranscriptWriter.text(
            topic: topic,
            turns: turns,
            participants: currentSeats,
            exportedAt: exportedAt
        )
    }

    public func copyConversation() {
        let text = transcriptAsText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Save the conversation to a text file, through the standard macOS save dialog.
    ///
    /// Returns the chosen URL, or nil if the moderator cancelled.
    @discardableResult
    public func saveConversation() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Conversation"
        panel.message = "Save the full conversation log as a plain text file."
        panel.prompt = "Save"
        panel.allowedContentTypes = [.plainText]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = TranscriptWriter.suggestedFilename(topic: topic)

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let text = transcriptAsText()
        do {
            // Atomic, so a failure part-way through cannot leave a half-written log where
            // the moderator expects a complete one.
            try Data(text.utf8).write(to: url, options: .atomic)
            errorBanner = nil
            return url
        } catch {
            errorBanner = "Could not save the conversation: \(error.localizedDescription)"
            return nil
        }
    }

    /// Rename a seat.
    ///
    /// The name is what the moderator sees, what the transcript is tagged with, and what
    /// the *models* are told each participant is called. The seat's internal id is
    /// untouched, so the log stays addressable and settings keep loading.
    ///
    /// Rejected while a conversation is running: history already carries the previous name,
    /// and a rename halfway through would leave the shared log attributing turns to
    /// different names for the same participant.
    @discardableResult
    public func renameSeat(_ agentID: String, to name: String) -> Bool {
        guard turns.isEmpty, !isRunning else { return false }
        guard let index = panes.firstIndex(where: { $0.id == agentID }) else { return false }

        let trimmed = String(
            name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        var spec = panes[index].spec
        // An emptied field falls back to the seat's kind rather than leaving it nameless.
        spec.displayName = trimmed.isEmpty ? panes[index].seatKind : trimmed
        panes[index].spec = spec

        run { client in
            _ = try await client.send(
                .updateSeat(.init(seatID: agentID, name: spec.displayName)))
        }
        saveSettings()
        return true
    }

    /// Whether seats may be renamed right now.
    public var canRenameSeats: Bool { turns.isEmpty && !isRunning }

    /// Change one seat's style. Applies from its next turn.
    public func setPersona(_ personaID: String, for agentID: String) {
        // The engine reseats the style and answers with the whole state, so the pane is
        // updated from the reply rather than from a local guess at what changed.
        run { client in
            _ = try await client.send(
                .updateSeat(.init(seatID: agentID, personaID: personaID)))
        }
        pane(agentID)?.spec.personaID = personaID
        saveSettings()
    }

    /// Point one seat at a backend. Only offered before the conversation starts, because
    /// switching mid-thread would change a participant's identity part-way through.
    public func setBackend(_ backend: AgentSpec.Backend, for agentID: String) {
        run { client in
            _ = try await client.send(
                .updateSeat(.init(seatID: agentID, backend: backend)))
        }
        pane(agentID)?.spec.backend = backend
    }

    /// Point one seat at a different server or model id.
    public func setEndpoint(_ endpoint: OpenAIEndpoint, for agentID: String) {
        run { client in
            _ = try await client.send(
                .updateSeat(
                    .init(
                        seatID: agentID, backend: .openAIResponses, baseURL: endpoint.baseURL,
                        apiModel: endpoint.model, apiKey: endpoint.apiKey)))
        }
        pane(agentID)?.spec.openAI = endpoint
    }

    /// Push every seat's configured endpoint into its engine.
    ///
    /// Called whenever the endpoint settings change and once at launch, so a seat is ready
    /// before it is asked for a turn.
    func applyAPIEndpoints(_ store: APIEndpointStore) {
        for (index, pane) in panes.enumerated() where index < panes.count {
            let endpoint = store.endpoint(forSeat: index)
            pane.spec.openAI = endpoint
            run { client in
                _ = try await client.send(
                    .updateSeat(
                        .init(
                            seatID: pane.id, baseURL: endpoint.baseURL,
                            apiModel: endpoint.model, apiKey: endpoint.apiKey)))
            }
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
        // Loading a model is the engine's business and happens on its first turn. A client
        // cannot reach a seat's engine, so there is nothing to warm from here.
        errorBanner = nil
    }

    /// No longer used; kept out of the way while the client settles.
    private func legacyWarmUp(_ agentID: String) {
        Task {
            do {
                try await Task.sleep(for: .milliseconds(1))
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

    // MARK: - Source material

    /// Documents and images the moderator has added.
    /// The files the engine is holding.
    ///
    /// Rebuilt from the state rather than kept separately, so the app and the engine cannot
    /// disagree about what is attached. The extracted text is the engine's and is not sent
    /// back, so a rebuilt document carries its summary and token count but not its body —
    /// which is all the interface shows.
    public var attachments: [AttachedDocument] {
        (lastSnapshot?.attachments ?? []).map { attachment in
            AttachedDocument(
                id: UUID(uuidString: attachment.id) ?? UUID(),
                name: attachment.name,
                kind: DocumentKind(rawValue: attachment.kind) ?? .plainText,
                text: "",
                byteCount: 0,
                pageCount: nil,
                wasTruncated: attachment.wasTruncated,
                imageData: attachment.imageBase64.flatMap { Data(base64Encoded: $0) })
        }
    }

    /// Push the attachment set to the engine.
    ///
    /// Adding a file already happened over the request channel, so this only reconciles the
    /// engine with the app's view — it removes what is gone. Adding here would re-upload.
    private func syncAttachments(_ documents: [AttachedDocument]) {
        let wanted = Set(documents.map(\.id.uuidString))
        let present = Set((lastSnapshot?.attachments ?? []).map(\.id))
        for missing in present.subtracting(wanted) {
            run { client in _ = try await client.send(.removeAttachment(id: missing)) }
        }
    }

    /// True when every seat's model can accept images, which is what decides whether the
    /// image part of the interface is offered at all. A conversation where one participant
    /// cannot see the picture is worse than being told upfront that images are unavailable.
    public var allSeatsSupportVision: Bool {
        panes.allSatisfy { $0.spec.visionSupport.allowsImages }
    }

    /// Which seats cannot see, for the explanation shown when images are unavailable.
    public var seatsWithoutVision: [String] {
        panes.filter { !$0.spec.visionSupport.allowsImages }.map { $0.spec.displayName }
    }

    /// Files may only be added before the conversation starts: the material is context for
    /// the discussion, and adding it midway would leave earlier turns ignorant of it.
    public var canAttachFiles: Bool { turns.isEmpty && !isRunning }

    /// Add files through the standard open panel.
    @discardableResult
    public func attachFiles(allowImages: Bool? = nil) -> Int {
        guard canAttachFiles else {
            errorBanner = "Source material must be added before the conversation starts."
            return 0
        }
        let imagesAllowed = allowImages ?? allSeatsSupportVision

        let panel = NSOpenPanel()
        panel.title = "Add Source Material"
        panel.message = imagesAllowed
            ? "Choose documents or images. Text is extracted so the models can read it."
            : "Choose documents. Images need every seat to support vision."
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        var types: [UTType] = [.plainText, .pdf, .rtf, .html]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        if let word = UTType(filenameExtension: "docx") { types.append(word) }
        if let legacyWord = UTType(filenameExtension: "doc") { types.append(legacyWord) }
        if imagesAllowed { types.append(contentsOf: [.png, .jpeg, .bmp, .gif, .tiff, .heic]) }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK else { return 0 }
        return addFiles(panel.urls, allowImages: imagesAllowed)
    }

    /// Add already-chosen files. Returns how many were accepted.
    @discardableResult
    public func addFiles(_ urls: [URL], allowImages: Bool = true) -> Int {
        let (documents, reportedFailures) = SystemDocumentExtractor.add(urls: urls)
        var failures = reportedFailures
        var accepted = documents.filter { document in
            guard document.kind.isImage else { return true }
            guard allowImages, allSeatsSupportVision else { return false }
            return true
        }
        let rejectedImages = documents.count - accepted.count
        if rejectedImages > 0 {
            failures.append(
                DocumentError.imageNotAllowed.errorDescription ?? "Images are unavailable.")
        }
        guard !accepted.isEmpty else {
            errorBanner = failures.first
            return 0
        }

        // Replace an attachment with the same name and size rather than stacking copies.
        var current = attachments
        for document in accepted {
            if let existing = current.firstIndex(where: {
                $0.name == document.name && $0.byteCount == document.byteCount
            }) {
                current[existing] = document
            } else {
                current.append(document)
            }
        }
        accepted = documents
        syncAttachments(current)
        // A failure alongside successes is reported without hiding the successes.
        errorBanner = failures.isEmpty ? nil : failures.joined(separator: "\n")
        saveSettings()
        return accepted.count
    }

    /// Seed the attached material at launch, before any turn can run.
    @discardableResult
    public func setAttachments(_ documents: [AttachedDocument]) -> Bool {
        // Uploads happen over the request channel, so this reconciles rather than sends: a
        // document the engine has not been told about cannot be added from here, because its
        // text is not on this side of the wire.
        syncAttachments(documents)
        return true
    }

    public func removeAttachment(_ id: UUID) {
        syncAttachments(attachments.filter { $0.id != id })
        saveSettings()
    }

    public func removeAllAttachments() {
        syncAttachments([])
        saveSettings()
    }

    /// Ask for a vision override on a seat, for an API model whose family cannot be
    /// recognised from its id.
    public func setVisionOverride(_ agentID: String, _ support: VisionSupport?) {
        guard var spec = panes.first(where: { $0.id == agentID })?.spec else { return }
        spec.visionOverride = support
        pane(agentID)?.spec = spec
        saveSettings()
    }

    /// Where the log gets condensed, for display.
    public var compactThreshold: Double { lastSnapshot?.compactThreshold ?? 0.7 }

    /// Condense the log now, rather than waiting for the threshold.
    public func compactNow() {
        errorBanner = nil
        run { client in _ = try await client.send(.compact) }
    }
}
