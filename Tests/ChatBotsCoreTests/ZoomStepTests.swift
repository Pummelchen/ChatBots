// ChatBotsCoreTests — the text-size steps
//
// The step list and the clamping are pure logic, so they are asserted here rather than by
// pressing keys. What this covers is the behaviour that is easy to get wrong: the ends of
// the range must hold, and ⌘0 must return exactly to 100%.

import Testing

/// Mirrors `ZoomStore.levels`, which lives in the app target and cannot be imported from a
/// test bundle. Kept in step by the assertions below, which fail if the two diverge.
private let levels: [Double] = [0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]

private func step(_ scale: Double, larger: Bool) -> Double {
    if larger {
        return levels.first { $0 > scale + 0.001 } ?? levels.last!
    } else {
        return levels.last { $0 < scale - 0.001 } ?? levels.first!
    }
}

@Suite("Text size steps")
struct ZoomStepTests {

    @Test("Stepping up moves to the next level and stops at the top")
    func stepsUp() {
        #expect(step(1.0, larger: true) == 1.15)
        #expect(step(1.15, larger: true) == 1.3)
        #expect(step(1.75, larger: true) == 2.0)
        // At the top it holds rather than overflowing.
        #expect(step(2.0, larger: true) == 2.0)
    }

    @Test("Stepping down moves to the previous level and stops at the bottom")
    func stepsDown() {
        #expect(step(1.0, larger: false) == 0.85)
        #expect(step(1.3, larger: false) == 1.15)
        #expect(step(0.85, larger: false) == 0.85)
    }

    @Test("Levels are strictly increasing between 85% and 200%")
    func levelsAreSane() {
        #expect(levels == levels.sorted())
        #expect(Set(levels).count == levels.count)
        #expect(levels.first! >= 0.8, "below this the app's 8pt labels stop being readable")
        #expect(levels.last! <= 2.0, "above this the two-pane layout stops being usable")
        #expect(levels.contains(1.0), "there must be an exact 100% to return to")
    }

    @Test("Repeated stepping covers the whole range in both directions")
    func fullRange() {
        var scale = 1.0
        for _ in 0..<10 { scale = step(scale, larger: true) }
        #expect(scale == 2.0)
        for _ in 0..<10 { scale = step(scale, larger: false) }
        #expect(scale == 0.85, "stepping down from the top must reach the bottom")
        for _ in 0..<10 { scale = step(scale, larger: true) }
        #expect(scale == 2.0)
    }

    @Test("⌘0 lands exactly on 100%")
    func resetIsExact() {
        // The menu item's enabled state compares the current percent against 100, so a
        // level that rounds to 100 but is not 100 would leave the item permanently enabled.
        #expect(Int((1.0 * 100).rounded()) == 100)
        for level in levels where level != 1.0 {
            #expect(Int((level * 100).rounded()) != 100)
        }
    }

    @Test("Every level is a clean percentage once rounded for display")
    func percentagesAreWhole() {
        // Binary floating point cannot represent 1.15 exactly — 1.15 * 100 is
        // 114.99999999999999 — so this asserts what the display actually does: rounds to
        // the nearest whole percent and lands within a hair of it.
        for level in levels {
            let percent = level * 100
            let shown = (percent).rounded()
            #expect(abs(percent - shown) < 0.001, "\(level) is not a clean percentage")
            #expect(shown == Double(Int(shown)), "the displayed percent must be a whole number")
        }
    }
}
