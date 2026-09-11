// ChatBotsApp — the matrix of shared conversation rows

import ChatBotsCore
import SwiftUI

/// One logged turn, rendered the same way in both panes.
///
/// Both panes draw the *shared* log: the moderator's messages and each model's
/// messages appear identically on both sides. Only the active seat adds a live,
/// in-progress row underneath.
struct TurnRow: View {
    let turn: Turn
    let isOwn: Bool
    let isPending: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: turn.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(turn.tint)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(turn.badge)
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(turn.tint)
                    if isOwn {
                        Text("YOU")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(turn.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(turn.tint)
                    }
                    if isPending {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                            Text("queued")
                        }
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                }

                Text(turn.content)
                    .font(.system(size: 12.5, design: .default))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let detail = turn.toolDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(turn.tint.opacity(isOwn ? 0.10 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(turn.tint.opacity(isOwn ? 0.45 : 0.15), lineWidth: isOwn ? 1.2 : 0.7)
        )
        .opacity(isPending ? 0.65 : 1)
    }
}

/// Collapsible chain-of-thought block. Never written to the log, only shown live.
struct ReasoningBlock: View {
    let text: String
    let tint: Color
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                    Text(expanded ? "Thinking" : "Thinking — \(Format.summarise(text, limit: 60))")
                        .font(.system(size: 11, design: .rounded))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// A model that is mid-generation but has not produced visible text yet.
struct WaitingRow: View {
    let name: String
    let tint: Color
    let activity: String
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("\(name) \(activity.isEmpty ? "is thinking" : activity)")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
