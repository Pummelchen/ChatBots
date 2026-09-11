// ChatBotsApp — colours and small formatting helpers

import ChatBotsCore
import SwiftUI

/// Which palette the app draws with.
///
/// `.original` is the default and follows the Mac's own appearance. `.black` is the
/// opt-in high-contrast theme: true black everywhere, which is what you want on an OLED
/// display or in a dark room.
enum ThemeMode: String, CaseIterable, Identifiable, Sendable {
    case original
    case black

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .original: "Original"
        case .black: "Black"
        }
    }

    var symbol: String {
        switch self {
        case .original: "circle.lefthalf.filled"
        case .black: "circle.fill"
        }
    }
}

/// Every colour the UI draws with, resolved for one theme.
///
/// The original palette uses dynamic system colours, so text and surfaces follow the
/// Mac's appearance and materials blend with the window. The black palette replaces them
/// with flat values, because a material over black reads as muddy grey and a semantic
/// colour would flip to dark ink on a black pane in light mode.
struct AppPalette: Sendable {
    /// Pane background.
    let background: Color
    /// Lifted panels: pane headers, control bar, moderator bar, footers.
    let surface: Color
    /// Raised elements inside a panel: chips, badges, reasoning blocks.
    let raised: Color
    /// Hairlines, where a plain `Divider` would disappear.
    let border: Color

    /// Wrapped so the original theme can use the semantic `.primary`/`.secondary`/
    /// `.tertiary` hierarchy, which is a `ShapeStyle` rather than a `Color`.
    let text: AnyShapeStyle
    let textSecondary: AnyShapeStyle
    let textTertiary: AnyShapeStyle

    /// Whether the window chrome should be forced dark.
    let forcesDarkChrome: Bool
    /// Whether the original materials (`.bar`) can be used for panels.
    let usesMaterials: Bool

    /// The original scheme, tracking the system appearance.
    static let original = AppPalette(
        background: Color(nsColor: .textBackgroundColor),
        surface: Color.primary.opacity(0.045),
        raised: Color.primary.opacity(0.07),
        border: Color.primary.opacity(0.12),
        text: AnyShapeStyle(.primary),
        textSecondary: AnyShapeStyle(.secondary),
        textTertiary: AnyShapeStyle(.tertiary),
        forcesDarkChrome: false,
        usesMaterials: true,
        isBlack: false
    )

    /// Plain black, top to bottom.
    static let black = AppPalette(
        background: .black,
        surface: Color(white: 0.055),
        raised: Color(white: 0.11),
        border: Color(white: 0.20),
        text: AnyShapeStyle(Color(white: 0.95)),
        textSecondary: AnyShapeStyle(Color(white: 0.62)),
        textTertiary: AnyShapeStyle(Color(white: 0.40)),
        forcesDarkChrome: true,
        usesMaterials: false,
        isBlack: true
    )

    static func resolve(_ mode: ThemeMode) -> AppPalette {
        switch mode {
        case .original: .original
        case .black: .black
        }
    }

    /// True for the black theme. Used for the handful of places that need to branch on
    /// the theme rather than read a colour.
    let isBlack: Bool

    /// A panel background: the system material where it is appropriate, flat otherwise.
    var panelBackground: AnyShapeStyle {
        usesMaterials ? AnyShapeStyle(.bar) : AnyShapeStyle(surface)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: AppPalette = .original
}

extension EnvironmentValues {
    /// Named `themePalette` rather than `palette` so it cannot collide with a
    /// `.palette(_:)` view modifier or a local `palette` binding.
    var themePalette: AppPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension View {
    /// Injects the resolved palette for the whole subtree.
    func themePalette(_ palette: AppPalette) -> some View {
        environment(\.themePalette, palette)
    }
}

/// Persisted theme choice. Kept in `AppStorage` so the choice survives relaunch.
@MainActor
final class ThemeStore: ObservableObject {
    @AppStorage("themeMode") var mode: ThemeMode = .original

    var palette: AppPalette { AppPalette.resolve(mode) }

    func toggle() {
        mode = mode == .original ? .black : .original
    }
}

enum AgentTheme {
    /// Deterministic tint per seat, so adding a third LLM later just works.
    ///
    /// The black palette overrides two of these: the system `.teal` and `.indigo` are
    /// too dim against pure black at small sizes.
    static func tint(for agentID: String, palette: AppPalette) -> Color {
        switch agentID {
        case "Agent A":
            palette.isBlack ? Color(red: 0.29, green: 0.87, blue: 0.83) : .teal
        case "Agent B":
            palette.isBlack ? Color(red: 0.55, green: 0.62, blue: 1.00) : .indigo
        case "Agent C":
            .orange
        case "Agent D":
            .pink
        default:
            .accentColor
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

    static func moderatorTint(_ palette: AppPalette) -> Color {
        palette.isBlack ? Color(red: 1.00, green: 0.72, blue: 0.30) : .orange
    }

    static func systemTint(_ palette: AppPalette) -> AnyShapeStyle {
        palette.isBlack ? AnyShapeStyle(Color(white: 0.55)) : AnyShapeStyle(.secondary)
    }

    /// Idle status dot: a concrete colour, because it is chosen in a ternary with
    /// another `Color`.
    static func dotIdle(_ palette: AppPalette) -> Color {
        palette.isBlack ? Color(white: 0.40) : Color.secondary
    }

    static func toolTint(_ palette: AppPalette) -> Color {
        palette.isBlack ? Color(red: 0.78, green: 0.62, blue: 1.00) : .purple
    }

    static let ok = Color.green
    static let warning = Color.orange
    static let failure = Color.red
}

extension Turn {
    func tint(_ palette: AppPalette) -> AnyShapeStyle {
        switch kind {
        case .topic, .steering: AnyShapeStyle(AgentTheme.moderatorTint(palette))
        case .introduction: AgentTheme.systemTint(palette)
        case .tool: AnyShapeStyle(AgentTheme.toolTint(palette))
        case .chat:
            speakerID.map { AnyShapeStyle(AgentTheme.tint(for: $0, palette: palette)) }
                ?? palette.textSecondary
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
