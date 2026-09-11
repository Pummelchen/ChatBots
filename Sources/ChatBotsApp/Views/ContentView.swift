// ChatBotsApp — window layout: two horizontal panes, controls above and below

import ChatBotsCore
import SwiftUI

struct ContentView: View {
    @Environment(\.themePalette) private var palette
    @ObservedObject var controller: ChatController

    var body: some View {
        VStack(spacing: 0) {
            ControlBar(controller: controller)
            Divider()
            AgentPanes(controller: controller)
            Divider()
            ModeratorBar(controller: controller)
        }
        // Minimums only — no maximum — so the window can be dragged to any size.
        .frame(minWidth: 720, idealWidth: 1280, minHeight: 480, idealHeight: 780)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = controller.errorBanner {
                ErrorBanner(message: message) { controller.errorBanner = nil }
            }
        }
    }
}

/// The two seats, side by side.
///
/// `HSplitView` keeps the panes independently resizable while still reading as one
/// surface; the model-free header of each pane is what makes "which LLM said this"
/// unambiguous, which is the whole point of running two instances separately.
struct AgentPanes: View {
    @ObservedObject var controller: ChatController

    private var pending: Set<UUID> { controller.pendingSteeringIDs }

    var body: some View {
        HSplitView {
            ForEach(controller.panes) { pane in
                ChatPane(
                    pane: pane,
                    controller: controller,
                    turns: controller.turns,
                    pendingSteeringIDs: pending,
                    showReasoning: controller.showReasoning,
                    contextEstimate: controller.contextEstimate
                )
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12))
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
    }
}
