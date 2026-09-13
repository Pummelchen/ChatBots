// ChatBotsCoreTests — where the app and the engine are allowed to write
//
// These exist because of a real defect: the app wrote its engine log to
// `<ChatBots.app>/.run/app-engine.log`, and an installed engine would have written its
// certificate and kept conversations under `<ChatBots.app>/Contents/MacOS/.run`. Two consequences,
// both bad — the bundle's code signature is invalid the moment it writes to itself (`codesign`
// reports "unsealed contents present in the bundle root"), and an app in a location it cannot
// write to cannot start its engine at all.
//
// The resolver is tested with an explicit project root so the answer does not depend on where the
// test happens to be running.

import ChatBotsCore
import Foundation
import Testing

@Suite("Run directory")
struct RunDirectoryTests {

    /// A scratch directory that cleans up after itself.
    private func scratch(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "chatbots-run-\(name)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A checkout keeps its runtime state in .run, as it always has")
    func checkoutUsesDotRun() throws {
        // `tools/install.sh` prepares the engine certificate in `<project>/.run`, and
        // `tools/start.sh` writes its pid files there. Running from a checkout must not move.
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try "// swift-tools-version: 6.3".write(
            to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)

        #expect(RunDirectory.resolve(projectRoot: root) == root.appending(path: ".run"))
    }

    @Test("A directory that merely contains models is not a checkout")
    func modelsFolderIsNotACheckout() throws {
        // `ModelStore.projectRoot()` also accepts a directory containing `models`, which is right
        // for finding checkpoints and wrong for deciding where to write: an installed app would
        // put its certificate and its conversations wherever it happened to find one.
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "models"), withIntermediateDirectories: true)

        #expect(RunDirectory.resolve(projectRoot: root) != root.appending(path: ".run"))
    }

    @Test("With no checkout it writes outside the bundle, on a path a user can write")
    func fallsBackOutsideTheBundle() {
        let resolved = RunDirectory.resolve(projectRoot: nil)

        #expect(resolved.path.contains("Application Support"), "got \(resolved.path)")
        #expect(!resolved.path.contains(".app/"), "runtime state must not be inside the bundle")
        #expect(resolved.lastPathComponent == "ChatBots")
    }

    @Test("The fallback is the same folder for the app and for the engine it starts")
    func fallbackIsStable() {
        // Both processes ask the same question and must get the same answer, or the app's log and
        // the engine's certificate end up in different places.
        #expect(RunDirectory.resolve(projectRoot: nil) == RunDirectory.resolve(projectRoot: nil))
    }
}
