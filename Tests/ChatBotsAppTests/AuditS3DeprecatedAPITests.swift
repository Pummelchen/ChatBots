// ChatBotsAppTests — the activation call the macOS 27 SDK is retiring (A180).
//
// `activateIgnoringOtherApps:` is annotated `API_DEPRECATED(…, macos(10.0, API_TO_BE_DEPRECATED))` in
// the macOS 27 SDK, with `activate` named as the replacement — and because "to be deprecated" is not
// "deprecated", nothing warns yet, so the build with warnings-as-errors cannot see it. The migration is
// a behaviour change as well as a spelling one: `activate` is a request the system may decline, which
// is what cooperative activation means, so the app no longer takes focus from whatever was frontmost.
// What a test can do is see the spelling, which is what this does.

import Foundation
import Testing

@testable import ChatBots

@Suite("The activation API the macOS 27 SDK is retiring (A180)")
struct DeprecatedActivationTests {

    @Test("Nothing calls the activation API the SDK has marked to be deprecated")
    func theRetiringCallIsGone() throws {
        for file in try swiftSources(under: "Sources") {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !text.contains("activate(ignoringOtherApps"),
                "\(file.path) calls the activation API the SDK names `activate` as the replacement for")
        }
    }

    @Test("The app still asks to be activated when its window opens")
    func theAppStillAsks() throws {
        // The counterweight: removing the retiring call must leave the request there, or the window
        // opens behind whatever is frontmost and nobody notices until a user complains.
        let app = try source("Sources/ChatBotsApp/ChatBotsApp.swift")
        #expect(app.contains("NSApp.activate()"))
        #expect(app.contains("window.makeKeyAndOrderFront"))
    }

    /// Every Swift file under `path`.
    private func swiftSources(under path: String) throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ChatBotsAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
            .appending(path: path)
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return walk.compactMap { entry in
            guard let name = entry as? String, name.hasSuffix(".swift") else { return nil }
            return root.appending(path: name)
        }
    }

    private func source(_ path: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: path)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
