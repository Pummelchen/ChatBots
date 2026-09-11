// ChatBotsCoreTests — the engine's TLS identity

import ChatBotsCore
import Foundation
import Security
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
        // The certificate and the key, as DER, which is what the transport takes. No bundle
        // and no passphrase: those existed only to be imported through the keychain, which is
        // what put a password dialog on every launch.
        #expect(!identity.certificateChainDER.isEmpty, "there should be a certificate")
        #expect(!identity.privateKeyDER.isEmpty, "there should be a private key")
        #expect(identity.keyKind == .rsa(sizeInBits: 2048))
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
        #expect(first.certificateChainDER == second.certificateChainDER)
        #expect(first.privateKeyDER == second.privateKeyDER)
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

        for name in ["webtransport-key.pem"] {
            let path = directory.appending(path: name).path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let permissions = attributes[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600, "\(name) should be owner-only")
        }
    }

    @Test("A partial identity on disk is regenerated rather than half-used")
    func repairsPartialState() throws {
        // A crash between writing the two files would otherwise leave an install that can
        // never start again, with an error about a missing key rather than a fix.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try CertificateStore.loadOrCreate(in: directory)

        // Remove the key, as an interrupted first run would.
        try FileManager.default.removeItem(at: directory.appending(path: "webtransport-key.pem"))

        let repaired = try CertificateStore.loadOrCreate(in: directory)
        #expect(!repaired.privateKeyDER.isEmpty)
        // A new identity, because the key the old certificate matched is gone.
        #expect(repaired.fingerprintSHA256 != identity.fingerprintSHA256)
    }

    @Test("The private key is in the encoding the transport accepts")
    func keyEncodingIsUsable() throws {
        // PKCS#1, not PKCS#8. The transport hands these bytes to SecKeyCreateWithData, which
        // for RSA expects PKCS#1 and rejects PKCS#8 with a bare OSStatus -50 that says nothing
        // about encoding. Guarded here because nothing else would notice until a connection
        // failed.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try CertificateStore.loadOrCreate(in: directory)

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false,
        ]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(
            identity.privateKeyDER as CFData, attributes as CFDictionary, &error)
        #expect(key != nil, "Security.framework rejected the key: \(error.map { String(describing: $0.takeRetainedValue()) } ?? "?")")
    }
}
