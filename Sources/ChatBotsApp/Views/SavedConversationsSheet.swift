// ChatBotsApp — reopening a conversation the engine kept
//
// Every conversation the engine runs is written to disk as it goes and kept afterwards, so the
// work of an investigation survives the window being closed. Until now nothing could get one
// back: the files were there and the engine could list and load them, and neither front end
// asked. This is that missing half.
//
// Loading is refused while a turn is generating, and the refusal comes from the engine rather
// than being re-implemented here — swapping the transcript out from under a turn in flight is
// the engine's rule to make, and a front end that made its own copy of the rule would end up
// disagreeing with it.

import ChatBotsCore
import SwiftUI

struct SavedConversationsSheet: View {
    @EnvironmentObject private var zoom: ZoomStore
    @ObservedObject var controller: ChatController
    let dismiss: () -> Void

    @State private var confirmingDelete: SavedConversationSummary?
    @State private var confirmingNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 600 * zoom.scale, height: 520 * zoom.scale)
        .onAppear { controller.refreshSavedConversations() }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }),
            presenting: confirmingDelete
        ) { item in
            Button("Delete", role: .destructive) {
                controller.deleteSavedConversation(id: item.id)
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: { item in
            Text("\"\(item.topic.isEmpty ? "Untitled" : item.topic)\" and its \(item.replies) messages will be removed from disk. This cannot be undone.")
        }
        .confirmationDialog(
            "Start a new conversation?",
            isPresented: $confirmingNew
        ) {
            Button("Start new", role: .destructive) {
                controller.beginNewConversation()
                confirmingNew = false
                dismiss()
            }
            Button("Cancel", role: .cancel) { confirmingNew = false }
        } message: {
            Text("The current transcript is cleared from the screen. The engine has already kept it, so it stays in this list.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kept conversations")
                    .scaledFont(size: 13, weight: .semibold)
                Text("Written to disk as the conversation runs. The most recent \(ConversationStore.maximumKept) are kept.")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                controller.refreshSavedConversations()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .scaledFont(size: 11)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if controller.savedConversations.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .scaledFont(size: 22)
                    .foregroundStyle(.secondary)
                Text("Nothing kept yet")
                    .scaledFont(size: 12, weight: .medium)
                Text("A conversation is kept as soon as it starts and stays after the window closes.")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.savedConversations) { item in
                        row(item)
                        Divider()
                    }
                }
            }
        }
    }

    private func row(_ item: SavedConversationSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.topic.isEmpty ? "Untitled" : item.topic)
                    .scaledFont(size: 12, weight: .semibold)
                    .lineLimit(2)
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("\(item.replies) messages · \(Self.stamp(item.updatedAt))")
                    .scaledFont(size: 10, design: .rounded)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    controller.loadSavedConversation(id: item.id)
                    dismiss()
                } label: {
                    Label("Open", systemImage: "arrow.down.doc")
                        .scaledFont(size: 11)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!controller.canLoadSavedConversation)
                .help(
                    controller.canLoadSavedConversation
                        ? "Replace what is on screen with this conversation"
                        : "Stop the conversation before opening another one")

                Button {
                    confirmingDelete = item
                } label: {
                    Label("Delete", systemImage: "trash")
                        .scaledFont(size: 11)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                confirmingNew = true
            } label: {
                Label("New conversation", systemImage: "plus")
                    .scaledFont(size: 11)
            }
            .buttonStyle(.bordered)
            .disabled(!controller.canLoadSavedConversation)
            .help("Clear the screen and begin again. The engine keeps what is there now.")
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    /// A date a reader can place without reading a timestamp: today, yesterday, or the date.
    static func stamp(_ date: Date, now: Date = Date.now) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if calendar.isDateInToday(date) {
            formatter.dateStyle = .none
            return formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            formatter.dateStyle = .none
            return "Yesterday \(formatter.string(from: date))"
        }
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
