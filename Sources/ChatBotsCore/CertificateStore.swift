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
    /// PKCS#12 bundle: leaf certificate, chain and private key.
    public var pkcs12: Data
    /// The passphrase protecting the bundle. Generated with it and stored beside it.
    public var passphrase: String
    /// SHA-256 of the certificate, which is what a client pins.
    public var fingerprintSHA256: Data

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
        let passphraseFile = directory.appending(path: "webtransport.passphrase")
        let bundleFile = directory.appending(path: "webtransport.p12")
        // A long validity, deliberately. The certificate is pinned by fingerprint, so its
        // expiry is not what carries the trust — but an identity that expires mid-use would
        // break a running install for no benefit.
        let certificate = directory.appending(path: "webtransport-cert.pem")
        let privateKey = directory.appending(path: "webtransport-key.pem")

        if let identity = try? existing(
            certificate: certificate, privateKey: privateKey, passphraseFile: passphraseFile,
            bundleFile: bundleFile)
        {
            return identity
        }

        return try generate(
            in: directory, certificate: certificate, privateKey: privateKey,
            passphraseFile: passphraseFile, bundleFile: bundleFile, hostnames: hostnames,
            validityDays: validityDays)
    }

    /// Read an identity that is already on disk.
    private static func existing(
        certificate: URL, privateKey: URL, passphraseFile: URL, bundleFile: URL
    ) throws -> EngineIdentity {
        let manager = FileManager.default
        guard manager.fileExists(atPath: certificate.path),
            manager.fileExists(atPath: privateKey.path),
            manager.fileExists(atPath: passphraseFile.path)
        else {
            throw CertificateStoreError.unusableIdentity("not generated yet")
        }
        guard let passphrase = try? String(contentsOf: passphraseFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !passphrase.isEmpty
        else {
            throw CertificateStoreError.unusableIdentity("the passphrase file is empty")
        }

        // Read the stored bundle. If it is missing — an interrupted first run, or a version
        // that did not write one — rebuild it from the key and certificate, which are the
        // files that actually carry the identity.
        let bundle: Data
        if let stored = try? Data(contentsOf: bundleFile), !stored.isEmpty {
            bundle = stored
        } else {
            bundle = try bundlePKCS12(
                certificate: certificate, privateKey: privateKey, passphrase: passphrase)
            try? bundle.write(to: bundleFile)
        }
        let fingerprint = try fingerprint(ofPEMCertificate: certificate)
        return EngineIdentity(
            pkcs12: bundle, passphrase: passphrase, fingerprintSHA256: fingerprint)
    }

    private static func generate(
        in directory: URL, certificate: URL, privateKey: URL, passphraseFile: URL,
        bundleFile: URL, hostnames: [String], validityDays: Int
    ) throws -> EngineIdentity {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let openssl = whichOpenSSL() else { throw CertificateStoreError.opensslUnavailable }

        // One passphrase for the bundle, generated rather than fixed. It protects a key that
        // only ever exists on this machine and is read by a process that already has the file,
        // so its job is to be unpredictable rather than memorable.
        let passphrase = randomPassphrase()
        try passphrase.write(to: passphraseFile, atomically: true, encoding: .utf8)
        try manager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: passphraseFile.path)

        // RSA rather than the smaller, faster EC key, and this is not a preference.
        // Security.framework cannot turn an openssl-written EC private key into a SecKeyRef —
        // the PKCS#12 import yields a NULL key and the library then trips over it — while an
        // RSA key imports cleanly. Measured, not assumed: the same code path with a P-256 key
        // fails and with RSA:2048 succeeds.
        //
        // The subject alternative names matter: a client verifying the certificate checks the
        // authority it connected to, and "localhost" and the loopback addresses all have to be
        // present or a connection to an address that is not listed is refused.
        var alternatives = ["DNS:localhost"]
        for host in hostnames where host != "localhost" {
            alternatives.append(host.contains(":") ? "IP:\(host)" : "IP:\(host)")
        }

        let result = run(
            openssl,
            arguments: [
                "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", privateKey.path,
                "-out", certificate.path,
                "-days", String(validityDays),
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
        // The key is readable only by this user. It is not a secret in the usual sense — it is
        // local to the machine — but there is no reason for it to be world-readable either.
        try? manager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: privateKey.path)

        let bundle = try bundlePKCS12(
            certificate: certificate, privateKey: privateKey, passphrase: passphrase)
        try bundle.write(to: bundleFile)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: bundleFile.path)
        let fingerprint = try fingerprint(ofPEMCertificate: certificate)
        return EngineIdentity(
            pkcs12: bundle, passphrase: passphrase, fingerprintSHA256: fingerprint)
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

    private static func bundlePKCS12(
        certificate: URL, privateKey: URL, passphrase: String
    ) throws -> Data {
        guard let openssl = whichOpenSSL() else { throw CertificateStoreError.opensslUnavailable }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "chatbots-p12-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appending(path: "identity.p12")

        let result = run(
            openssl,
            arguments: [
                "pkcs12", "-export",
                "-out", bundle.path,
                "-inkey", privateKey.path,
                "-in", certificate.path,
                "-passout", "pass:\(passphrase)",
                // No algorithm flags: macOS ships LibreSSL, whose PKCS#12 defaults (RC2-40 for
                // the certificate, 3DES for the key) are what Security.framework expects. The
                // `-legacy` flag that OpenSSL 3 needs for this does not exist in LibreSSL, and
                // passing it fails outright.
            ])
        guard result.status == 0 else {
            throw CertificateStoreError.generationFailed(result.errorText)
        }
        return try Data(contentsOf: bundle)
    }

    private static func randomPassphrase() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
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
