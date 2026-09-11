// ChatBotsApp — one seat's pane
//
// Both panes show the same shared log; the difference is the header (which model,
// what state it is in) and the live row at the bottom while that seat is speaking.

import ChatBotsCore
import SwiftUI

struct ChatPane: View {
    @Environment(\.themePalette) private var palette
    @ObservedObject var pane: AgentPaneState
    @ObservedObject var controller: ChatController
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
        // Values only — no `@ObservedObject` pane — so this subtree is not rebuilt while
        // text streams. See PaneHeader for why that matters.
        PaneHeader(
            spec: pane.spec,
            statusText: pane.statusText,
            isGenerating: pane.isGenerating,
            tint: tint,
            palette: palette,
            onThinkingChange: { controller.setThinking($0, for: pane.id) }
        )
    }

    // MARK: Transcript

    private var transcript: some View {
        // AppKit does the scrolling; see AppKitScrollView for why ScrollViewReader's
        // `scrollTo` could not be used here.
        AppKitScrollView(
            scrollToBottomSignal: pane.scrollSignal
        ) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(turns) { turn in
                    TurnRow(
                        turn: turn,
                        isOwn: turn.speakerID == pane.spec.id,
                        isPending: pendingSteeringIDs.contains(turn.id)
                    )
                }

                if pane.isGenerating {
                    liveRow
                }

                if turns.isEmpty {
                    emptyState
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var liveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !pane.liveReasoning.isEmpty, showReasoning {
                ReasoningBlock(text: pane.liveReasoning, tint: tint)
            }

            if pane.liveText.isEmpty, pane.liveBlocks.isEmpty {
                WaitingRow(name: pane.spec.displayName, tint: tint, activity: pane.activity)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: AgentTheme.symbol(for: pane.spec.id))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 18)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(pane.spec.id.uppercased())
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(tint)
                            Text("streaming")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.textSecondary)
                            Spacer(minLength: 0)
                        }
                        // Selection is enabled only on text that is no longer changing.
                        // A `.textSelection(.enabled)` view whose content updates while a
                        // model streams drives SwiftUI's `SelectionOverlay` into a
                        // re-entrant update: the overlay rescans on every change and each
                        // scan triggers another layout pass, which pins the main thread in
                        // `GraphHost.flushTransactions` and the window stops drawing.
                        //
                        // Completed paragraphs are frozen, so they can stay selectable;
                        // the tail becomes selectable the moment the turn ends and it is
                        // written into the log.
                        ForEach(Array(pane.liveBlocks.enumerated()), id: \.offset) { _, block in
                            Text(block)
                                .font(.system(size: 12.5))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !pane.liveText.isEmpty {
                            Text(pane.liveText)
                                .font(.system(size: 12.5))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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
