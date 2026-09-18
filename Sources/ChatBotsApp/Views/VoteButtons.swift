// ChatBotsApp — the audience's verdict on one contribution
//
// The vote buttons belong to the reader, not to the conversation. They are never sent to a model
// and never enter the prompt — the engine keeps them beside the transcript and nothing reads them
// to decide who speaks. See `AudienceVote` for why that boundary matters.
//
// Kept as its own view because there are two ways of drawing a transcript in this app (the panes
// and the single thread) and a score that only appeared in one of them would be a feature that
// depends on a layout preference.

import ChatBotsCore
import SwiftUI

struct VoteButtons: View {
    @Environment(\.themePalette) private var palette
    @ObservedObject var controller: ChatController
    let turn: Turn

    var body: some View {
        // Only a contribution can be scored. A verdict on the topic or on the moderator's own
        // assignment would be a judgement of something nobody argued.
        if turn.kind == .chat {
            HStack(spacing: 4) {
                button(.strong, symbol: "arrow.up")
                button(.weak, symbol: "arrow.down")
            }
        }
    }

    private func button(_ verdict: AudienceVote.Verdict, symbol: String) -> some View {
        let cast = controller.vote(for: turn.id) == verdict
        return Button {
            controller.castVote(turnID: turn.id.uuidString, verdict: verdict)
        } label: {
            Image(systemName: symbol)
                .scaledFont(size: 9, weight: .bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    cast ? palette.raised : Color.clear, in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        cast
                            ? AgentTheme.tint(for: turn.speakerID ?? "", palette: palette)
                            : palette.border,
                        lineWidth: 1)
                )
                .foregroundStyle(cast ? palette.text : palette.textTertiary)
        }
        .buttonStyle(.plain)
        .help(
            cast
                ? "\(verdict.label) — click again to take the verdict back"
                : verdict.label)
    }
}

/// The scorecard, once anyone has voted.
struct AudienceScorecardView: View {
    @Environment(\.themePalette) private var palette
    @ObservedObject var controller: ChatController

    var body: some View {
        if !controller.audience.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "person.wave.2")
                    .scaledFont(size: 9)
                    .foregroundStyle(palette.textSecondary)
                Text(
                    controller.audience
                        .map { "\($0.name) \($0.score > 0 ? "+" : "")\($0.score)" }
                        .joined(separator: " · ")
                )
                .scaledFont(size: 10, design: .rounded)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)

                Button {
                    controller.clearVotes()
                } label: {
                    Image(systemName: "xmark.circle")
                        .scaledFont(size: 9)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textTertiary)
                .help("Forget every vote")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(palette.raised, in: Capsule())
        }
    }
}
