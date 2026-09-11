// ChatBotsApp — topic, transport controls and live status

import ChatBotsCore
import SwiftUI

struct ControlBar: View {
    @ObservedObject var controller: ChatController
    @State private var showNotes = false

    private var status: RunStatus { controller.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("Topic", systemImage: "text.bubble")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                TextField("What should the models discuss?", text: $controller.topic)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .disabled(controller.isRunning)
                    .onSubmit { if controller.canStart { controller.startOrRestart() } }

                transport
            }

            HStack(spacing: 10) {
                statusPill
                Spacer(minLength: 0)
                Toggle(isOn: $controller.showReasoning) {
                    Label("Show thinking", systemImage: "brain")
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Stream the models' <think> blocks into their panes. Thinking is never part of the shared log.")

                notesMenu
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 6) {
            Button {
                controller.startOrRestart()
            } label: {
                Label(
                    controller.turns.isEmpty ? "Start" : "Restart",
                    systemImage: controller.turns.isEmpty ? "play.fill" : "arrow.clockwise"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canStart)
            .help("Load both models and begin the conversation")

            Button {
                controller.togglePause()
            } label: {
                Label(status.isPaused ? "Resume" : "Pause", systemImage: status.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!status.isActive && !status.isPaused)
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button {
                controller.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!status.isActive && !status.isPaused)
            .keyboardShortcut(".", modifiers: .command)

            Button {
                controller.reset()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(controller.isRunning)
            .help("Forget the transcript. Loaded models stay in memory.")

            Menu {
                ForEach(controller.panes) { pane in
                    Button("Load \(pane.spec.displayName) — \(pane.spec.modelShortName)") {
                        controller.warmUp(pane.spec.id)
                    }
                }
            } label: {
                Label("Models", systemImage: "cpu")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pre-load weights so the first turn starts immediately")
        }
    }

    // MARK: Status

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColour)
                .frame(width: 8, height: 8)
            Text(status.label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
            if controller.isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }
            Text("· \(controller.turns.filter { $0.kind == .chat }.count) messages")
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }

    private var dotColour: Color {
        switch status {
        case .running: .green
        case .preparing: .yellow
        case .paused: .orange
        case .limitReached: .blue
        case .failed: .red
        case .idle, .stopped: .secondary
        }
    }

    // MARK: Notes

    private var notesMenu: some View {
        Menu {
            if controller.notices.isEmpty {
                Text("Nothing to report")
            } else {
                ForEach(Array(controller.notices.enumerated()), id: \.offset) { _, note in
                    Text(note)
                }
            }
        } label: {
            Label("\(controller.notices.count)", systemImage: "list.bullet.rectangle")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Engine notices: trimming, tool failures, turn limits")
    }
}

/// Moderator strip — one input, delivered to both models.
struct ModeratorBar: View {
    @ObservedObject var controller: ChatController

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Moderator", systemImage: "person.wave.2.fill")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(AgentTheme.moderatorTint)
                Text("Goes into the shared log — both models read it.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 170, alignment: .leading)

            TextField(
                "Ask both models something, redirect them, or call out a claim…",
                text: $controller.moderatorDraft,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
            .font(.system(size: 12.5))
            .onSubmit { controller.sendModeratorMessage() }

            Button {
                controller.sendModeratorMessage()
            } label: {
                Label("Send to both", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(AgentTheme.moderatorTint)
            .disabled(controller.moderatorDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
