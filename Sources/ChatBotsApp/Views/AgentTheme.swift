// ChatBotsApp — colours and small formatting helpers

import ChatBotsCore
import SwiftUI

enum AgentTheme {
    /// Deterministic tint per seat, so adding a third LLM later just works.
    static func tint(for agentID: String) -> Color {
        switch agentID {
        case "Agent A": .teal
        case "Agent B": .indigo
        case "Agent C": .orange
        case "Agent D": .pink
        default: .accentColor
        }
    }

    static func symbol(for agentID: String) -> String {
        switch agentID {
        case "Agent A": "a.circle.fill"
        case "Agent B": "b.circle.fill"
        case "Agent C": "c.circle.fill"
        case "Agent D": "d.circle.fill"
        default: "circle.fill"
        }
    }

    static let moderatorTint = Color.orange
    static let systemTint = Color.secondary
    static let toolTint = Color.purple
}

extension Turn {
    var tint: Color {
        switch kind {
        case .topic, .steering: AgentTheme.moderatorTint
        case .introduction: AgentTheme.systemTint
        case .tool: AgentTheme.toolTint
        case .chat: speakerID.map(AgentTheme.tint(for:)) ?? .accentColor
        }
    }

    var badge: String {
        switch kind {
        case .topic: "TOPIC"
        case .steering: "MODERATOR"
        case .introduction: "SETUP"
        case .tool: "TOOL"
        case .chat: speakerName.uppercased()
        }
    }

    var symbol: String {
        switch kind {
        case .topic: "questionmark.bubble.fill"
        case .steering: "person.wave.2.fill"
        case .introduction: "info.circle.fill"
        case .tool: "globe"
        case .chat: speakerID.map(AgentTheme.symbol(for:)) ?? "bubble.fill"
        }
    }
}

enum Format {
    static func tokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }

    static func rate(_ stats: TurnStats) -> String {
        String(format: "%.1f tok/s · %d tok · %.1fs", stats.tokensPerSecond, stats.generationTokens, stats.seconds)
    }

    /// First sentence-ish summary, for collapsed rows.
    static func summarise(_ text: String, limit: Int = 90) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}
