// ChatBotsApp — choosing who is in the room, and what they are in front of
//
// One sheet for both, because they are one decision. A panel of statisticians is the wrong room
// for "is a hotdog a sandwich" and the right one for whether a trial design supports its claim,
// so a picker that offered line-ups and questions separately would be offering half a choice.
//
// The libraries come from the engine rather than being written here, so a line-up added to the
// core appears in the app and the browser without either being rebuilt — and the two cannot
// disagree about what the presets are.

import ChatBotsCore
import SwiftUI

struct LineupSheet: View {
    @EnvironmentObject private var zoom: ZoomStore
    @ObservedObject var controller: ChatController
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    section("Line-ups")
                    randomRow
                    ForEach(controller.rosters) { roster in
                        row(
                            title: roster.name,
                            note: roster.summary,
                            who: roster.personaIDs.joined(separator: " · "),
                            action: {
                                controller.applyRoster(id: roster.id)
                                dismiss()
                            })
                    }

                    section("Scenarios")
                    ForEach(controller.scenarios) { scenario in
                        row(
                            title: scenario.topic,
                            note: scenario.note,
                            who: scenario.depth.map { "budget: \($0.label)" } ?? "",
                            action: {
                                controller.applyScenario(id: scenario.id)
                                dismiss()
                            })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            Divider()
            footer
        }
        .frame(width: 620 * zoom.scale, height: 560 * zoom.scale)
        .onAppear { controller.refreshLineup() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.3.sequence")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Line-up")
                    .scaledFont(size: 13, weight: .semibold)
                Text(
                    controller.mode == .research
                        ? "Research panels. A scenario sets the question, the panel and the budget together."
                        : "Character combinations. A scenario sets the question and the room together."
                )
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .scaledFont(size: 10, weight: .bold)
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    private var randomRow: some View {
        row(
            title: "Surprise me — a random room",
            note:
                "Drawn from every participant in this mode. The seed is reported in the log, so the draw can be repeated and shared.",
            who: "",
            action: {
                controller.applyRoster(id: RosterLibrary.randomID)
                dismiss()
            })
    }

    private func row(
        title: String, note: String, who: String, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(size: 12, weight: .semibold)
                Text(note)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !who.isEmpty {
                    Text(who)
                        .scaledFont(size: 10, design: .monospaced)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button("Apply", action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!controller.canChangeLineup)
                .help(
                    controller.canChangeLineup
                        ? "Put this in place"
                        : "Who is in the room cannot be changed once the conversation has started")
        }
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !controller.canChangeLineup {
                Text("Stop the conversation to change who is in the room.")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}
