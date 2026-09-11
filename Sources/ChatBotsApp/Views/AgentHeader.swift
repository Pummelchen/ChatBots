// ChatBotsApp — the per-seat header and settings controls
//
// Shared by both window modes: the split view puts one at the top of each pane, the
// unified view puts a compact strip of them above a single conversation.
//
// These take plain values rather than observing the streaming pane. A SwiftUI `Menu`
// rebuilt 10–20 times a second — which is what observing the pane means while a model
// streams — sends the hosting view into a `NSRunLoop.flushObservers` →
// `GraphHost.flushTransactions` transaction loop, and the window stops drawing. Verified
// by sampling before and after isolating the control.

import ChatBotsCore
import SwiftUI

/// A pane's header: identity, sampler readout, thinking control and status.
///
/// Takes plain values rather than observing the pane, because the pane republishes on
/// every streaming update. A `Menu` rebuilt 10–20 times a second is enough to send the
/// hosting view into a `NSRunLoop.flushObservers` → `GraphHost.flushTransactions`
/// transaction loop, which stops the window drawing entirely (measured). With values
/// only, this subtree is rebuilt when something it actually shows changes — the spec,
/// the status line, or whether the seat is generating.
struct PaneHeader: View {
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
        StatusChip(text: statusText, isGenerating: isGenerating, palette: palette)
    }
}

/// A seat's state: a dot plus a short label.
struct StatusChip: View {
    let text: String
    let isGenerating: Bool
    let palette: AppPalette

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isGenerating ? AgentTheme.ok : AgentTheme.dotIdle(palette))
                .frame(width: 7, height: 7)
            Text(text)
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
struct PaneThinkingControl: View {
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

/// One seat's settings, compact, for the unified window's strip.
///
/// A condensed version of the pane header's parameter row. The full precision is still
/// available: it is printed per seat at startup, and the tooltip here carries all of it.
struct CompactAgentSettings: View {
    let spec: AgentSpec
    let palette: AppPalette

    var body: some View {
        HStack(spacing: 7) {
            Label(String(format: "%.2f", spec.temperature), systemImage: "thermometer.medium")
            Label("p \(String(format: "%.2f", spec.topP))", systemImage: "chart.bar")
            Label("k \(spec.topK)", systemImage: "list.number")
            Label("min \(String(format: "%.1f", spec.minP))", systemImage: "line.diagonal")
            if let presence = spec.presencePenalty {
                Label("pres \(String(format: "%.1f", abs(presence)))", systemImage: "arrow.uturn.backward")
            }
            Label("\(Format.tokens(spec.maxTokens))", systemImage: "text.alignleft")
            if spec.webSearchEnabled {
                Image(systemName: "globe")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9.5, design: .rounded))
        .foregroundStyle(palette.textTertiary)
        .help(description)
    }

    private var description: String {
        let presence = spec.presencePenalty.map { String(format: "%.1f", abs($0)) } ?? "off"
        let repetition = spec.repetitionPenalty.map { String(format: "%.2f", $0) } ?? "off"
        return """
            \(spec.modelID)
            temp \(String(format: "%.2f", spec.temperature)) · top-p \(String(format: "%.2f", spec.topP)) · \
            top-k \(spec.topK) · min-p \(String(format: "%.1f", spec.minP)) · presence \(presence) · \
            repetition \(repetition) · max \(spec.maxTokens) tok · thinking \(spec.thinking.label)
            """
    }
}
