// ChatBotsApp — window layout: two horizontal panes, controls above and below

import ChatBotsCore
import SwiftUI

struct ContentView: View {
    @Environment(\.themePalette) private var palette
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var zoom: ZoomStore
    @ObservedObject var controller: ChatController

    @State private var hud: Int?
    @State private var hudDismissal: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            ControlBar(controller: controller)
            Divider()
            ConversationLayout(controller: controller, mode: theme.windowMode)
            Divider()
            ModeratorBar(controller: controller)
        }
        // Minimums only — no maximum — so the window can be dragged to any size.
        // Minimums only — no maximum — so the window can be dragged to any size. The floor
        // rises with the text size, since a window that fits at 100% clips at 200%.
        .frame(
            minWidth: zoom.minimumWindowSize.width, idealWidth: 1280,
            minHeight: zoom.minimumWindowSize.height, idealHeight: 780
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            // The connection state is shown here too. It was set on every failure and never
            // displayed anywhere, so an engine that could not be reached, or one whose live
            // updates had stopped, looked exactly like a conversation nobody had started: the
            // window simply sat there saying "Nothing yet" and offered no reason.
            if let message = controller.errorBanner {
                ErrorBanner(message: message) { controller.errorBanner = nil }
            } else if let connection = controller.engineConnection {
                ErrorBanner(message: connection) { controller.clearConnectionMessage() }
            }
        }
        .overlay(alignment: .top) {
            if let hud {
                ZoomHUD(percent: hud)
                    .padding(.top, 90)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        // Report the new size, then fade. `onChange` only fires on a change, so the saved
        // setting being restored at launch shows nothing — there is no need to test the
        // previous value, which the compiler rightly pointed out was never nil.
        .onChange(of: zoom.percent) { _, current in
            hudDismissal?.cancel()
            withAnimation(.easeOut(duration: 0.12)) { hud = current }
            hudDismissal = Task {
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.25)) { hud = nil }
            }
        }
    }
}

/// Swaps the conversation between the two window modes.
///
/// Both modes render the same shared log from the same controller; only the arrangement
/// differs, so switching mid-conversation is lossless and instant.
struct ConversationLayout: View {
    @ObservedObject var controller: ChatController
    let mode: WindowMode

    var body: some View {
        switch mode {
        case .split:
            AgentPanes(controller: controller)
        case .unified:
            UnifiedConversation(controller: controller)
        }
    }
}

/// The seats, laid out for however many there are.
///
/// The arrangement is chosen from the roster size and the space available:
///
/// * one seat fills the window;
/// * two go side by side when there is room, which is the app's familiar shape;
/// * more than two form a grid — three across in a wide window, otherwise two columns and
///   two rows for four seats.
///
/// The point is that a pane never drops below a legible width, because four panes squeezed
/// side by side in a 1500pt window are 370pt each and unreadable. `HSplitView`/`VSplitView`
/// cannot express a grid, so a plain `Grid` does the work and the panes divide the space
/// evenly. Dragging dividers is given up in exchange for a layout that survives a larger
/// roster; the unified window mode remains the best view for three or four seats.
struct AgentPanes: View {
    @Environment(\.themePalette) private var palette
    @ObservedObject var controller: ChatController

    /// Width below which a pane stops being comfortable to read.
    ///
    /// 380 is enough for the transcript and for the header's compact form, and it is what
    /// decides the column count: 1240pt of window fits three of them, not four.
    private static let comfortablePaneWidth: CGFloat = 380

    var body: some View {
        GeometryReader { geometry in
            // Built here rather than in `body` so the branch is on the *count*, and the
            // panes keep a stable identity across a resize that changes the column count.
            let panes = controller.panes
            if panes.count <= 2 {
                if panes.count == 1 {
                    pane(panes[0], width: geometry.size.width)
                } else if usesColumns(for: 2, in: geometry.size.width) {
                    HSplitView { ForEach(panes) { pane($0, width: geometry.size.width / 2) } }
                } else {
                    VSplitView { ForEach(panes) { pane($0, width: geometry.size.width) } }
                }
            } else {
                grid(panes, in: geometry.size.width)
            }
        }
    }

    /// Even grid of equal cells.
    ///
    /// Built from explicit stacks rather than `Grid`: `Grid` sizes columns to their
    /// content, which let a wider header push its column past the window edge and left the
    /// columns visibly unequal. Nested stacks with a known cell width are deterministic.
    private func grid(_ panes: [AgentPaneState], in width: CGFloat) -> some View {
        let columns = columnCount(for: panes.count, in: width)
        let rows = Int(ceil(Double(panes.count) / Double(columns)))
        let cellWidth = max(1, (width - CGFloat(columns - 1)) / CGFloat(columns))

        return VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { row in
                if row > 0 {
                    Rectangle()
                        .fill(palette.border)
                        .frame(height: 1)
                }
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < panes.count {
                            if column > 0 {
                                Rectangle()
                                    .fill(palette.border)
                                    .frame(width: 1)
                            }
                            pane(panes[index], width: cellWidth)
                        }
                    }
                    // Keeps a short final row aligned with the columns above it.
                    if row * columns + columns > panes.count {
                        ForEach(0..<(row * columns + columns - panes.count), id: \.self) { _ in
                            Color.clear.frame(width: cellWidth)
                        }
                    }
                }
                .frame(height: nil)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func pane(_ state: AgentPaneState, width: CGFloat) -> some View {
        ChatPane(
            pane: state,
            controller: controller,
            turns: controller.turns,
            pendingSteeringIDs: controller.pendingSteeringIDs,
            showReasoning: controller.showReasoning
        )
        .frame(width: width)
        .frame(maxHeight: .infinity)
    }

    private func usesColumns(for count: Int, in width: CGFloat) -> Bool {
        width / CGFloat(count) >= Self.comfortablePaneWidth
    }

    /// The fewest columns that still leave every pane at a legible width, capped at the
    /// number of panes. Falls back to one column when even that is too narrow.
    private func columnCount(for count: Int, in width: CGFloat) -> Int {
        let affordable = max(1, Int(width / Self.comfortablePaneWidth))
        return max(1, min(count, affordable))
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AgentTheme.failure)
            Text(message)
                .scaledFont(size: 12)
                .foregroundStyle(palette.text)
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(AgentTheme.failure.opacity(0.18))
    }
}
