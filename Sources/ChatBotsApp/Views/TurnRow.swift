// ChatBotsApp — the matrix of shared conversation rows

import ChatBotsCore
import SwiftUI

/// One logged turn, rendered the same way in both panes.
///
/// Text selection is deliberately *not* enabled here or anywhere else in a pane: these
/// views are rebuilt every time the pane republishes (~20 Hz while a model streams), and
/// a rebuilt selection overlay drives SwiftUI into a re-entrant update that stops the
/// window drawing. See `AppKitScrollView` for the full account, and Edit ▸ Copy
/// Conversation for the supported way to get the text out.
///
/// Both panes draw the *shared* log: the moderator's messages and each model's
/// messages appear identically on both sides. Only the active seat adds a live,
/// in-progress row underneath.
struct TurnRow: View {
    @EnvironmentObject private var zoom: ZoomStore
    @Environment(\.themePalette) private var palette
    @ObservedObject var controller: ChatController
    let turn: Turn
    /// The speaker's seat position, when known; the id is parsed as a fallback.
    let seatIndex: Int?
    let isOwn: Bool
    let isPending: Bool

    /// The row's colour as a concrete `Color`, so it can be faded into washes and
    /// borders. The setup row is deliberately neutral, hence the fallback.
    private var wash: Color {
        switch turn.kind {
        case .topic, .steering, .direction: AgentTheme.moderatorTint(palette)
        case .introduction, .summary, .report: palette.isBlack ? Color(white: 0.16) : Color.secondary
        case .tool: AgentTheme.toolTint(palette)
        case .chat:
            seatIndex.map { AgentTheme.tint(forSeat: $0, palette: palette) }
                ?? AgentTheme.tint(for: turn.speakerID ?? "", palette: palette)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: turn.symbol)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(turn.tint(palette, seatIndex: seatIndex))
                .frame(width: 18 * zoom.scale)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(turn.badge)
                        .scaledFont(size: 10, weight: .heavy, design: .rounded)
                        .foregroundStyle(turn.tint(palette, seatIndex: seatIndex))
                    if isOwn {
                        Text("YOU")
                            .scaledFont(size: 9, weight: .bold, design: .rounded)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(wash.opacity(0.15), in: Capsule())
                            .foregroundStyle(wash)
                    }
                    if isPending {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                            Text("queued")
                        }
                        .scaledFont(size: 9, weight: .semibold, design: .rounded)
                        .foregroundStyle(AgentTheme.warning)
                    }
                    Spacer(minLength: 0)
                }

                Text(turn.content)
                    .scaledFont(size: 12.5, design: .default)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VoteButtons(controller: controller, turn: turn)

                if let detail = turn.toolDetail, !detail.isEmpty {
                    Text(detail)
                        .scaledFont(size: 10.5, design: .monospaced)
                        .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(wash.opacity(isOwn ? 0.16 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(wash.opacity(isOwn ? 0.45 : 0.16), lineWidth: isOwn ? 1.2 : 0.7)
        )
        .opacity(isPending ? 0.65 : 1)
    }
}

/// Collapsible chain-of-thought block. Never written to the log, only shown live.
struct ReasoningBlock: View {
    @Environment(\.themePalette) private var palette
    let text: String
    let tint: Color
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .scaledFont(size: 9, weight: .bold)
                    Image(systemName: "brain")
                        .scaledFont(size: 10)
                    Text(expanded ? "Thinking" : "Thinking — \(Format.summarise(text, limit: 60))")
                        .scaledFont(size: 11, design: .rounded)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.raised, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// A model that is mid-generation but has not produced visible text yet.
struct WaitingRow: View {
    @Environment(\.themePalette) private var palette
    let name: String
    let tint: Color
    let activity: String
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("\(name) \(activity.isEmpty ? "is thinking" : activity)")
                .scaledFont(size: 12, design: .rounded)
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}
