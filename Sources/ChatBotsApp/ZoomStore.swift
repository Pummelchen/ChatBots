// ChatBotsApp — text size for the whole app
//
// SwiftUI on macOS has no Dynamic Type, so ⌘+ and ⌘− need an explicit scale that every
// piece of text respects. Two things make that more than a font size:
//
//   * **Layout has to follow.** Scaling text inside fixed-width rows clips labels and
//     overlaps controls, so spacing and the few fixed dimensions scale through the same
//     store rather than being left behind at their original size.
//   * **It has to persist.** A text size is a preference like any other, so it is stored
//     and restored — see `UserSettings`.
//
// The scale is applied by a view modifier that reads the environment, so a change
// republishes and every scaled font in the hierarchy updates together.

import ChatBotsCore
import SwiftUI

@MainActor
final class ZoomStore: ObservableObject {

    /// The steps ⌘+ and ⌘− move through.
    ///
    /// The list and every comparison over it live in `ChatBotsCore.TextZoom`, so the suite that
    /// covers them asserts the code the app runs rather than a copy of it. These are aliases
    /// kept so the views that read them read the same values.
    static let levels = TextZoom.levels
    static let `default` = TextZoom.default
    static var minimumScale: Double { TextZoom.minimumScale }
    static var maximumScale: Double { TextZoom.maximumScale }

    @AppStorage("textScale") private var storedScale: Double = TextZoom.default

    var scale: Double {
        get { storedScale }
        set { storedScale = TextZoom.clamped(newValue) }
    }

    var percent: Int { TextZoom.percent(of: scale) }
    /// 100, for comparing against `percent`.
    var resetPercent: Int { TextZoom.percent(of: TextZoom.default) }
    var canEnlarge: Bool { scale < Self.maximumScale - TextZoom.tolerance }
    var canReduce: Bool { scale > Self.minimumScale + TextZoom.tolerance }

    /// Move one step, in the direction of `larger`.
    func step(larger: Bool) {
        scale = TextZoom.stepped(from: scale, larger: larger)
    }

    func reset() { scale = TextZoom.default }

    /// The scale ⌘+ would go to, as a percentage, or `nil` at the top of the range.
    ///
    /// The menu reads these to say what ⌘+ will do rather than only what it is called; `nil` is also
    /// when its item is disabled, so the label and the button cannot disagree.
    var nextLargerPercent: Int? {
        TextZoom.next(from: scale, larger: true).map(TextZoom.percent(of:))
    }

    /// The scale ⌘− would go to, as a percentage, or `nil` at the bottom of the range.
    var nextSmallerPercent: Int? {
        TextZoom.next(from: scale, larger: false).map(TextZoom.percent(of:))
    }

    /// The smallest the window may be, in points, at this text size.
    var minimumWindowSize: CGSize { Self.minimumWindowSize(at: scale) }

    /// The window floor at any scale, as a pure function of it.
    ///
    /// Below this the two panes stop being usable side by side, and the floor rises with the text
    /// size: at 200% the same 720 points would clip every label. It is one rule because there were
    /// three — a declaration in `ChatBotsApp` that nothing read, a hard-coded 720×480 on the window
    /// and a 700×460 frame minimum in `ContentView` — which disagreed about the base size and about
    /// whether to scale at all. The window's minimum is what a drag is clamped by; the frame's
    /// is what the layout asks for where there is no window to clamp it.
    ///
    /// A function of the scale rather than only a property, so the rule can be asserted at 100 % and
    /// at 200 % without a store whose scale lives in the preferences of whatever process runs the test.
    static func minimumWindowSize(at scale: Double) -> CGSize {
        CGSize(width: 720 * scale, height: 480 * (1 + (scale - 1) * 0.5))
    }
}

// MARK: - Scaling text and spacing

/// A font size as written in the design (at 100%), scaled by the current text size.
///
/// Uses `Font.system(size:)` explicitly rather than a semantic font (`Font.body`), because
/// the app's sizes are hand-tuned and semantic fonts also respond to other system settings
/// — which would make the result depend on two scales at once.
struct ScaledFont: ViewModifier {
    @EnvironmentObject private var zoom: ZoomStore
    let size: Double
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * zoom.scale, weight: weight, design: design))
    }
}

extension View {
    /// Apply a text size that follows the app's text-size setting.
    func scaledFont(
        size: Double,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }

    /// Spacing that follows the text size, for rows whose contents are text.
    func scaledPadding(_ edges: Edge.Set = .all, _ length: Double) -> some View {
        modifier(ScaledPadding(edges: edges, length: length))
    }
}

struct ScaledPadding: ViewModifier {
    @EnvironmentObject private var zoom: ZoomStore
    let edges: Edge.Set
    let length: Double

    func body(content: Content) -> some View {
        content.padding(edges, length * zoom.scale)
    }
}
