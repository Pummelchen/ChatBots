// ChatBotsApp — the single-thread window mode
//
// One conversation, newest at the bottom, drawn the way a group chat draws one: your own
// messages on the right in blue, everybody else's on the left in grey, a name above the first
// message of a run, an avatar beside the last, and the app's own notes as centred grey lines.
//
// The identity is carried by the name and the avatar rather than by which side a bubble is on,
// which is the whole reason a group chat looks like this: with four people in the room, two
// sides cannot tell you who is speaking. This is the alternative to the split view, where each
// seat gets its own pane.
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

    /// Turns with the setup brief and tool traffic removed, plus the seats' live text spliced
    /// in at the end, so the thread reads like a chat rather than as a debug log.
    ///
    /// The setup brief is not a message and belongs in `SetupBlock`, which is where it is.
    private var rows: [ThreadRow] {
        var built: [ThreadRow] = controller.turns.compactMap { turn in
            switch turn.kind {
            case .introduction, .tool: nil
            case .topic, .steering, .direction, .chat, .summary, .report:
                ThreadRow(turn: turn)
            }
        }
        // An actively generating seat gets a row, with whatever it has produced so far.
        for pane in controller.panes where pane.isGenerating {
            built.append(ThreadRow(live: pane))
        }
        return ThreadRow.grouped(built)
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

                    ModelControl(
                        spec: pane.spec,
                        isEnabled: !pane.isGenerating
                    ) { modelID in
                        controller.setModel(modelID, for: pane.id)
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

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface)
    }

    // MARK: Conversation

    private var conversation: some View {
        // The placeholder is drawn *over* the scroll view rather than inside it. Inside a
        // `LazyVStack` — whose width the scroll view decides from its content — `maxWidth:
        // .infinity` resolves to the stack's own idea of its width rather than the viewport's,
        // so "centred" landed well right of centre with nothing in the thread to size against.
        ZStack {
            transcript
            if rows.isEmpty {
                emptyState
            }
        }
    }

    private var transcript: some View {
        AppKitScrollView(scrollToBottomSignal: controller.threadScrollSignal) {
            // No stack spacing: each row brings its own. A group chat's rhythm is the point —
            // messages from one person sit tight together and a change of speaker gets air —
            // and a uniform gap throws exactly that information away.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    if let turn = row.turn {
                        ThreadMessage(
                            controller: controller,
                            turn: turn,
                            isPending: controller.pendingSteeringIDs.contains(turn.id),
                            liveText: "",
                            liveReasoning: "",
                            liveBlocks: [],
                            activity: "",
                            showReasoning: controller.showReasoning,
                            row: row
                        )
                    } else if let pane = row.live {
                        ThreadMessage(
                            controller: controller,
                            turn: nil,
                            isPending: false,
                            liveText: pane.liveText,
                            liveReasoning: pane.liveReasoning,
                            liveBlocks: pane.liveBlocks,
                            activity: pane.activity,
                            showReasoning: controller.showReasoning,
                            liveSpec: pane.spec,
                            row: row
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    /// What the thread says before anything has been said.
    ///
    /// Centred in the space it is actually given, which is why it is a sibling of the scroll
    /// view: see the note in `conversation`. Nudged up a little, because dead centre of a tall
    /// window reads as bottom-heavy once the eye includes the bars above and below.
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.bottom, 40)
        .allowsHitTesting(false)
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
///
/// The grouping — who is named, whose picture is drawn, where the gaps and the date lines go —
/// is `ThreadGrouping` in the core, which is where it can be tested. This type only carries the
/// answer to the view.
struct ThreadRow: Identifiable {
    var turn: Turn?
    var live: AgentPaneState?
    var flags = ThreadGrouping.Flags(
        opensRun: true, closesRun: true, startsGroup: true, divider: nil)

    var id: String {
        if let turn { return "turn-\(turn.id)" }
        if let live { return "live-\(live.id)" }
        return "empty"
    }

    var shape: ThreadGrouping.Shape {
        guard let turn else { return .theirs }   // a seat mid-generation
        return ThreadGrouping.shape(of: turn.kind)
    }

    var speaker: String? {
        if let turn { return turn.speakerID ?? turn.speakerName }
        if let live { return live.id }
        return nil
    }

    /// Group a whole thread, in one pass, over the rows in the order they are drawn.
    static func grouped(_ rows: [ThreadRow]) -> [ThreadRow] {
        let described = rows.map {
            ThreadGrouping.Row(shape: $0.shape, speaker: $0.speaker, at: $0.turn?.timestamp)
        }
        let flags = ThreadGrouping.flags(for: described)
        return zip(rows, flags).map { row, flag in
            var copy = row
            copy.flags = flag
            return copy
        }
    }
}

/// A participant's picture, in the only form this app has: their symbol in their colour.
///
/// A group chat identifies people by their picture. There are no photographs here, so the seat's
/// own symbol stands in — and it does the same job, which is letting the eye follow one person
/// down a long thread without reading a name each time.
struct SeatAvatar: View {
    let seatID: String
    let palette: AppPalette
    var isStreaming = false

    var body: some View {
        let tint = AgentTheme.tint(for: seatID, palette: palette)
        ZStack {
            Circle().fill(tint.opacity(isStreaming ? 0.16 : 0.26))
            Image(systemName: AgentTheme.symbol(for: seatID))
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(tint)
        }
        .frame(width: 26, height: 26)
        .overlay(
            Circle().strokeBorder(tint.opacity(isStreaming ? 0.5 : 0.0), lineWidth: 1.5)
        )
    }
}

/// One message in the thread.
///
/// Three shapes, and nothing else: yours (blue, right), theirs (grey, left, with a name above
/// the first of a run and an avatar beside the last), and the app's own notes (a centred grey
/// line, no bubble). Reasoning and tool activity hang off the message that produced them, so the
/// thread stays readable while remaining honest about what the model actually did.
struct ThreadMessage: View {
    @Environment(\.themePalette) private var palette
    @ObservedObject var controller: ChatController
    let turn: Turn?
    let isPending: Bool
    let liveText: String
    let liveReasoning: String
    let liveBlocks: [String]
    let activity: String
    let showReasoning: Bool
    var liveSpec: AgentSpec?
    /// Where this row sits in the thread, so the gaps and the name and the avatar are right.
    let row: ThreadRow

    private var speakerID: String? { turn?.speakerID ?? liveSpec?.id }

    private var name: String {
        turn?.speakerName ?? liveSpec?.displayName ?? "Model"
    }

    private var isMine: Bool { row.shape == .mine }
    private var isSystem: Bool { row.shape == .system }

    private var tint: Color {
        guard let speakerID, !isSystem else { return AgentTheme.moderatorTint(palette) }
        return AgentTheme.tint(for: speakerID, palette: palette)
    }

    private var text: String { turn?.content ?? liveText }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let divider = row.flags.divider {
                Text(divider)
                    .scaledFont(size: 10.5, weight: .medium)
                    .foregroundStyle(palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }

            if isSystem {
                systemLine
            } else if isMine {
                mine
            } else {
                theirs
            }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .padding(.top, row.flags.startsGroup && row.flags.divider == nil ? 9 : 0)
    }

    // MARK: Your own messages

    private var mine: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 3) {
                bubble(
                    text: text,
                    blocks: [],
                    fill: palette.bubbleMine,
                    foreground: palette.onBubbleMine,
                    maxWidth: 520
                )
                // A queued message is the one status this app can honestly report. There is no
                // "Delivered" or "Read" to claim: nothing acknowledges a model having read it.
                if isPending {
                    Text("Queued")
                        .scaledFont(size: 9.5)
                        .foregroundStyle(palette.textTertiary)
                        .padding(.trailing, 4)
                }
                if let turn { VoteButtons(controller: controller, turn: turn) }
            }
        }
    }

    // MARK: Everybody else

    private var theirs: some View {
        HStack(alignment: .bottom, spacing: 6) {
            // The avatar holds the place even when it is not drawn, so every bubble in a run
            // starts at the same edge and the column does not wobble.
            Group {
                if row.flags.closesRun {
                    SeatAvatar(
                        seatID: speakerID ?? "unknown",
                        palette: palette,
                        isStreaming: turn == nil
                    )
                } else {
                    Color.clear.frame(width: 26, height: 26)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                if row.flags.opensRun {
                    Text(name)
                        .scaledFont(size: 10.5, weight: .semibold)
                        .foregroundStyle(palette.textSecondary)
                        .padding(.leading, 3)
                }
                if !liveReasoning.isEmpty, showReasoning {
                    ReasoningBlock(text: liveReasoning, tint: tint)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                bubble(
                    text: text,
                    blocks: liveBlocks,
                    fill: palette.bubbleTheirs,
                    foreground: Color.primary,
                    maxWidth: 520,
                    isStreaming: turn == nil
                )
                if turn == nil { ActivityLine(activity: activity) }
                if let turn { VoteButtons(controller: controller, turn: turn) }
            }
            Spacer(minLength: 40)
        }
    }

    // MARK: The app's own notes

    /// A centred grey line, the way a messaging app reports that somebody was added to a group.
    ///
    /// The research moderator's assignments go here rather than into a bubble, and that is a
    /// decision rather than a shortcut: the director is the app speaking, not one of the
    /// participants, and a bubble would put it in the argument the analysts are having.
    private var systemLine: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: turn?.symbol ?? "info.circle")
                    .scaledFont(size: 9)
                Text(systemLabel)
                    .scaledFont(size: 10.5, weight: .semibold)
            }
            .foregroundStyle(palette.textSecondary)

            if !text.isEmpty {
                Text(text)
                    .scaledFont(size: 11)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
        .opacity(isPending ? 0.6 : 1)
    }

    private var systemLabel: String {
        switch turn?.kind {
        case .direction: "Research Moderator assigned work"
        case .summary: "Earlier discussion condensed"
        case .report: "Research report"
        default: name
        }
    }

    // MARK: The bubble

    @ViewBuilder
    private func bubble(
        text: String,
        blocks: [String],
        fill: Color,
        foreground: Color,
        maxWidth: CGFloat,
        isStreaming: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Frozen paragraphs first, then the growing tail. Selection is off for the reason
            // given at the top of this file.
            // No `maxWidth: .infinity` inside the bubble. A frame that fills the available
            // width makes *every* bubble the maximum width regardless of what it says, so
            // "Why are eggs not round?" drew as a 520-point slab and a one-word reply would
            // have too. The bubble hugs its text and stops at the cap instead.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                Text(block)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if text.isEmpty, isStreaming {
                TypingDots()
            } else if !text.isEmpty {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .scaledFont(size: 12.5)
        .foregroundStyle(foreground)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: maxWidth, alignment: .leading)
        // Continuous corners, because a group chat's bubbles are squircles rather than
        // rounded rectangles — at 17 points the difference is most of what makes it look right.
        .background(fill, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

/// A seat that has started producing tokens but has nothing readable yet.
///
/// Three dots rather than a spinner, because this is the one place the app is imitating a chat
/// window and a spinner is the one thing a chat window never shows. Deliberately *not* animated:
/// this thread is rebuilt on every streamed token, and a repeating animation inside it is how
/// this file's SwiftUI main-thread stalls start.
private struct TypingDots: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 6, height: 6)
                    .opacity(0.35 + Double(index) * 0.25)
            }
        }
        .padding(.vertical, 3)
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

/// What a seat is doing while it has produced no readable text.
///
/// The typing bubble says "something is coming"; this says *what* — "searching the web" is worth
/// knowing and a row of dots cannot say it. Small and grey, under the bubble, where a chat app
/// puts a receipt.
private struct ActivityLine: View {
    @Environment(\.themePalette) private var palette
    let activity: String

    var body: some View {
        if !activity.isEmpty {
            Text(activity)
                .scaledFont(size: 10)
                .foregroundStyle(palette.textTertiary)
                .padding(.leading, 3)
        }
    }
}
