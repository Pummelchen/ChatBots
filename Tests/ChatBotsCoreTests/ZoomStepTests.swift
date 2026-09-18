// ChatBotsCoreTests — the text-size steps
//
// The step list and the clamping are pure logic, so they are asserted here rather than by pressing
// keys — and they are asserted against `TextZoom` itself. What this suite used to do was re-declare
// `levels` and `step` inside the test file and assert those against themselves, with a comment
// claiming the assertions kept the two in step. They could not: nothing read the store's copy, so
// changing the store — or deleting the logic outright — left this suite green. It read as coverage
// and pinned nothing (the same class of defect either way).
//
// The logic moved into `ChatBotsCore` so that this file has something real to read: the app target
// has no test target, which is why the copy existed at all.

import ChatBotsCore
import Testing

@Suite("Text size steps")
struct ZoomStepTests {

    @Test("Stepping up moves to the next level and stops at the top")
    func stepsUp() {
        #expect(TextZoom.stepped(from: 1.0, larger: true) == 1.15)
        #expect(TextZoom.stepped(from: 1.15, larger: true) == 1.3)
        #expect(TextZoom.stepped(from: 1.75, larger: true) == 2.0)
        // At the top it holds rather than overflowing.
        #expect(TextZoom.stepped(from: 2.0, larger: true) == 2.0)
    }

    @Test("Stepping down moves to the previous level and stops at the bottom")
    func stepsDown() {
        #expect(TextZoom.stepped(from: 1.0, larger: false) == 0.85)
        #expect(TextZoom.stepped(from: 1.3, larger: false) == 1.15)
        #expect(TextZoom.stepped(from: 0.85, larger: false) == 0.85)
    }

    @Test("Levels are strictly increasing between 85% and 200%")
    func levelsAreSane() throws {
        let levels = TextZoom.levels
        #expect(levels == levels.sorted())
        #expect(Set(levels).count == levels.count)
        let smallest = try #require(levels.first)
        let largest = try #require(levels.last)
        #expect(smallest >= 0.8, "below this the app's 8pt labels stop being readable")
        #expect(largest <= 2.0, "above this the two-pane layout stops being usable")
        #expect(levels.contains(1.0), "there must be an exact 100% to return to")
        #expect(TextZoom.minimumScale == levels.first)
        #expect(TextZoom.maximumScale == levels.last)
    }

    @Test("Repeated stepping covers the whole range in both directions")
    func fullRange() {
        var scale = 1.0
        for _ in 0..<10 { scale = TextZoom.stepped(from: scale, larger: true) }
        #expect(scale == 2.0)
        for _ in 0..<10 { scale = TextZoom.stepped(from: scale, larger: false) }
        #expect(scale == 0.85, "stepping down from the top must reach the bottom")
        for _ in 0..<10 { scale = TextZoom.stepped(from: scale, larger: true) }
        #expect(scale == 2.0)
    }

    @Test("⌘0 lands exactly on 100%")
    func resetIsExact() {
        // The menu item's enabled state compares the current percent against 100, so a level that
        // rounds to 100 but is not 100 would leave the item permanently enabled.
        #expect(TextZoom.percent(of: TextZoom.default) == 100)
        for level in TextZoom.levels where level != 1.0 {
            #expect(TextZoom.percent(of: level) != 100)
        }
    }

    @Test("Every level is a clean percentage once rounded for display")
    func percentagesAreWhole() {
        // Binary floating point cannot represent 1.15 exactly — 1.15 * 100 is 114.99999999999999 — so
        // this asserts what the display actually does: rounds to the nearest whole percent.
        for level in TextZoom.levels {
            let percent = level * 100
            let shown = percent.rounded()
            #expect(abs(percent - shown) < TextZoom.tolerance, "\(level) is not a clean percentage")
            #expect(shown == Double(Int(shown)), "the displayed percent must be a whole number")
            #expect(TextZoom.percent(of: level) == Int(shown))
        }
    }

    @Test("A scale that came back from storage still counts as being on its level")
    func toleranceHoldsThroughRounding() {
        // What the store reads back after writing 1.15 is not exactly 1.15. Without the tolerance the
        // step up from here would find 1.15 again, and ⌘+ would look broken at its own levels.
        let readBack = 1.15 - 1e-16
        #expect(TextZoom.stepped(from: readBack, larger: true) == 1.3)
        #expect(TextZoom.stepped(from: 1.15 + 1e-16, larger: false) == 1.0)
    }

    @Test("What a menu offers is what stepping lands on, and nothing at the ends")
    func nextAgreesWithStepping() {
        for scale in TextZoom.levels {
            let up = TextZoom.next(from: scale, larger: true)
            let down = TextZoom.next(from: scale, larger: false)
            #expect(up == nil || TextZoom.stepped(from: scale, larger: true) == up)
            #expect(down == nil || TextZoom.stepped(from: scale, larger: false) == down)
            // The ends are where `next` runs out and `stepped` holds instead.
            #expect(up != nil || scale == TextZoom.maximumScale)
            #expect(down != nil || scale == TextZoom.minimumScale)
        }
    }

    @Test("A scale outside the range is pulled back into it")
    func clamping() {
        #expect(TextZoom.clamped(0.1) == TextZoom.minimumScale)
        #expect(TextZoom.clamped(9.0) == TextZoom.maximumScale)
        #expect(TextZoom.clamped(1.3) == 1.3)
    }

    @Test("A corrupted stored scale has a percentage rather than trapping")
    func corruptedScaleIsSane() {
        // `percent` is `Int((scale * 100).rounded())`, which traps for NaN or a value outside
        // `Int`'s range — and the scale comes from a persisted preference that the app never
        // writes out of range itself. `sanitised` is what makes the conversion total.
        // Not a number at all: the default is the only sane answer.
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(TextZoom.sanitised(bad) == TextZoom.default, "\(bad) is not a scale")
            #expect(TextZoom.percent(of: bad) == 100, "\(bad) must report the default's percentage")
        }
        // A number that is merely enormous is clamped like any other out-of-range value, and the
        // percentage follows it rather than trapping.
        for (bad, expected) in [(1e300, TextZoom.maximumScale), (-1e300, TextZoom.minimumScale)] {
            #expect(TextZoom.sanitised(bad) == expected)
            #expect(TextZoom.percent(of: bad) == TextZoom.percent(of: expected))
        }
        // The ordinary paths are unchanged.
        #expect(TextZoom.sanitised(1.3) == 1.3)
        #expect(TextZoom.sanitised(0.1) == TextZoom.minimumScale)
    }
}
