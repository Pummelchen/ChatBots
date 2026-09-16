// ChatBotsApp — topic, transport controls and live status

import ChatBotsCore
import SwiftUI

struct ControlBar: View {
    @Environment(\.themePalette) private var palette
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var zoom: ZoomStore
    @EnvironmentObject private var endpoints: APIEndpointStore
    @ObservedObject var controller: ChatController
    @State private var showNotes = false
    @State private var showEndpoints = false
    @State private var showSaved = false
    @State private var showLineup = false
    @State private var showReport = false

    private var status: RunStatus { controller.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("Topic", systemImage: "text.bubble")
                    .scaledFont(size: 11, weight: .semibold, design: .rounded)
                    .foregroundStyle(palette.textSecondary)

                TextField("What should the models discuss?", text: $controller.topic)
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(size: 13)
                    .disabled(controller.isRunning)
                    .onSubmit { if controller.canStart { controller.startOrRestart() } }

                Picker("Mode", selection: modeBinding) {
                    ForEach(DiscussionMode.allCases) { mode in
                        Label(mode.label, systemImage: mode == .research ? "magnifyingglass" : "theatermasks")
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(controller.isRunning)
                .help("A show, or an investigation with a budget and a report")
            }

            // The actions have their own row. They used to share the topic's, which left eight
            // buttons competing with a text field for the width and every one of them collapsing
            // to an ellipsis: "St…", "Sa…", "K…", "Cl…". A control whose label cannot be read is
            // worse than no control, because the tooltip is the only way to find out what it
            // does and nobody hovers over a button they cannot identify.
            actionRow

            AttachmentBar(controller: controller)

            if let research = controller.research {
                researchBar(research)
            }

            HStack(spacing: 10) {
                statusPill
                audiencePill

                // Before the conversation starts, show what the two seats are configured
                // as. Afterwards the per-pane controls carry it and this would be noise.
                if controller.turns.isEmpty {
                    PersonaSummary(specs: controller.panes.map(\.spec), palette: palette)
                }

                Spacer(minLength: 0)

                Toggle(isOn: cloudOnlyBinding) {
                    Label("Cloud only", systemImage: "cloud")
                        .scaledFont(size: 11)
                        .lineLimit(1)
                        .fixedSize()
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Skip the local models entirely and route every seat through its API endpoint")

                Button {
                    showEndpoints = true
                } label: {
                    Label("API", systemImage: "network")
                        .scaledFont(size: 11)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Configure an OpenAI-compatible /v1 endpoint per seat")
                .sheet(isPresented: $showEndpoints) {
                    APIEndpointsSheet(controller: controller) { showEndpoints = false }
                        .environmentObject(endpoints)
                        // A sheet is a separate presentation context, so it does not
                        // inherit the window's environment objects.
                        .environmentObject(zoom)
                }

                Picker("Layout", selection: $theme.windowMode) {
                    ForEach(WindowMode.allCases) { mode in
                        Label(mode.shortLabel, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(
                    "\(theme.windowMode.label) — "
                        + (theme.windowMode == .split
                            ? "one pane per model"
                            : "one conversation, like a chat")
                )

                Picker("Theme", selection: $theme.mode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Original follows the Mac's appearance; Black is pure black")

                Toggle(isOn: $controller.showReasoning) {
                    Label("Show thinking", systemImage: "brain")
                        // One line: a wrapped toggle label makes the switch jump position
                        // as the text size changes.
                        .lineLimit(1)
                        .fixedSize()
                        .scaledFont(size: 11)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Stream the models' <think> blocks into their panes. Thinking is never part of the shared log.")

                notesMenu
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(palette.surface)
    }

    // MARK: Actions

    /// Everything that *does* something, on one line that is theirs.
    ///
    /// Grouped rather than run together — starting and stopping the conversation, then the things
    /// you do with the transcript — because eight undifferentiated buttons is a row you have to
    /// read every time.
    ///
    /// There used to be a "Models" menu here whose only action was `controller.warmUp(_:)`, a
    /// body that set `errorBanner = nil` and nothing else, under help text promising "Pre-load
    /// weights so the first turn starts immediately". A client cannot warm a seat — the engine
    /// loads weights on the first turn — so the control lied about what it did and was removed
    /// rather than left as a placeholder. Which model each seat runs is still shown,
    /// as `spec.backendLabel` in the seat's own pane header.
    private var actionRow: some View {
        HStack(spacing: 6) {
            transport
            Divider().frame(height: 16)
            transcriptActions
        }
    }

    /// Start, pause and stop: what the conversation is doing.
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
            .controlSize(.small)
            .disabled(!controller.canStart)
            .help("Load both models and begin the conversation")

            Button {
                controller.togglePause()
            } label: {
                Label(status.isPaused ? "Resume" : "Pause", systemImage: status.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!status.isActive && !status.isPaused)
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button {
                controller.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!status.isActive && !status.isPaused)
            .keyboardShortcut(".", modifiers: .command)
        }
    }

    /// Save, reopen, line-up, report, clear: what you do with the transcript.
    private var transcriptActions: some View {
        HStack(spacing: 6) {
            Button {
                controller.saveConversation()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(controller.turns.isEmpty)
            .help("Save the full conversation log to a text file")

            Button {
                showSaved = true
            } label: {
                Label("Kept", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reopen a conversation the engine kept, or start a new one")
            .sheet(isPresented: $showSaved) {
                SavedConversationsSheet(controller: controller) { showSaved = false }
                    // A sheet is a separate presentation context, so it does not inherit the
                    // window's environment objects.
                    .environmentObject(zoom)
            }

            Button {
                showLineup = true
            } label: {
                Label("Line-up", systemImage: "person.3.sequence")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Choose who is in the room, or let the app choose")
            .sheet(isPresented: $showLineup) {
                LineupSheet(controller: controller) { showLineup = false }
                    .environmentObject(zoom)
            }

            if controller.report != nil {
                Button {
                    showReport = true
                } label: {
                    Label("Report", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("The report the investigation produced")
                .sheet(isPresented: $showReport) {
                    ReportSheet(controller: controller) { showReport = false }
                        .environmentObject(zoom)
                }
            }

            Button {
                controller.reset()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(controller.isRunning)
            .help("Forget the transcript. Loaded models stay in memory.")
        }
    }

    // MARK: Status

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColour)
                .frame(width: 8, height: 8)
            Text(status.label)
                .scaledFont(size: 11, weight: .medium, design: .rounded)
            if controller.isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }
            Text("· \(controller.turns.filter { $0.kind == .chat }.count) messages")
                .scaledFont(size: 10.5, design: .rounded)
                .foregroundStyle(palette.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(palette.raised, in: Capsule())
    }

    /// The audience's scorecard, once anyone has voted.
    private var audiencePill: some View {
        AudienceScorecardView(controller: controller)
    }

    /// The mode picker writes through to the engine, which owns the answer.
    private var modeBinding: Binding<DiscussionMode> {
        Binding(get: { controller.mode }, set: { controller.setMode($0) })
    }

    /// Where a research session has got to, and how hard it is looking.
    ///
    /// Shown only while there is a research session, which is the one case where the numbers
    /// mean anything: a budget with no session behind it is a control that does nothing.
    private func researchBar(_ research: APISnapshot.ResearchStatus) -> some View {
        HStack(spacing: 8) {
            Text(research.depth)
                .scaledFont(size: 10, weight: .bold)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(palette.raised, in: Capsule())
            Text(research.statusLine)
                .scaledFont(size: 11, design: .rounded)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !research.isFinished {
                Picker("Depth", selection: depthBinding) {
                    ForEach(ResearchBudget.Depth.allCases) { depth in
                        Text(depth.label).tag(depth)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(controller.isRunning)
                .help("How hard the analysts look before concluding")
            }
        }
    }

    private var depthBinding: Binding<ResearchBudget.Depth> {
        Binding(
            get: { ResearchBudget.Depth(rawValue: controller.research?.depth.lowercased() ?? "") ?? .standard },
            set: { controller.setResearchDepth($0) })
    }

    private var cloudOnlyBinding: Binding<Bool> {
        Binding(
            get: { controller.isCloudOnly },
            set: { controller.useAPIForAllSeats($0, store: endpoints) }
        )
    }

    private var dotColour: Color {
        switch status {
        case .running: AgentTheme.ok
        case .preparing: AgentTheme.warning
        case .paused: AgentTheme.warning
        case .limitReached: AgentTheme.tint(for: "Agent B", palette: palette)
        case .failed: AgentTheme.failure
        case .idle, .stopped: AgentTheme.dotIdle(palette)
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
                .scaledFont(size: 11)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Engine notices: trimming, tool failures, turn limits")
    }
}

/// Moderator strip — one input, delivered to both models.
struct ModeratorBar: View {
    @Environment(\.themePalette) private var palette
    @EnvironmentObject private var zoom: ZoomStore
    @ObservedObject var controller: ChatController
    @State private var showIdentity = false

    /// The human's own name, so the bar says who is speaking rather than only what the role is.
    private var who: String {
        let name = controller.lastSnapshot?.moderatorName ?? ModeratorIdentity.defaultName
        let persona = controller.lastSnapshot?.moderatorPersona ?? "Neutral"
        return persona == "Neutral" ? name : "\(name) · \(persona)"
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Label(who, systemImage: "person.wave.2.fill")
                        .scaledFont(size: 10.5, weight: .semibold, design: .rounded)
                        .foregroundStyle(AgentTheme.moderatorTint(palette))
                        .lineLimit(1)
                    Button {
                        showIdentity = true
                    } label: {
                        Image(systemName: "pencil")
                            .scaledFont(size: 9)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.textTertiary)
                    .help("Set your name, and how your interjections read")
                    .sheet(isPresented: $showIdentity) {
                        ModeratorIdentitySheet(controller: controller) { showIdentity = false }
                            .environmentObject(zoom)
                    }
                }
                Text("Goes into the shared log — every participant reads it.")
                    .scaledFont(size: 9.5)
                    .foregroundStyle(palette.textTertiary)
            }
            .frame(width: 170, alignment: .leading)

            TextField(
                "Ask both models something, redirect them, or call out a claim…",
                text: $controller.moderatorDraft,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
            .scaledFont(size: 12.5)
            .onSubmit { controller.sendModeratorMessage() }

            Button {
                controller.sendModeratorMessage()
            } label: {
                Label("Send to both", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(AgentTheme.moderatorTint(palette))
            .disabled(controller.moderatorDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(palette.surface)
    }
}
