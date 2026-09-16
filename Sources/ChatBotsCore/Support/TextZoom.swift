// ChatBotsCore — the text-size steps
//
// The arithmetic behind ⌘+ / ⌘− / ⌘0. It lives in the core rather than beside the SwiftUI store for
// one reason: the app target has no test target, so logic that lives there cannot be asserted at all.
// The suite that covered this used to re-declare `levels` and `step` inside the test file and assert
// them against themselves, which pinned nothing — changing the store left it green (and it had
// to be written that way because the app target has no test target).

/// The discrete text sizes the app offers, and the steps between them.
public enum TextZoom {
    /// The steps ⌘+ and ⌘− move through.
    ///
    /// Discrete steps rather than a free multiplier: a text size that lands on 1.07× serves nobody,
    /// and steps are what make ⌘0 predictable.
    public static let levels: [Double] = [0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]

    /// 100 %, what ⌘0 returns to.
    public static let `default` = 1.0

    /// How close to a level counts as being on it.
    ///
    /// A scale that was set to 1.15 and read back can be 1.1499999999999999, and without a tolerance
    /// the next step up would find 1.15 and land there again — ⌘+ would look broken at exactly the
    /// levels it moves through.
    public static let tolerance = 0.001

    /// The smallest and largest steps.
    ///
    /// `levels` is an ascending literal, so these are its ends; the fallback to `default` is what a
    /// caller would see if that ever stopped being true, rather than a trap.
    public static var minimumScale: Double { levels.min() ?? `default` }
    public static var maximumScale: Double { levels.max() ?? `default` }

    /// `scale` pulled inside the range.
    public static func clamped(_ scale: Double) -> Double {
        min(max(scale, minimumScale), maximumScale)
    }

    /// The scale one step from `scale` in the direction of `larger`, holding at either end.
    public static func stepped(from scale: Double, larger: Bool) -> Double {
        next(from: scale, larger: larger) ?? (larger ? maximumScale : minimumScale)
    }

    /// The scale one step from `scale`, or `nil` when `scale` is already at that end.
    ///
    /// This is what a menu reads to say what ⌘+ will do, and what tells `stepped` where to go; the
    /// two cannot disagree about the ends because there is only one comparison.
    public static func next(from scale: Double, larger: Bool) -> Double? {
        if larger {
            return levels.first { $0 > scale + tolerance }
        }
        return levels.last { $0 < scale - tolerance }
    }

    /// The whole percentage a scale displays as.
    ///
    /// Rounded rather than truncated, because binary floating point makes 1.15 × 100 come out at
    /// 114.99999999999999.
    public static func percent(of scale: Double) -> Int { Int((scale * 100).rounded()) }
}
