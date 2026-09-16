// ChatBotsAppTests — the window floor and the menu's zoom labels.
//
// Nine app-layer declarations were unread. Two of them were not dead so much as unwired: the window
// minimum existed three times and nothing read the declared one, and the next-step percentages were
// written for a menu that never asked for them. Those are used now; the rest are gone. What is left
// to assert is the part a compiler cannot: that the one floor is the rule it claims to be, and that
// the labels name the step the buttons actually take.

import ChatBotsCore
import CoreGraphics
import Foundation
import Testing

@testable import ChatBots

@MainActor
@Suite("The app's window floor and zoom labels")
struct AppWindowFloorTests {

    @Test("The floor is the base size at 100% and scales with the text")
    func theFloorScalesWithTheText() {
        let base = ZoomStore.minimumWindowSize(at: 1.0)
        #expect(base == CGSize(width: 720, height: 480))

        // 200% text: the width doubles, and the height rises more slowly because the title, the
        // control bar and the status row do not grow with the text the way the panes do.
        let doubled = ZoomStore.minimumWindowSize(at: 2.0)
        #expect(doubled == CGSize(width: 1440, height: 720))

        let smallest = ZoomStore.minimumWindowSize(at: 0.85)
        #expect(smallest == CGSize(width: 612, height: 444))
    }

    @Test("The floor rises at every step, so a bigger text never gets a smaller window")
    func theFloorRisesAtEveryStep() {
        let sizes = TextZoom.levels.map { ZoomStore.minimumWindowSize(at: $0) }
        for (smaller, larger) in zip(sizes, sizes.dropFirst()) {
            #expect(larger.width > smaller.width, "\(larger) is not wider than \(smaller)")
            #expect(larger.height > smaller.height, "\(larger) is not taller than \(smaller)")
        }
    }

    @Test("The window's own minimum is that rule at the current text size")
    func theWindowUsesThatRule() {
        // Whatever the text size is in this process, the window and the layout have to agree about
        // it: they read the same property, and this is what says so.
        let zoom = ZoomStore()
        #expect(zoom.minimumWindowSize == ZoomStore.minimumWindowSize(at: zoom.scale))
    }

    @Test("The floor is stated once: neither the window nor the layout carries its own")
    func theFloorIsStatedOnce() throws {
        // There were three floors — a declaration in the app that nothing read, a hard-coded
        // 720×480 on the window and a 700×460 frame minimum. The rule is tested above; this is what
        // says the two *sites* still read it, which no rendering test here could see. Read as source,
        // the way `TavilyKeyTests` asserts a property of a file.
        let app = try source("Sources/ChatBotsApp/ChatBotsApp.swift")
        let content = try source("Sources/ChatBotsApp/Views/ContentView.swift")

        #expect(
            app.contains("window.contentMinSize = NSSize(width: minimumSize.width"),
            "the window's minimum is not the shared rule")
        #expect(
            app.contains("minimumSize: zoom.minimumWindowSize"),
            "the window is not handed the rule")
        #expect(
            content.contains("minWidth: zoom.minimumWindowSize.width"),
            "the layout's minimum is not the shared rule")
        #expect(
            !content.contains("700 * zoom.scale"),
            "the layout carries a floor of its own again")
        #expect(
            !app.contains("NSSize(width: 720, height: 480)"),
            "the window carries a floor of its own again")
    }

    /// A source file in this package, for the property that only its text can show.
    private func source(_ path: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ChatBotsAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
            .appending(path: path)
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("The menu's percentages are the steps its buttons take")
    func theLabelsNameTheStep() {
        let zoom = ZoomStore()
        // The labels were written for exactly this and nothing read them; the step is what the
        // button does, so the two have to come from the same place.
        #expect(
            zoom.nextLargerPercent
                == TextZoom.next(from: zoom.scale, larger: true).map(TextZoom.percent(of:)))
        #expect(
            zoom.nextSmallerPercent
                == TextZoom.next(from: zoom.scale, larger: false).map(TextZoom.percent(of:)))
    }
}
