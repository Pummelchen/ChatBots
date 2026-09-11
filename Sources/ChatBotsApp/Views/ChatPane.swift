// ChatBotsApp — one seat's pane
//
// Both panes show the same shared log; the difference is the header (which model,
// what state it is in) and the live row at the bottom while that seat is speaking.

import ChatBotsCore
import SwiftUI

struct ChatPane: View {
    @Environment(\.themePalette) private var palette
    @ObservedObject var pane: AgentPaneState
    let turns: [Turn]
    let pendingSteeringIDs: Set<UUID>
    let showReasoning: Bool
    let contextEstimate: Int

    private var tint: Color { AgentTheme.tint(for: pane.spec.id, palette: palette) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            footer
        }
        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: AgentTheme.symbol(for: pane.spec.id))
                    .foregroundStyle(tint)
                    .font(.system(size: 15))

                VStack(alignment: .leading, spacing: 1) {
                    Text(pane.spec.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(pane.spec.modelShortName)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                statusChip
            }

            HStack(spacing: 10) {
                Label(String(format: "temp %.2f", pane.spec.temperature), systemImage: "thermometer.medium")
                Label("top-p \(String(format: "%.2f", pane.spec.topP))", systemImage: "chart.bar")
                Label("max \(pane.spec.maxTokens) tok", systemImage: "text.alignleft")
                if pane.spec.webSearchEnabled {
                    Label("web", systemImage: "globe")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9.5, design: .rounded))
            .foregroundStyle(palette.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10))
    }

    private var statusChip: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(pane.isGenerating ? AgentTheme.ok : AgentTheme.dotIdle(palette))
                .frame(width: 7, height: 7)
            Text(pane.statusText)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(palette.raised, in: Capsule())
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(turns) { turn in
                        TurnRow(
                            turn: turn,
                            isOwn: turn.speakerID == pane.spec.id,
                            isPending: pendingSteeringIDs.contains(turn.id)
                        )
                        .id(turn.id)
                    }

                    if pane.isGenerating {
                        liveRow.id(Self.liveAnchor)
                    }

                    if turns.isEmpty {
                        emptyState
                    }
                }
                .padding(12)
            }
            // Only follow real growth. Animating a scroll per token fights the layout
            // and is a common cause of stutter while a model streams.
            .onChange(of: turns.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: pane.liveText.count) { _, count in
                guard count > 0 else { return }
                scrollToBottom(proxy)
            }
        }
    }

    private static let liveAnchor = "live-turn-anchor"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.liveAnchor, anchor: .bottom)
    }

    @ViewBuilder
    private var liveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !pane.liveReasoning.isEmpty, showReasoning {
                ReasoningBlock(text: pane.liveReasoning, tint: tint)
            }

            if pane.liveText.isEmpty {
                WaitingRow(name: pane.spec.displayName, tint: tint, activity: pane.activity)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: AgentTheme.symbol(for: pane.spec.id))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 18)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(pane.spec.id.uppercased())
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(tint)
                            Text("streaming")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.textSecondary)
                            Spacer(minLength: 0)
                        }
                        Text(pane.liveText)
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(tint.opacity(0.5), lineWidth: 1.2)
                )
            }

            if !pane.toolLog.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(pane.toolLog.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 5) {
                            Image(systemName: "globe")
                                .font(.system(size: 9))
                            Text(entry)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(2)
                        }
                        .foregroundStyle(AgentTheme.toolTint(palette))
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26))
                .foregroundStyle(palette.textTertiary)
            Text("Nothing yet")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(palette.textSecondary)
            Text("Set a topic and press Start. Both models will appear here.")
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let stats = pane.lastStats, stats.generationTokens > 0 {
                Label(Format.rate(stats), systemImage: "speedometer")
            } else {
                Label("no turn yet", systemImage: "speedometer")
            }
            Spacer(minLength: 0)
            Label("≈\(Format.tokens(contextEstimate)) prompt tok shared", systemImage: "text.book.closed")
        }
        .font(.system(size: 9.5, design: .rounded))
        .foregroundStyle(palette.textTertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(palette.surface)
    }
}
