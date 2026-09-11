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

/// How the conversation is laid out.
enum WindowMode: String, CaseIterable, Identifiable, Sendable {
    /// One pane per seat, side by side. Each seat keeps its own scroll position.
    case split
    /// A single conversation, newest at the bottom, like a messaging app.
    case unified

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .split: "Side by side"
        case .unified: "Single thread"
        }
    }

    var shortLabel: String {
        switch self {
        case .split: "Split"
        case .unified: "Thread"
        }
    }

    var symbol: String {
        switch self {
        case .split: "rectangle.split.2x1"
        case .unified: "bubble.left.and.bubble.right"
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
    @AppStorage("windowMode") var windowMode: WindowMode = .split

    var palette: AppPalette { AppPalette.resolve(mode) }

    func toggle() {
        mode = mode == .original ? .black : .original
    }
}

enum AgentTheme {
    /// One tint per seat position, so a seat's colour is stable no matter what it is
    /// called and adding a seat never collides with an existing one.
    ///
    /// The black palette needs stronger values: the system `.teal` and `.indigo` are
    /// nearly invisible against pure black at small sizes.
    static func tint(forSeat index: Int, palette: AppPalette) -> Color {
        let normal: [Color] = [.teal, .indigo, .orange, .pink, .purple, .green]
        let onBlack: [Color] = [
            Color(red: 0.29, green: 0.87, blue: 0.83),
            Color(red: 0.55, green: 0.62, blue: 1.00),
            Color(red: 1.00, green: 0.66, blue: 0.30),
            Color(red: 1.00, green: 0.55, blue: 0.75),
            Color(red: 0.78, green: 0.62, blue: 1.00),
            Color(red: 0.45, green: 0.88, blue: 0.60),
        ]
        let ramp = palette.isBlack ? onBlack : normal
        return ramp[((index % ramp.count) + ramp.count) % ramp.count]
    }

    /// Tint by id, for callers that only have a speaker id from the transcript. Matches
    /// the `Agent N` form; anything else falls back to the neutral text colour.
    static func tint(for agentID: String, palette: AppPalette) -> Color {
        guard let index = seatIndex(in: agentID) else {
            return palette.isBlack ? Color(white: 0.62) : Color.secondary
        }
        return tint(forSeat: index, palette: palette)
    }

    /// `"Agent 3"` → `2`. Nil when the id is not in that form.
    static func seatIndex(in agentID: String) -> Int? {
        guard agentID.hasPrefix("Agent ") else { return nil }
        let suffix = agentID.dropFirst("Agent ".count)
        guard let number = Int(suffix), number >= 1 else { return nil }
        return number - 1
    }

    /// One symbol per seat position, cycling if there are more seats than symbols.
    static func symbol(forSeat index: Int) -> String {
        let symbols = [
            "a.circle.fill", "b.circle.fill", "c.circle.fill", "d.circle.fill",
            "e.circle.fill", "f.circle.fill",
        ]
        return symbols[((index % symbols.count) + symbols.count) % symbols.count]
    }

    /// Symbol by id; see `tint(for:palette:)` for the fallback rule.
    static func symbol(for agentID: String) -> String {
        guard let index = seatIndex(in: agentID) else { return "circle.fill" }
        return symbol(forSeat: index)
    }

    static func moderatorTint(_ palette: AppPalette) -> Color {
        palette.isBlack ? Color(red: 1.00, green: 0.72, blue: 0.30) : .orange
    }

    /// The report of a research session. Its own tint because it is the deliverable rather
    /// than a voice in the conversation: it should not read as one more participant.
    static func reportTint(_ palette: AppPalette) -> AnyShapeStyle {
        AnyShapeStyle(
            palette.isBlack ? Color(white: 0.62) : Color(red: 0.30, green: 0.40, blue: 0.52))
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
    /// The turn's colour.
    ///
    /// - Parameter seatIndex: the speaker's position, when the caller knows it. Passing it
    ///   is preferred because it is exact; otherwise the id is parsed.
    func tint(_ palette: AppPalette, seatIndex: Int? = nil) -> AnyShapeStyle {
        switch kind {
        case .topic, .steering, .direction: AnyShapeStyle(AgentTheme.moderatorTint(palette))
        case .introduction, .summary: AgentTheme.systemTint(palette)
        case .report: AgentTheme.reportTint(palette)
        case .tool: AnyShapeStyle(AgentTheme.toolTint(palette))
        case .chat:
            if let seatIndex {
                AnyShapeStyle(AgentTheme.tint(forSeat: seatIndex, palette: palette))
            } else {
                speakerID.map { AnyShapeStyle(AgentTheme.tint(for: $0, palette: palette)) }
                    ?? palette.textSecondary
            }
        }
    }

    var badge: String {
        switch kind {
        case .topic: "\(speakerName.uppercased()) · TOPIC"
        case .steering: speakerName.uppercased()
        case .direction: "ASSIGNMENT"
        case .introduction: "SETUP"
        case .summary: "CONDENSED"
        case .report: "REPORT"
        case .tool: "TOOL"
        case .chat: speakerName.uppercased()
        }
    }

    var symbol: String {
        switch kind {
        case .topic: "questionmark.bubble.fill"
        case .steering: "person.wave.2.fill"
        case .direction: "arrow.right.circle.fill"
        case .introduction: "info.circle.fill"
        case .summary: "arrow.triangle.2.circlepath"
        case .report: "doc.text.magnifyingglass"
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

    /// Context occupancy, with the compaction threshold marked so the reader can see how
    /// close the log is to being condensed.
    static func context(tokens used: Int, of window: Int, compactAt: Double) -> String {
        guard window > 0 else { return "ctx \(tokens(used))" }
        let percent = Int(Double(used) / Double(window) * 100)
        return "ctx \(tokens(used))/\(tokens(window)) · \(percent)% (condense at \(Int(compactAt * 100))%)"
    }

    /// Generation and prefill side by side.
    ///
    /// Prefill is worth showing: it is an order of magnitude faster than generation per
    /// token on this hardware (measured ~310 tok/s against ~28), so on a long shared log
    /// the wait before the first token is a large part of the turn.
    static func rates(_ stats: TurnStats) -> String {
        var text = String(format: "gen %.1f tok/s", stats.tokensPerSecond)
        if stats.prefillSeconds > 0 {
            text += String(format: " · prefill %.0f tok/s", stats.prefillTokensPerSecond)
        }
        return text
    }

    /// First sentence-ish summary, for collapsed rows.
    static func summarise(_ text: String, limit: Int = 90) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}
