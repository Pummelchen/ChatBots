// ChatBotsAppTests — a comment written once, and an environment object nobody reads.
//
// Two comments were pasted twice, the first copy of one of them truncated mid-sentence — the kind of
// thing a merge or a hurried edit leaves and nobody re-reads, because the file still compiles and the
// comment still reads plausibly if you stop halfway. And `UserSettingsStore` was injected into the
// environment while publishing nothing and being declared by no view, so the injection could not
// repaint anything.
//
// Comments are not values, so what is asserted here is what a reader would notice: that the sentence
// appears once rather than twice, that no view asks for the settings object, and — the part that is
// easy to get wrong when removing an injection — that the store's own owner is still there.

import Foundation
import Testing

@testable import ChatBots

@Suite("A comment once, and no dead environment object")
struct CommentAndInjectionTests {

    @Test("The sentence a comment repeats appears once")
    func commentsAreNotDuplicated() throws {
        let scroll = try source("Sources/ChatBotsApp/Views/AppKitScrollView.swift")
        let content = try source("Sources/ChatBotsApp/Views/ContentView.swift")

        // The first copy of the `@MainActor` rationale ended at "…a real hazard rather" and the whole
        // thing followed it again.
        #expect(
            occurrences(of: "`@MainActor` because everything it touches", in: scroll) == 1,
            "the coordinator's `@MainActor` rationale is written twice")
        // The copy that was truncated stopped at "…a real hazard rather" and the whole rationale
        // began again; the sentence completing once is what says only one copy is left.
        #expect(
            occurrences(of: "than a formality", in: scroll) == 1,
            "the truncated copy of that comment is back")
        #expect(
            occurrences(of: "Minimums only — no maximum", in: content) == 1,
            "the layout's minimum-size sentence is written twice")
    }

    @Test("No view asks for the settings store")
    func noViewReadsTheSettingsStore() throws {
        // It publishes nothing (`private(set) var settings` with no `@Published`), so an injection
        // could not repaint a view even if one read it — and none does.
        let app = try source("Sources/ChatBotsApp/ChatBotsApp.swift")
        #expect(
            !app.contains(".environmentObject(settings)"),
            "the settings store is injected into the environment again")

        for file in try appSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("EnvironmentObject") && line.contains("settings") {
                Issue.record("\(file.lastPathComponent):\(number + 1) reads the settings store from the environment")
            }
        }
    }

    @Test("The store is still owned, which is what removing the injection must not break")
    func theStoreIsStillOwned() throws {
        // The save callback holds the store weakly, so the `@StateObject` is what keeps it alive:
        // deleting the property along with the injection would silently stop the app saving settings.
        let app = try source("Sources/ChatBotsApp/ChatBotsApp.swift")
        #expect(app.contains("@StateObject private var settings: UserSettingsStore"))
        #expect(app.contains("[weak store]"), "the callback is expected to hold the store weakly")
        #expect(app.contains("_settings = StateObject(wrappedValue: store)"))
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// Every Swift file in the application target.
    private func appSources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ChatBotsAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
            .appending(path: "Sources/ChatBotsApp")
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return walk.compactMap { entry in
            guard let name = entry as? String, name.hasSuffix(".swift") else { return nil }
            return root.appending(path: name)
        }
    }

    /// A source file in this package, for a property only its text can show.
    private func source(_ path: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: path)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
