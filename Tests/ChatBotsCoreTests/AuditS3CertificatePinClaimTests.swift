// ChatBotsCoreTests — the fingerprint comments match the trust the client gives them (A195)
//
// `SECURITY.md` states the local trust boundary honestly: the desktop app reaches the engine with the
// transport library's `.localDevelopmentSelfSigned` policy, a loopback-only bypass of platform
// certificate validation, so the engine's SHA-256 is **reported and logged but not enforced**. Several
// comments said the opposite — `CertificateStore.swift` opened with "the client verifies it by pinning
// its SHA-256 fingerprint", three operator-facing error messages warned that regenerating the identity
// would cost "every client its pin", and `TransportCheck.swift` and `WebTransportServer.swift`
// described a client that pins or must pin. Two comments cannot both be true, and the policy document
// is the one that stands, so those comments now say what the code does: the fingerprint is reported,
// logged and compared by eye, and the identity is worth keeping stable precisely because it is
// reported — not because anything enforces it.
//
// The words *are* the artefact here, so the check reads them. The counterweight matters as much as the
// blacklist: a fix that made the comments agree by removing the fingerprint from the engine would be a
// different defect, so the value's public surfaces are checked too.

import Foundation
import Testing

@Suite("The certificate comments match the trust the client gives them (A195)")
struct CertificatePinClaimTests {

    /// A file in this package, for a property only its text can show.
    private func text(of path: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ChatBotsCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
            .appending(path: path)
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Every Swift source in `Sources/`, since the claim was in four files and could return in any of
    /// them — the same reason A192 stopped deciding the shell lint's scope by a path list.
    private func sources() -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources")
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return walk.compactMap { entry in
            guard let name = entry as? String, name.hasSuffix(".swift") else { return nil }
            let url = root.appending(path: name)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (name, source)
        }
    }

    /// The phrasings that assert an enforcement the client does not perform. Exact rather than
    /// thematic, and quoted from the finding, so this is a regression guard rather than a style rule:
    /// it names what was written, and a future comment that says "the client pins the fingerprint" in
    /// some other words is for a reviewer, not for a string match.
    private static let falseClaims = [
        "the client verifies it by pinning",
        "what makes pinning meaningful",
        "the fingerprint a client pins",
        "which is what a client pins",
        "a client must pin",
        "costs every client its pin",
        "every client that had pinned",
        "fingerprint pinned here",
        "fingerprint pinned above",
    ]

    /// The words with the comment wrapping taken out.
    ///
    /// Comments wrap: `WebTransportClient.swift` says "it does not\n// verify our fingerprint" and
    /// `CertificateStore.swift` says "which is what makes\n// pinning meaningful". A phrase the
    /// finding quotes is therefore not a substring of the file, so the match is made against the
    /// words with newlines and comment markers collapsed rather than against the raw bytes. The `/`
    /// goes too, including the one left over from a `///` doc comment — otherwise a phrase that spans
    /// two comment lines has a stray slash in the middle of it.
    private func flattened(_ source: String) -> String {
        source.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    @Test("No source file claims the client pins or enforces the certificate")
    func noSourceClaimsPinning() {
        let found = sources()
        #expect(found.count > 20, "found only \(found.count) source files — the walk is wrong")
        for (name, source) in found {
            let words = flattened(source)
            for claim in Self.falseClaims {
                #expect(!words.contains(claim), "\(name) still claims: \(claim)")
            }
        }
    }

    @Test("The store says what the fingerprint is for, in the policy document's words")
    func storeStatesTheTrade() throws {
        let store = flattened(try text(of: "Sources/ChatBotsCore/CertificateStore.swift"))
        #expect(
            store.contains("reported and logged but not enforced"),
            "the store does not state the trade in the words SECURITY.md uses")
        #expect(
            store.contains("does *not* verify it"),
            "the store does not say the client declines to verify the certificate")
        #expect(
            store.contains("SECURITY.md"),
            "the store does not point at the policy document that decides this")
    }

    @Test("The policy document and the client's own note still say the same thing")
    func policyAndClientAgree() throws {
        let security = flattened(try text(of: "SECURITY.md"))
        let client = flattened(try text(of: "Sources/ChatBotsCore/WebTransportClient.swift"))
        #expect(security.contains("reported and logged but not enforced"))
        #expect(security.contains("WebTransportClient.swift"), "the policy names no source file")
        #expect(
            client.contains("does not verify our fingerprint"),
            "the client's own note no longer says it declines to verify")
        #expect(client.contains("localDevelopmentSelfSigned"))
    }

    @Test("The fingerprint is still reported everywhere it was (the counterweight)")
    func fingerprintStillExposed() throws {
        let store = try text(of: "Sources/ChatBotsCore/CertificateStore.swift")
        let server = try text(of: "Sources/ChatBotsCore/WebTransportServer.swift")
        let check = try text(of: "Sources/ChatBotsCore/TransportCheck.swift")
        #expect(store.contains("fingerprintSHA256"))
        #expect(store.contains("fingerprintDisplay"))
        #expect(
            server.contains("fingerprintSHA256"),
            "the server stopped exposing the fingerprint to make the comments agree")
        #expect(
            check.contains("report.fingerprint = identity.fingerprintDisplay"),
            "the transport check stopped reporting the fingerprint")
    }
}
