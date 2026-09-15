// ChatBotsCoreTests — the stored TLS identity is read, not assumed (A155).
//
// The store generated an identity once and then, on every later start, believed four things about the
// files it found:
//
//   * `try? existing` made *any* read failure look like a first run, so a damaged identity was replaced
//     with a new key — a new fingerprint, so every client that pinned the old one refused to connect,
//     and the failure looked like a broken engine;
//   * `.rsa(sizeInBits: 2048)` was written into the identity whatever the key actually was, and the
//     transport hardcoded its own 2048 as well;
//   * the certificate and the key were never checked to be a pair, and the `hostnames` argument was
//     honoured only at generation, so a certificate that does not name the authority a client uses came
//     up and was refused by the client's own verification, with an error naming no certificate;
//   * `whichOpenSSL` would run a `openssl` from a user-writable prefix, with the private key's path in its
//     argument list.
//
// The last suite is the one that needs a real listener, and it is gated like the other transport suites.

import Foundation
import Testing

@testable import ChatBotsCore

@Suite("The stored certificate is read, not assumed (A155)")
struct CertificateStoreAuditTests {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "certificate-audit-\(UUID().uuidString)")
    }

    /// A certificate and key pair written under the names the store uses, made here rather than by the
    /// store because the store only ever generates 2048-bit RSA.
    @discardableResult
    private func writeIdentity(
        in directory: URL, bits: Int = 2048, hostnames: [String] = ["localhost", "127.0.0.1", "::1"]
    ) throws -> SystemProcess.Result {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var alternatives = ["DNS:localhost"]
        for host in hostnames where host != "localhost" {
            alternatives.append("IP:\(host)")
        }
        return try SystemProcess.run(
            "/usr/bin/openssl",
            [
                "req", "-x509", "-newkey", "rsa:\(bits)",
                "-keyout", directory.appending(path: "webtransport-key.pem").path,
                "-out", directory.appending(path: "webtransport-cert.pem").path,
                "-days", "3", "-nodes", "-subj", "/CN=ChatBots Engine",
                "-addext", "subjectAltName=\(alternatives.joined(separator: ","))",
                "-addext", "basicConstraints=critical,CA:FALSE",
                "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
                "-addext", "extendedKeyUsage=serverAuth",
            ],
            timeout: 30)
    }

    @Test("A corrupt certificate is reported, and the pinned identity is left alone")
    func corruptCertificateIsNotReplaced() throws {
        // The finding's first claim. Before the fix the load failed, `try?` turned that into "no identity
        // yet", and the store quietly generated a new key: the certificate every client had pinned was
        // gone and the reason was invisible.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try CertificateStore.loadOrCreate(in: directory)

        let certificate = directory.appending(path: "webtransport-cert.pem")
        try Data("this is not a certificate".utf8).write(to: certificate)

        do {
            _ = try CertificateStore.loadOrCreate(in: directory)
            Issue.record("a corrupt certificate was replaced behind the clients' backs")
        } catch {
            // The answer names the file it could not read, which is the part an operator can act on.
            #expect(error.localizedDescription.contains("certificate"))
        }

        #expect(
            try Data(contentsOf: certificate) == Data("this is not a certificate".utf8),
            "the refused load rewrote the certificate")
        // And the pinned identity is still the one on disk, unchanged by the attempt.
        #expect(identity.fingerprintSHA256.count == 32)
    }

    @Test("A directory with nothing in it still generates, and a second load reuses")
    func theHappyPathStillWorks() throws {
        // The counterweight to the whole suite: refusing to read damage must not turn into refusing to
        // work. An empty directory is the one case that generates.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try CertificateStore.loadOrCreate(in: directory)
        let second = try CertificateStore.loadOrCreate(in: directory)
        #expect(first.fingerprintSHA256 == second.fingerprintSHA256)
        #expect(first.keyKind == .rsa(sizeInBits: 2048))
    }

    @Test("The key size is read from the key rather than assumed to be 2048")
    func theKeySizeComesFromTheKey() throws {
        // `.rsa(sizeInBits: 2048)` was written into the identity whatever the file held, and the transport
        // was configured with its own hardcoded 2048, so a key of another size was described wrongly to
        // `SecKeyCreateWithData`.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeIdentity(in: directory, bits: 3072)

        let identity = try CertificateStore.loadOrCreate(in: directory)
        #expect(identity.keyKind == .rsa(sizeInBits: 3072))
        #expect(identity.privateKeyDER.count > 1_200, "a 3072-bit PKCS#1 key is larger than a 2048-bit one")
    }

    @Test("A key from another identity is refused as not a pair")
    func aMismatchedPairIsRefused() throws {
        // A key restored from a backup beside a certificate from another install used to load here and
        // fail in the handshake, where nothing names the file that is wrong.
        let first = temporaryDirectory()
        let second = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try writeIdentity(in: first)
        try writeIdentity(in: second)

        let certificate = first.appending(path: "webtransport-cert.pem")
        try FileManager.default.removeItem(at: certificate)
        try FileManager.default.copyItem(
            at: second.appending(path: "webtransport-cert.pem"), to: certificate)

        do {
            _ = try CertificateStore.loadOrCreate(in: first)
            Issue.record("a certificate and a key from different identities were accepted")
        } catch {
            #expect(
                error.localizedDescription.contains("not a pair"),
                "the answer should say what is wrong: \(error.localizedDescription)")
        }
    }

    @Test("A certificate that does not name the hostnames asked for is refused")
    func aCertificateMustCoverTheHostnames() throws {
        // `hostnames` was honoured only when the identity was generated; on every later load it was
        // ignored, so a caller asking for a name the certificate does not carry got a server that came up
        // and a client whose own verification refused it.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeIdentity(in: directory, hostnames: ["localhost"])

        do {
            _ = try CertificateStore.loadOrCreate(in: directory)
            Issue.record("a certificate for localhost was accepted for 127.0.0.1 and ::1")
        } catch {
            #expect(
                error.localizedDescription.contains("127.0.0.1"),
                "the answer should name what is not covered: \(error.localizedDescription)")
        }

        // The counterweight: the same identity, asked for what it does cover, loads.
        let identity = try CertificateStore.loadOrCreate(in: directory, hostnames: ["localhost"])
        #expect(identity.fingerprintSHA256.count == 32)
    }

    @Test("Coverage is decided by address bytes, so an IPv6 literal matches its expanded form")
    func addressesAreComparedAsBytes() {
        // Security reports a SAN address fully expanded — `0000:…:0001` — while a caller asks for `::1`.
        // `inet_pton` reads both, which is why the check does not go through anyone's text formatting.
        #expect(CertificateStore.addressBytes("::1") == CertificateStore.addressBytes("0:0:0:0:0:0:0:1"))
        #expect(CertificateStore.addressBytes("127.0.0.1")?.count == 4)
        #expect(CertificateStore.addressBytes("localhost") == nil)
    }

    @Test("openssl is only run from a path another user could not have written")
    func opensslMustBeTrustworthy() throws {
        // The private key's path travels in this program's argument list, so a binary another user can
        // replace is a binary that can read the key.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let open = directory.appending(path: "open")
        let own = directory.appending(path: "own")
        let plain = directory.appending(path: "plain")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: open)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: own)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: open.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: own.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)

        #expect(CertificateStore.isTrustworthyExecutable(open.path) == false, "world-writable was accepted")
        #expect(CertificateStore.isTrustworthyExecutable(own.path), "an ordinary executable was refused")
        #expect(CertificateStore.isTrustworthyExecutable(plain.path) == false, "not executable was accepted")

        // A symlink is judged by the file it resolves to, because that is the file that runs.
        let link = directory.appending(path: "link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: open.path)
        #expect(CertificateStore.isTrustworthyExecutable(link.path) == false, "a link to an open file passed")

        #expect(CertificateStore.whichOpenSSL(in: [plain.path, open.path]) == nil)
        #expect(CertificateStore.whichOpenSSL(in: [plain.path, link.path, own.path]) == own.path)
        // The machine's own answer: the system binary first, which is the root-owned one.
        #expect(CertificateStore.whichOpenSSL() == "/usr/bin/openssl")
    }

    @Test("Both of a child's pipes are drained, so a full error pipe cannot wedge the run")
    func bothPipesAreDrained() throws {
        // The fourth claim. The store had its own runner that read stdout to EOF before it looked at
        // stderr; a child that fills the error pipe blocks writing while this side blocks reading, and
        // neither ever moves. `SystemProcess` polls both, and this is the child that would have wedged the
        // old one: 200 KB of stderr — well past the 64 KB a pipe holds — before a byte of stdout.
        let result = try SystemProcess.run(
            "/bin/sh",
            ["-c", "head -c 200000 /dev/zero | tr '\\0' 'e' 1>&2; head -c 10 /dev/zero | tr '\\0' 'o'"],
            timeout: 10)
        #expect(result.status == 0)
        #expect(result.error.count == 200_000, "stderr was truncated: \(result.error.count)")
        #expect(result.output.count == 10, "stdout was truncated: \(result.output.count)")
    }

    @Test("The transport is told the size the key really is")
    func theTransportIsToldTheRealSize() {
        // The store carried a key kind that nothing read, while the transport hardcoded 2048 as well.
        #expect(EngineIdentity.KeyKind.rsa(sizeInBits: 3072).transportKind == .rsa(sizeInBits: 3072))
        #expect(EngineIdentity.KeyKind.rsa(sizeInBits: 2048).transportKind == .rsa(sizeInBits: 2048))
    }
}

@MainActor
@Suite("A larger identity reaches a real client (A155)", .serialized, TransportSerialized())
struct CertificateTransportAuditTests {

    @Test("A 3072-bit identity carries a real transport round trip")
    func aBiggerKeyConnects() async throws {
        // The end of claim two: not "the store reports 3072" but "the transport, told 3072, starts and
        // serves". Before the fix the transport was configured with 2048 whatever the key was.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "certificate-transport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try SystemProcess.run(
            "/usr/bin/openssl",
            [
                "req", "-x509", "-newkey", "rsa:3072",
                "-keyout", directory.appending(path: "webtransport-key.pem").path,
                "-out", directory.appending(path: "webtransport-cert.pem").path,
                "-days", "3", "-nodes", "-subj", "/CN=ChatBots Engine",
                "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1",
                "-addext", "basicConstraints=critical,CA:FALSE",
                "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
                "-addext", "extendedKeyUsage=serverAuth",
            ],
            timeout: 30)

        let identity = try CertificateStore.loadOrCreate(in: directory)
        #expect(identity.keyKind == .rsa(sizeInBits: 3072))

        let binary = try #require(
            ProcessInfo.processInfo.arguments.first(where: { $0.contains(".xctest/Contents/MacOS/") })
                .map { URL(fileURLWithPath: $0) }
                .map { url in
                    url.deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent().deletingLastPathComponent()
                        .appending(path: "chatbots-cli")
                },
            "no chatbots-cli beside the test bundle to start")
        let report = await TransportCheck.run(
            in: directory, port: allocateTestPort(), timeout: .seconds(15), executable: binary)
        #expect(
            report.succeeded,
            "a 3072-bit identity did not carry the check:\n\(report.describe())")
    }
}
