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
    /// Discrete steps rather than a free multiplier: a text size that lands on 1.07× serves
    /// nobody, and steps make ⌘0 predictable.
    static let levels: [Double] = [0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]
    static let `default` = 1.0

    /// The smallest and largest steps.
    ///
    /// `levels` is an ascending literal, so these are its ends; the fallback to `default` is
    /// what a caller would see if that ever stopped being true, rather than a trap (audit A28).
    static var minimumScale: Double { levels.min() ?? `default` }
    static var maximumScale: Double { levels.max() ?? `default` }

    @AppStorage("textScale") private var storedScale: Double = ZoomStore.default

    var scale: Double {
        get { storedScale }
        set { storedScale = min(max(newValue, Self.minimumScale), Self.maximumScale) }
    }

    var percent: Int { Int((scale * 100).rounded()) }
    /// 100, for comparing against `percent`.
    var resetPercent: Int { Int((Self.default * 100).rounded()) }
    var canEnlarge: Bool { scale < Self.maximumScale - 0.001 }
    var canReduce: Bool { scale > Self.minimumScale + 0.001 }

    /// Move one step, in the direction of `larger`.
    func step(larger: Bool) {
        if larger {
            scale = Self.levels.first { $0 > scale + 0.001 } ?? Self.maximumScale
        } else {
            scale = Self.levels.last { $0 < scale - 0.001 } ?? Self.minimumScale
        }
    }

    func reset() { scale = Self.default }

    /// The next step's label, so a menu can say what ⌘+ will do.
    var nextLargerPercent: Int? {
        guard let next = Self.levels.first(where: { $0 > scale + 0.001 }) else { return nil }
        return Int((next * 100).rounded())
    }

    var nextSmallerPercent: Int? {
        guard let next = Self.levels.last(where: { $0 < scale - 0.001 }) else { return nil }
        return Int((next * 100).rounded())
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
