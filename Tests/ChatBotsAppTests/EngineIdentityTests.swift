// ChatBotsAppTests — an engine that cannot prove its identity is never adopted
//
// The finding: the supervisor adopted whatever answered on the transport port, and the app then
// pushed each seat's Keychain key to it. The decision that closes it is "the echo equals the token
// this run wrote", and it is exercised here without a socket: the supervisor is given a run
// directory of its own, so `SessionToken` and the supervisor's rule meet the way they do in the
// app without a QUIC listener in the way. The file's own rules are in `SessionTokenTests`.

import ChatBotsCore
import Foundation
import Testing

@testable import ChatBots

@MainActor
@Suite("An engine that cannot prove its identity")
struct EngineIdentityTests {

    /// A run directory this test owns, so the token is not shared with whatever else is running.
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "supervisor-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func supervisor(in directory: URL) -> EngineSupervisor {
        EngineSupervisor(
            logURL: directory.appending(path: "app-engine.log"), runDirectory: directory)
    }

    @Test("Only the token this run wrote is accepted")
    func wrongTokenIsRefused() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = try SessionToken.issue(in: directory)
        let supervisor = supervisor(in: directory)

        #expect(supervisor.identityMatches(token), "the engine's own echo is the one that counts")
        #expect(!supervisor.identityMatches("a-different-token"))
        #expect(!supervisor.identityMatches(token + "0"), "a longer string is not the token")
        #expect(!supervisor.identityMatches(token.uppercased()))
        #expect(!supervisor.identityMatches(nil), "an engine that answered nothing proves nothing")
        #expect(!supervisor.identityMatches(""))
    }

    @Test("With no token on disk, nothing is adopted")
    func noTokenOnDiskAdoptsNothing() throws {
        // Before the engine has written its token — the window an impostor would take — even a
        // guess that happens to be right for some later run proves nothing.
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let supervisor = supervisor(in: directory)

        #expect(!supervisor.identityMatches("any-token-at-all"))
        #expect(!supervisor.identityMatches(nil))
        #expect(!supervisor.hasVerifiedEngine, "a fresh supervisor has adopted nothing")
    }

    @Test("The refusal names the port and promises no credentials")
    func refusalIsActionable() {
        let message = EngineSupervisor.unverifiedEngineMessage(port: 7790)

        #expect(message.contains("7790"))
        #expect(message.contains("API keys"))
        #expect(message.contains("will not send"), "the reason must say what the app will not do")
    }
}
