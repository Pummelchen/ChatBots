// ChatBotsApp — the setup brief, shown collapsed above the thread
//
// Split out of `UnifiedConversation.swift`, which held the window mode and every row type in one
// 583-line file. The brief is the topic and the instructions both models received, and it is shown
// once rather than as a message.

import ChatBotsCore
import SwiftUI

/// The setup brief, shown once at the top of the thread and collapsed by default.
struct SetupBlock: View {
    @Environment(\.themePalette) private var palette
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .scaledFont(size: 9, weight: .bold)
                    Image(systemName: "info.circle")
                        .scaledFont(size: 10)
                    Text("Setup — the topic and the brief both models received")
                        .scaledFont(size: 10.5, design: .rounded)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .scaledFont(size: 11)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.raised, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
