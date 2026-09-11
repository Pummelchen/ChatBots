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



/// A pane's header: identity, sampler readout, thinking control and status.
///
/// Takes plain values rather than observing the pane, because the pane republishes on
/// every streaming update. A `Menu` rebuilt 10–20 times a second is enough to send the
/// hosting view into a `NSRunLoop.flushObservers` → `GraphHost.flushTransactions`
/// transaction loop, which stops the window drawing entirely (measured). With values
/// only, this subtree is rebuilt when something it actually shows changes — the spec,
/// the status line, or whether the seat is generating.
private struct PaneHeader: View {
    let spec: AgentSpec
    let statusText: String
    let isGenerating: Bool
    let tint: Color
    let palette: AppPalette
    let onThinkingChange: (ThinkingMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: AgentTheme.symbol(for: spec.id))
                    .foregroundStyle(tint)
                    .font(.system(size: 15))

                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(spec.modelShortName)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                PaneThinkingControl(
                    mode: spec.thinking,
                    isEnabled: !isGenerating,
                    onChange: onThinkingChange
                )

                statusChip
            }

            HStack(spacing: 9) {
                Label(String(format: "temp %.2f", spec.temperature), systemImage: "thermometer.medium")
                Label("top-p \(String(format: "%.2f", spec.topP))", systemImage: "chart.bar")
                Label("top-k \(spec.topK)", systemImage: "list.number")
                Label("min-p \(String(format: "%.1f", spec.minP))", systemImage: "line.diagonal")
                if let presence = spec.presencePenalty {
                    Label("pres \(String(format: "%.1f", abs(presence)))", systemImage: "arrow.uturn.backward")
                        .help("Presence penalty \(String(format: "%.1f", abs(presence))) (stored as \(String(format: "%.2f", presence)) for MLX, which subtracts it)")
                }
                if let repetition = spec.repetitionPenalty, repetition != 1.0 {
                    Label("rep \(String(format: "%.2f", repetition))", systemImage: "repeat")
                }
                Label("max \(Format.tokens(spec.maxTokens)) tok", systemImage: "text.alignleft")
                if spec.webSearchEnabled {
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
                .fill(isGenerating ? AgentTheme.ok : AgentTheme.dotIdle(palette))
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(palette.raised, in: Capsule())
    }
}

/// The per-seat thinking level control.
///
/// Plain values plus a callback, and never a view of the streaming pane, so the `Menu` is
/// not rebuilt while text arrives.
private struct PaneThinkingControl: View {
    let mode: ThinkingMode
    let isEnabled: Bool
    let onChange: (ThinkingMode) -> Void

    var body: some View {
        Menu {
            Picker("Thinking", selection: binding) {
                ForEach(ThinkingMode.allCases) { candidate in
                    Text("\(candidate.label) — \(candidate.detail)").tag(candidate)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 9))
                Text("think: \(mode.label)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!isEnabled)
        .help(
            mode == .off
                ? "Reasoning disabled for this seat"
                : "Reasoning budget for this seat — applies from its next turn (\(mode.detail))"
        )
    }

    private var binding: Binding<ThinkingMode> {
        Binding(get: { mode }, set: { onChange($0) })
    }
}
