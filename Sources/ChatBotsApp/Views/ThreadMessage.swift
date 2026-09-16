// ChatBotsApp — one row of the single thread, and the pieces it draws
//
// The row model and the message view that renders it, split out of `UnifiedConversation.swift`,
// which held the window mode and every row type in one 583-line file. The rules at the top of that
// file apply here too: nothing in a row enables text selection or rebuilds a `Menu` while text
// streams.

import ChatBotsCore
import SwiftUI

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
        guard let turn else { return .theirs }  // a seat mid-generation
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
