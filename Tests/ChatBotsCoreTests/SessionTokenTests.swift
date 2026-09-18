// ChatBotsCoreTests — the token that proves which engine is answering
//
// The rules the app and the engine both depend on: 32 random bytes written at 0600 into a directory
// created at 0700, a replacement that is atomic, a read that says nil rather than empty, and a
// comparison that cannot be told apart from a guess that was one byte right. There is no socket
// here on purpose — the file itself is the whole thing that goes wrong silently.

import ChatBotsCore
import Foundation
import Testing

@Suite("The session token")
struct SessionTokenTests {

    /// A run directory that does not exist yet, so `issue` is seen creating it.
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "session-token-\(UUID().uuidString)")
            .appending(path: "run")
    }

    /// A file's POSIX mode, with the type bits masked off.
    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = attributes[.posixPermissions] as? NSNumber
        return (number?.intValue ?? 0) & 0o777
    }

    /// Remove the whole scratch tree, directory and all.
    private func cleanUp(_ runDirectory: URL) {
        try? FileManager.default.removeItem(at: runDirectory.deletingLastPathComponent())
    }

    @Test("Issuing writes a 0600 file into a 0700 directory")
    func permissionsAreExplicit() throws {
        let directory = scratch()
        defer { cleanUp(directory) }

        _ = try SessionToken.issue(in: directory)

        let directoryMode = try mode(of: directory)
        let fileMode = try mode(of: directory.appending(path: SessionToken.filename))
        #expect(directoryMode == 0o700, "the run directory is the owner's alone")
        #expect(fileMode == 0o600, "the token is the owner's alone")
    }

    @Test("A token is 32 random bytes as lowercased hex")
    func tokenShape() throws {
        let directory = scratch()
        defer { cleanUp(directory) }

        let token = try SessionToken.issue(in: directory)

        let allHex = token.allSatisfy { $0.isHexDigit }
        #expect(token.count == 64, "32 bytes of hex is 64 characters")
        #expect(allHex)
        #expect(token == token.lowercased())
    }

    @Test("A second issue replaces the token")
    func aSecondIssueReplaces() throws {
        let directory = scratch()
        defer { cleanUp(directory) }

        let first = try SessionToken.issue(in: directory)
        let second = try SessionToken.issue(in: directory)

        #expect(first != second)
        #expect(SessionToken.read(from: directory) == second)
        #expect(!SessionToken.matches(first, in: directory), "the earlier token is forgotten")
        #expect(SessionToken.matches(second, in: directory))
    }

    @Test("Read is nil when the token is absent or empty")
    func readIsNilWhenThereIsNothing() throws {
        let directory = scratch()
        defer { cleanUp(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(SessionToken.read(from: directory) == nil)

        try Data().write(to: directory.appending(path: SessionToken.filename))
        #expect(SessionToken.read(from: directory) == nil)
    }

    @Test("Matches is true only for the token on disk")
    func matchesOnlyTheToken() throws {
        let directory = scratch()
        defer { cleanUp(directory) }

        let token = try SessionToken.issue(in: directory)

        #expect(SessionToken.matches(token, in: directory))
        #expect(!SessionToken.matches("not-the-token", in: directory))
        #expect(!SessionToken.matches(token.uppercased(), in: directory))
        #expect(!SessionToken.matches("", in: directory))
    }

    @Test("Removing forgets the token, and leaves nothing to match")
    func removingForgetsTheToken() throws {
        let directory = scratch()
        defer { cleanUp(directory) }

        let token = try SessionToken.issue(in: directory)
        SessionToken.remove(from: directory)

        #expect(SessionToken.read(from: directory) == nil)
        #expect(!SessionToken.matches(token, in: directory))
    }
}
