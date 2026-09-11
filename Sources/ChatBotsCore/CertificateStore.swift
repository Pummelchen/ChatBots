// ChatBotsCore — the engine's TLS identity, generated once and kept
//
// WebTransport runs over QUIC, which is always encrypted. A local engine therefore needs a
// certificate, and the client verifies it by pinning its SHA-256 fingerprint.
//
// **The certificate has to survive a restart.** The library's `.developmentSelfSigned` case
// generates a fresh key and certificate every time a server is constructed, and says so in its
// own documentation: the fingerprint changes across restarts, which makes it unusable for
// anything that pins. A client that trusted yesterday's fingerprint would refuse to connect
// today, and the failure would look like a broken engine. So the identity is generated once,
// stored, and reused — the same self-signed certificate on every launch, which is what makes
// pinning meaningful.
//
// **Nothing goes near the keychain.** The certificate and its key are read as DER bytes from
// the app's own folder and handed to the transport directly, which resolves them with
// `SecIdentityCreate` and no keychain involvement. The obvious alternative — a PKCS#12 bundle
// — does not: resolving one calls `SecPKCS12Import`, and on macOS that reaches into the login
// keychain and puts up a "chatbots-cli wants to sign using key … enter the login keychain
// password" dialog on every launch. The store owns its own files instead, and leaves the
// system's keychain alone.
//
// It is generated with `openssl` rather than assembled here. A self-signed X.509 certificate
// is a DER structure with a signature over it; writing that by hand is a few hundred lines of
// encoding whose bugs look like "the client cannot connect". `openssl` is present on macOS and
// gets this right. It runs once, at install or first launch, and never again.
//
// This is for the loopback channel between the app and the engine, both of which are this
// project. The website does not use it: Caddy serves browsers over HTTP.

import CryptoKit
import Foundation

/// A TLS identity on disk, with the fingerprint a client pins.
public struct EngineIdentity: Sendable, Equatable {
    /// The certificate, DER encoded, leaf first.
    public var certificateChainDER: [Data]
    /// The private key, DER encoded.
    public var privateKeyDER: Data
    /// Which curve or size the key is, so the transport can build it.
    public var keyKind: KeyKind
    /// SHA-256 of the certificate, which is what a client pins.
    public var fingerprintSHA256: Data

    public enum KeyKind: Sendable, Equatable {
        case rsa(sizeInBits: Int)

        /// What to use in a comment or a log.
        public var label: String {
            switch self {
            case .rsa(let bits): "RSA \(bits)"
            }
        }
    }

    public var fingerprintHex: String {
        fingerprintSHA256.map { String(format: "%02x", $0) }.joined()
    }

    /// The form a client shows and compares: colon-separated uppercase pairs.
    public var fingerprintDisplay: String {
        fingerprintSHA256.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

public enum CertificateStoreError: LocalizedError {
    case opensslUnavailable
    case generationFailed(String)
    case unusableIdentity(String)

    public var errorDescription: String? {
        switch self {
        case .opensslUnavailable:
            """
            openssl was not found, so the engine's certificate could not be generated. \
            It ships with macOS; if it is missing, install the Xcode command line tools \
            with: xcode-select --install
            """
        case .generationFailed(let detail):
            "The engine's certificate could not be generated: \(detail)"
        case .unusableIdentity(let detail):
            "The stored engine certificate could not be read: \(detail)"
        }
    }
}

/// Generates and loads the engine's certificate.
public enum CertificateStore {

    /// Load the identity, generating it if this is the first run.
    ///
    /// - Parameter directory: where to keep it. Defaults to the project's `.run`, which is
    ///   gitignored, so a developer's identity is never committed and two checkouts do not
    ///   fight over one file.
    public static func loadOrCreate(
        in directory: URL,
        hostnames: [String] = ["localhost", "127.0.0.1", "::1"],
        validityDays: Int = 3650
    ) throws -> EngineIdentity {
        // A long validity, deliberately. The certificate is pinned by fingerprint, so its
        // expiry is not what carries the trust — but an identity that expires mid-use would
        // break a running install for no benefit.
        let certificate = directory.appending(path: "webtransport-cert.pem")
        let privateKey = directory.appending(path: "webtransport-key.pem")

        if let identity = try? existing(certificate: certificate, privateKey: privateKey) {
            return identity
        }

        return try generate(
            in: directory, certificate: certificate, privateKey: privateKey,
            hostnames: hostnames, validityDays: validityDays)
    }

    /// Read an identity that is already on disk.
    ///
    /// Both files are converted to DER here, from PEM, because that is what the transport
    /// takes. It is a cheap read of two small local files and it touches no keychain.
    private static func existing(certificate: URL, privateKey: URL) throws -> EngineIdentity {
        let manager = FileManager.default
        guard manager.fileExists(atPath: certificate.path),
            manager.fileExists(atPath: privateKey.path)
        else {
            throw CertificateStoreError.unusableIdentity("not generated yet")
        }

        let chain = try derFromPEM(certificate, kind: "certificate")
        let key = try derFromPEM(privateKey, kind: "key")
        let fingerprint = try fingerprint(ofPEMCertificate: certificate)
        return EngineIdentity(
            certificateChainDER: [chain],
            privateKeyDER: key,
            keyKind: .rsa(sizeInBits: 2048),
            fingerprintSHA256: fingerprint)
    }

    private static func generate(
        in directory: URL, certificate: URL, privateKey: URL,
        hostnames: [String], validityDays: Int
    ) throws -> EngineIdentity {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let openssl = whichOpenSSL() else { throw CertificateStoreError.opensslUnavailable }

        // The subject alternative names matter: a client verifying the certificate checks the
        // authority it connected to, and "localhost" and the loopback addresses all have to be
        // present or a connection to an address that is not listed is refused.
        var alternatives = ["DNS:localhost"]
        for host in hostnames where host != "localhost" {
            alternatives.append("IP:\(host)")
        }

        let result = run(
            openssl,
            arguments: [
                "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", privateKey.path,
                "-out", certificate.path,
                "-days", String(validityDays),
                // No passphrase on the key. It never leaves this folder and is read only by
                // the engine on this machine; encrypting it would add a secret to manage
                // without adding a secret that is actually protected.
                "-nodes",
                "-subj", "/CN=ChatBots Engine",
                "-addext", "subjectAltName=\(alternatives.joined(separator: ","))",
                "-addext", "basicConstraints=critical,CA:FALSE",
                "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
                "-addext", "extendedKeyUsage=serverAuth",
            ])

        guard result.status == 0 else {
            throw CertificateStoreError.generationFailed(result.errorText)
        }
        // Readable only by this user. It is not a secret in the usual sense — it is local to
        // the machine — but there is no reason for it to be world-readable either.
        try? manager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: privateKey.path)

        return try existing(certificate: certificate, privateKey: privateKey)
    }

    // MARK: - openssl

    private static func whichOpenSSL() -> String? {
        for path in ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// SHA-256 over the certificate's DER, which is the value in the certificate itself.
    ///
    /// Taken from the certificate rather than from the PKCS#12, because the fingerprint a
    /// client reports is the certificate's, and the two must be comparable by eye.
    private static func fingerprint(ofPEMCertificate certificate: URL) throws -> Data {
        guard let openssl = whichOpenSSL() else { throw CertificateStoreError.opensslUnavailable }
        let der = run(
            openssl,
            arguments: ["x509", "-in", certificate.path, "-outform", "DER"])
        guard der.status == 0, !der.output.isEmpty else {
            throw CertificateStoreError.generationFailed("could not read the certificate")
        }
        return Data(SHA256.hash(data: der.output))
    }

    /// Convert a PEM file to DER.
    ///
    /// The certificate converts directly. The key converts to PKCS#1 (`RSAPrivateKey`), not
    /// PKCS#8, and that distinction is the difference between working and not: the transport
    /// hands the bytes to `SecKeyCreateWithData`, which for an RSA key expects PKCS#1 and
    /// rejects PKCS#8 with a bare `OSStatus -50`. Measured both, since the error says nothing
    /// about encoding.
    private static func derFromPEM(_ file: URL, kind: String) throws -> Data {
        guard let openssl = whichOpenSSL() else { throw CertificateStoreError.opensslUnavailable }
        let arguments: [String]
        switch kind {
        case "certificate":
            arguments = ["x509", "-in", file.path, "-outform", "DER"]
        default:
            arguments = ["rsa", "-in", file.path, "-outform", "DER"]
        }
        let result = run(openssl, arguments: arguments)
        guard result.status == 0, !result.output.isEmpty else {
            throw CertificateStoreError.generationFailed(
                "could not read the \(kind): \(result.errorText)")
        }
        return result.output
    }

    private struct ProcessResult {
        var status: Int32
        var output: Data
        var errorText: String
    }

    private static func run(_ executable: String, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return ProcessResult(
                status: -1, output: Data(), errorText: error.localizedDescription)
        }
        // Read before waiting: a large output would fill the pipe and deadlock if the process
        // were waited on first.
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            output: output,
            errorText: String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
