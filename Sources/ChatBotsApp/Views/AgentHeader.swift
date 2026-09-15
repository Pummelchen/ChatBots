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
    /// Seat position, for the colour and symbol.
    let seatIndex: Int
    /// The seat's own kind ("Agent 1"), used when a cleared name is restored.
    let seatKind: String
    /// Whether the name is currently being edited, owned by the pane.
    let seatRenaming: Bool
    /// Whether renaming is allowed at all right now.
    let canRenameSeats: Bool
    let onRename: (String) -> Void
    let onBeginRename: () -> Void
    /// Backend may only change before the conversation begins.
    let canChangeBackend: Bool
    let statusText: String
    let isGenerating: Bool
    let tint: Color
    let palette: AppPalette
    let onThinkingChange: (ThinkingMode) -> Void
    let onPersonaChange: (String) -> Void
    let onBackendChange: (AgentSpec.Backend) -> Void
    let onModelChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: AgentTheme.symbol(forSeat: seatIndex))
                    .foregroundStyle(tint)
                    .scaledFont(size: 15)

                VStack(alignment: .leading, spacing: 1) {
                    EditableSeatName(
                        name: spec.displayName,
                        seatKind: seatKind,
                        isRenaming: seatRenaming,
                        canRename: canRenameSeats,
                        onBeginRename: onBeginRename,
                        onCommit: onRename
                    )
                    Text(spec.backendLabel)
                        .scaledFont(size: 10.5, design: .monospaced)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                BackendControl(
                    spec: spec,
                    isEnabled: canChangeBackend,
                    onSelect: onBackendChange
                )

                ModelControl(
                    spec: spec,
                    isEnabled: !isGenerating,
                    onSelect: onModelChange
                )

                PersonaControl(
                    persona: spec.persona,
                    isEnabled: !isGenerating,
                    onSelect: onPersonaChange
                )

                PaneThinkingControl(
                    mode: spec.thinking,
                    isEnabled: !isGenerating,
                    onChange: onThinkingChange
                )

                statusChip
            }

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
    @EnvironmentObject private var zoom: ZoomStore
    let text: String
    let isGenerating: Bool
    let palette: AppPalette

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isGenerating ? AgentTheme.ok : AgentTheme.dotIdle(palette))
                .frame(width: 7 * zoom.scale, height: 7 * zoom.scale)
            Text(text)
                .scaledFont(size: 10, weight: .medium, design: .rounded)
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
                    .scaledFont(size: 9)
                Text("think: \(mode.label)")
                    .scaledFont(size: 10, weight: .medium, design: .rounded)
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
/// Per-seat persona picker.
///
/// Same isolation as `PaneThinkingControl`: plain values plus a callback, never an
/// observation of the streaming pane, because a `Menu` rebuilt on every streaming update
/// sends the hosting view into a transaction loop that stops the window drawing.
///
/// Styled after the macOS way of picking a value from a list with an indicator.
struct PersonaControl: View {
    let persona: Persona
    let isEnabled: Bool
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(Persona.Category.allCases) { category in
                Section(category.rawValue) {
                    ForEach(PersonaLibrary.personas(in: category)) { candidate in
                        Button {
                            onSelect(candidate.id)
                        } label: {
                            if candidate.id == persona.id {
                                Label(candidate.name, systemImage: "checkmark")
                            } else {
                                Text(candidate.name)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "theatermasks")
                    .scaledFont(size: 9)
                Text(persona.name)
                    .scaledFont(size: 10, weight: .medium, design: .rounded)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!isEnabled)
        .help(persona.summary + " — applies to this seat only")
    }
}

/// A one-line summary of both seats' styles, shown before the conversation starts.
struct PersonaSummary: View {
    let specs: [AgentSpec]
    let palette: AppPalette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "theatermasks")
                .scaledFont(size: 10)
            ForEach(Array(specs.enumerated()), id: \.offset) { index, spec in
                if index > 0 {
                    Image(systemName: "arrow.left.arrow.right")
                        .scaledFont(size: 8)
                        .foregroundStyle(palette.textTertiary)
                }
                Text("\(spec.id): \(spec.persona.name)")
                    .scaledFont(size: 10.5, weight: .medium, design: .rounded)
                    .foregroundStyle(AgentTheme.tint(for: spec.id, palette: palette))
                    // One line each: at large text sizes this summary cannot fit, and a
                    // name broken across two lines reads worse than a shorter one. The
                    // per-seat control in each pane carries the full value anyway, and the
                    // tooltip has both.
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .help(specs.map { "\($0.id) — \($0.persona.name): \($0.persona.summary)" }
            .joined(separator: "\n"))
    }
}

/// Per-seat backend picker.
///
/// Changing backend changes who a participant *is*, so it is offered only before the
/// conversation starts — the control disables itself once there are turns, and the
/// tooltip says why.
struct BackendControl: View {
    let spec: AgentSpec
    let isEnabled: Bool
    let onSelect: (AgentSpec.Backend) -> Void

    var body: some View {
        Menu {
            Picker("Backend", selection: binding) {
                ForEach(AgentSpec.Backend.allCases) { backend in
                    Text(backend.label).tag(backend)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: spec.backend == .mlx ? "cpu" : "network")
                    .scaledFont(size: 9)
                Text(spec.backend.shortLabel)
                    .scaledFont(size: 10, weight: .medium, design: .rounded)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!isEnabled)
        .help(
            !isEnabled
                ? "Backend is fixed once the conversation has started"
                : spec.backend == .mlx
                    ? "Running \(spec.modelShortName) in the engine process, on this Mac's GPU with MLX"
                    : "Talking to \(spec.openAI.baseURL) over the OpenAI Responses API. Web tools are MLX-only, so this seat has none."
        )
    }

    private var binding: Binding<AgentSpec.Backend> {
        Binding(get: { spec.backend }, set: { onSelect($0) })
    }
}

/// Per-seat checkpoint picker.
///
/// The list is `ModelCatalog`, so what is offered is what has been run through this app's engine
/// rather than whatever a hub search happens to return. The current checkpoint is always shown even
/// when it is not in the catalogue — a seat can be pointed at any repository id from the command line,
/// and a picker that could not display the model in use would be lying about it.
///
/// Same isolation as the other controls: plain values and a callback, never an observation of the
/// streaming pane, because a `Menu` rebuilt on every token sends the hosting view into a transaction
/// loop.
struct ModelControl: View {
    let spec: AgentSpec
    let isEnabled: Bool
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            Picker("Model", selection: binding) {
                ForEach(choices) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .scaledFont(size: 9)
                Text(spec.modelShortName)
                    .scaledFont(size: 10, weight: .medium, design: .rounded)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!isEnabled)
        .help(helpText)
    }

    /// The catalogue, plus whatever this seat is running if the catalogue does not have it.
    private var choices: [ModelChoice] {
        let known = ModelCatalog.choices
        guard !known.contains(where: { $0.id == spec.modelID }) else { return known }
        // Built separately rather than inline in the array: a call whose last argument is an empty
        // literal is where swiftlint and swift-format disagree about a trailing comma, and a named
        // local reads better than either of them.
        let current = ModelChoice(
            id: spec.modelID,
            name: spec.modelShortName,
            summary: "Set outside this app; its size is not known here.",
            aliases: []
        )
        return known + [current]
    }

    private var helpText: String {
        guard isEnabled else { return "The model is fixed while this seat is generating" }
        let current = ModelCatalog.choice(for: spec.modelID)?.summary
        return current ?? "MLX checkpoint for this seat: \(spec.modelID)"
    }

    private var binding: Binding<String> {
        Binding(get: { spec.modelID }, set: { onSelect($0) })
    }
}

/// A seat's name, renamed by double-clicking it.
///
/// Double-click to edit and Return (or clicking away) to commit, which is the convention
/// macOS uses for renaming — Finder's file names, sidebar items and window titles all
/// behave this way, so it needs no explaining. A single click does nothing, so the name
/// cannot be changed by accident while reaching for a control beside it.
///
/// The field shows the seat's kind as a placeholder, so clearing the name shows what will
/// be restored rather than leaving an empty space.
struct EditableSeatName: View {
    let name: String
    let seatKind: String
    let isRenaming: Bool
    let canRename: Bool
    let onBeginRename: () -> Void
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isRenaming {
                TextField(seatKind, text: $draft)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 14, weight: .semibold, design: .rounded)
                    .frame(minWidth: 60, maxWidth: 220)
                    .focused($focused)
                    .onSubmit { onCommit(draft) }
                    // Clicking away commits, matching the double-click-to-edit convention.
                    // Committing is idempotent on the pane side, so this firing around the
                    // same time as onSubmit is harmless.
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { onCommit(draft) }
                    }
                    .task(id: isRenaming) {
                        guard isRenaming else { return }
                        draft = name
                        focused = true
                    }
            } else {
                Text(name)
                    .scaledFont(size: 14, weight: .semibold, design: .rounded)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard canRename else { return }
                        onBeginRename()
                    }
                    .help(
                        canRename
                            ? "Double-click to rename"
                            : "Names are fixed once the conversation has started"
                    )
            }
        }
    }

}
