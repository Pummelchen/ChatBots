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
    /// covers them asserts the code the app runs rather than a copy of it (A167). These are aliases
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

    /// The next step's label, so a menu can say what ⌘+ will do.
    var nextLargerPercent: Int? {
        TextZoom.next(from: scale, larger: true).map(TextZoom.percent(of:))
    }

    var nextSmallerPercent: Int? {
        TextZoom.next(from: scale, larger: false).map(TextZoom.percent(of:))
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

/// A dimension that follows the text size — for icon columns and similar fixed widths that
/// would otherwise clip once the labels beside them grow.
struct ScaledLength: ViewModifier {
    @EnvironmentObject private var zoom: ZoomStore
    let base: Double

    func body(content: Content) -> some View {
        content.frame(width: base * zoom.scale)
    }
}
