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
//
// This file is the window itself. The rows it draws are in `ThreadMessage.swift`, and the setup
// brief is in `SetupBlock.swift`; it was one 583-line file.

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
