// ChatBotsCoreTests — the engine's TLS identity

import ChatBotsCore
import Foundation
import Testing

@Suite("Engine certificate")
struct CertificateStoreTests {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "chatbots-cert-test-\(UUID().uuidString)")
    }

    @Test("An identity is generated and is usable")
    func generates() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let identity = try CertificateStore.loadOrCreate(in: directory)
        #expect(!identity.pkcs12.isEmpty, "the bundle should have contents")
        #expect(!identity.passphrase.isEmpty)
        #expect(identity.fingerprintSHA256.count == 32, "SHA-256 is 32 bytes")
        #expect(identity.fingerprintHex.count == 64)
        #expect(identity.fingerprintDisplay.contains(":"))
    }

    @Test("The same identity comes back on the next load, which is what pinning needs")
    func isStableAcrossLoads() throws {
        // The reason this type exists. The library's development identity is regenerated on
        // every server construction, so its fingerprint changes each restart and a pinned
        // client would refuse to connect. If this test ever fails, the app will break on
        // relaunch in a way that looks like a dead engine.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try CertificateStore.loadOrCreate(in: directory)
        let second = try CertificateStore.loadOrCreate(in: directory)

        #expect(first.fingerprintSHA256 == second.fingerprintSHA256)
        #expect(first.passphrase == second.passphrase)
        #expect(first.pkcs12 == second.pkcs12)
    }

    @Test("Two separate stores have different identities")
    func distinctPerDirectory() throws {
        // A stable fingerprint must not mean a shared key: two installations are two
        // identities, and neither should be able to impersonate the other.
        let one = temporaryDirectory()
        let two = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: one)
            try? FileManager.default.removeItem(at: two)
        }
        let first = try CertificateStore.loadOrCreate(in: one)
        let second = try CertificateStore.loadOrCreate(in: two)
        #expect(first.fingerprintSHA256 != second.fingerprintSHA256)
    }

    @Test("The private key is not world-readable")
    func keyPermissions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try CertificateStore.loadOrCreate(in: directory)

        for name in ["webtransport-key.pem", "webtransport.passphrase"] {
            let path = directory.appending(path: name).path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let permissions = attributes[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600, "\(name) should be owner-only")
        }
    }

    @Test("A partial identity on disk is regenerated rather than half-used")
    func repairsPartialState() throws {
        // A crash between writing the files would otherwise leave an install that can never
        // start again, with an error about a missing passphrase rather than a fix.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try CertificateStore.loadOrCreate(in: directory)

        // Remove the passphrase, as an interrupted first run would.
        try FileManager.default.removeItem(at: directory.appending(path: "webtransport.passphrase"))

        let repaired = try CertificateStore.loadOrCreate(in: directory)
        #expect(!repaired.pkcs12.isEmpty)
        // A new identity, because the passphrase that protected the old bundle is gone.
        #expect(repaired.fingerprintSHA256 != identity.fingerprintSHA256
            || repaired.pkcs12 != identity.pkcs12)
    }

    @Test("An empty passphrase file does not produce a silently broken identity")
    func emptyPassphraseIsRefused() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try CertificateStore.loadOrCreate(in: directory)
        try "".write(
            to: directory.appending(path: "webtransport.passphrase"), atomically: true,
            encoding: .utf8)

        // Either it regenerates or it raises; what it must not do is return an identity whose
        // bundle cannot be opened.
        do {
            let identity = try CertificateStore.loadOrCreate(in: directory)
            #expect(!identity.passphrase.isEmpty)
        } catch {
            #expect(error is CertificateStoreError)
        }
    }
}
