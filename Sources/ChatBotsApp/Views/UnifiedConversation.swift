// ChatBotsApp — the single-thread window mode
//
// One conversation, newest at the bottom: each seat's messages are attributed and
// tinted by who said them, the way a messaging app renders a group chat. This is the
// alternative to the split view, where each seat gets its own pane.
//
// Everything in here obeys the two SwiftUI rules this app learned the hard way, both of
// which otherwise pin the main thread in `GraphHost.flushTransactions` and stop the
// window drawing:
//
//   1. No `.textSelection(.enabled)` on anything this view rebuilds while text streams.
//   2. No `Menu` rebuilt while text streams — the thinking controls live in a strip that
//      depends on the seats' specs, not on the streaming text.
//
// Scrolling is done by `AppKitScrollView` on a signal, never on a timer.

import ChatBotsCore
import SwiftUI

/// One conversation, all seats interleaved.
struct UnifiedConversation: View {
    @Environment(\.themePalette) private var palette
    @ObservedObject var controller: ChatController

    /// Turns with the setup brief and tool traffic removed, plus the two seats' live text
    /// spliced in at the end, so the thread reads like a chat rather than a debug log.
    private var rows: [ThreadRow] {
        var rows: [ThreadRow] = controller.turns.compactMap { turn in
            switch turn.kind {
            case .introduction, .tool: nil
            case .topic, .steering, .direction, .chat, .summary, .report:
                ThreadRow(turn: turn)
            }
        }
        // An actively generating seat gets a row, with whatever it has produced so far.
        for pane in controller.panes where pane.isGenerating {
            rows.append(ThreadRow(live: pane))
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsStrip
            Divider()
            conversation
            Divider()
            footer
        }
        .background(palette.background)
        .frame(minWidth: 420, maxHeight: .infinity)
    }

    // MARK: Settings strip

    /// Both seats' controls, above the thread. In this mode there are no per-pane headers,
    /// so the per-seat thinking control has to live here.
    private var settingsStrip: some View {
        VStack(spacing: 6) {
            ForEach(controller.panes) { pane in
                HStack(spacing: 8) {
                    Image(systemName: AgentTheme.symbol(for: pane.spec.id))
                        .scaledFont(size: 11)
                        .foregroundStyle(AgentTheme.tint(for: pane.spec.id, palette: palette))

                    Text(pane.spec.displayName)
                        .scaledFont(size: 11, weight: .semibold, design: .rounded)

                    BackendControl(
                        spec: pane.spec,
                        isEnabled: controller.turns.isEmpty
                    ) { backend in
                        controller.setBackend(backend, for: pane.id)
                    }

                    PersonaControl(
                        persona: pane.spec.persona,
                        isEnabled: !pane.isGenerating
                    ) { personaID in
                        controller.setPersona(personaID, for: pane.id)
                    }

                    PaneThinkingControl(
                        mode: pane.spec.thinking,
                        isEnabled: !pane.isGenerating
                    ) { mode in
                        controller.setThinking(mode, for: pane.id)
                    }

                    StatusChip(
                        text: pane.statusText,
                        isGenerating: pane.isGenerating,
                        palette: palette
                    )

                    CompactAgentSettings(spec: pane.spec, palette: palette)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface)
    }

    // MARK: Conversation

    private var conversation: some View {
        AppKitScrollView(scrollToBottomSignal: controller.threadScrollSignal) {
            LazyVStack(alignment: .leading, spacing: 10) {
                if rows.isEmpty {
                    emptyState
                }
                ForEach(rows) { row in
                    if let turn = row.turn {
                        ThreadMessage(
                                turn: turn,
                                isPending: controller.pendingSteeringIDs.contains(turn.id),
                                isOwn: false,
                                liveText: "",
                                liveReasoning: "",
                                liveBlocks: [],
                            activity: "",
                            showReasoning: controller.showReasoning
                        )
                    } else if let pane = row.live {
                        ThreadMessage(
                            turn: nil,
                            isPending: false,
                            isOwn: false,
                            liveText: pane.liveText,
                            liveReasoning: pane.liveReasoning,
                            liveBlocks: pane.liveBlocks,
                            activity: pane.activity,
                            showReasoning: controller.showReasoning,
                            liveSpec: pane.spec
                        )
                    }
                }
            }
            .padding(12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .scaledFont(size: 26)
                .foregroundStyle(palette.textTertiary)
            Text("Nothing yet")
                .scaledFont(size: 13, weight: .medium, design: .rounded)
                .foregroundStyle(palette.textSecondary)
            Text("Set a topic and press Start. Both models will post here.")
                .scaledFont(size: 11)
                .foregroundStyle(palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            ForEach(controller.panes) { pane in
                if let stats = pane.lastStats, stats.generationTokens > 0 {
                    Label("\(pane.spec.id): \(Format.rates(stats))", systemImage: "speedometer")
                }
            }
            Spacer(minLength: 0)
            Button {
                controller.compactNow()
            } label: {
                Label("Condense", systemImage: "arrow.triangle.2.circlepath")
                    .scaledFont(size: 9.5)
            }
            .buttonStyle(.link)
            .disabled(controller.isRunning || controller.turns.isEmpty)
            .help("Summarise the older turns now instead of waiting for the threshold")
            Label(
                Format.context(
                    tokens: controller.contextUsage.tokens,
                    of: controller.contextUsage.window,
                    compactAt: controller.compactThreshold),
                systemImage: "text.book.closed"
            )
        }
        .scaledFont(size: 9.5, design: .rounded)
        .foregroundStyle(palette.textTertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(palette.surface)
    }
}

/// One row of the thread: either a logged turn or a seat that is mid-generation.
struct ThreadRow: Identifiable {
    var turn: Turn?
    var live: AgentPaneState?
    /// Stable across rebuilds so SwiftUI does not re-create the row every update.
    var id: String {
        if let turn { return "turn-\(turn.id)" }
        if let live { return "live-\(live.id)" }
        return "empty"
    }

    init(turn: Turn) { self.turn = turn }
    init(live: AgentPaneState) { self.live = live }
}

/// One message in the thread.
///
/// Alignment and tint carry the attribution: a seat's messages hug its own side, the
/// moderator's stay centred and neutral. Reasoning and tool traffic hang off whichever
/// message produced them, so the thread stays readable while remaining honest about what
/// the model did.
struct ThreadMessage: View {
    @Environment(\.themePalette) private var palette
    let turn: Turn?
    let isPending: Bool
    let isOwn: Bool
    let liveText: String
    let liveReasoning: String
    let liveBlocks: [String]
    let activity: String
    let showReasoning: Bool
    var liveSpec: AgentSpec?

    private var speakerID: String? { turn?.speakerID ?? liveSpec?.id }

    private var name: String {
        turn?.speakerName ?? liveSpec?.displayName ?? "Model"
    }

    private var isModerator: Bool {
        turn?.kind == .topic || turn?.kind == .steering || turn?.kind == .direction
    }

    /// Seats alternate sides so the eye can follow who is speaking without reading names.
    private var alignment: HorizontalAlignment { isModerator ? .center : .leading }

    private var frameAlignment: Alignment {
        if isModerator { return .center }
        return isSecondSeat ? .trailing : .leading
    }

    private var isSecondSeat: Bool {
        guard let speakerID else { return false }
        return speakerID.hasSuffix("B")
    }

    private var tint: Color {
        guard let speakerID, !isModerator else {
            return AgentTheme.moderatorTint(palette)
        }
        return AgentTheme.tint(for: speakerID, palette: palette)
    }

    private var text: String { turn?.content ?? liveText }

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            header
            if !liveReasoning.isEmpty, showReasoning {
                ReasoningBlock(text: liveReasoning, tint: tint)
                    .frame(maxWidth: 620, alignment: .leading)
            }
            bubble
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var header: some View {
        HStack(spacing: 5) {
            if isModerator {
                Image(systemName: turn?.symbol ?? "person.wave.2.fill")
                    .scaledFont(size: 9)
            }
            Text(isModerator ? name.uppercased() : name)
                .scaledFont(size: 10, weight: .heavy, design: .rounded)
            if turn == nil {
                Text("streaming")
                    .scaledFont(size: 9, weight: .semibold, design: .rounded)
                    .foregroundStyle(palette.textSecondary)
            }
            if isPending {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    Text("queued")
                }
                .scaledFont(size: 9, weight: .semibold, design: .rounded)
                .foregroundStyle(AgentTheme.warning)
            }
        }
        .foregroundStyle(tint)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !liveBlocks.isEmpty || !text.isEmpty {
                // Frozen paragraphs first, then the growing tail. Selection is off for the
                // reason given at the top of this file.
                ForEach(Array(liveBlocks.enumerated()), id: \.offset) { _, block in
                    Text(block)
                        .scaledFont(size: 12.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if text.isEmpty, turn == nil {
                    WaitingLine(name: name, tint: tint, activity: activity)
                } else if !text.isEmpty {
                    Text(text)
                        .scaledFont(size: 12.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if turn == nil {
                WaitingLine(name: name, tint: tint, activity: activity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 620, alignment: .leading)
        .background(tint.opacity(isModerator ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(isModerator ? 0.35 : 0.28), lineWidth: 0.8)
        )
        .opacity(isPending ? 0.65 : 1)
    }
}

/// The setup brief, shown once at the top of the thread and collapsed by default.
struct SetupBlock: View {
    @Environment(\.themePalette) private var palette
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .scaledFont(size: 9, weight: .bold)
                    Image(systemName: "info.circle")
                        .scaledFont(size: 10)
                    Text("Setup — the topic and the brief both models received")
                        .scaledFont(size: 10.5, design: .rounded)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .scaledFont(size: 11)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.raised, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A seat that is generating but has not produced text yet.
private struct WaitingLine: View {
    let name: String
    let tint: Color
    let activity: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("\(name) \(activity.isEmpty ? "is thinking" : activity)")
                .scaledFont(size: 11.5, design: .rounded)
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
    }
}
