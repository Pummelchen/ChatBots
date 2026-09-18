// ChatBotsCore — running `openssl` for the engine's certificate
//
// Split out of `CertificateStore.swift`, which had grown past the repository's 500-line limit. This
// is the whole of "find a trustworthy `openssl`, run it, and read what it produced"; the store's
// own decisions — what a valid stored pair is, when to generate one, and the modes it must have —
// stay in the store.

import CryptoKit
import Foundation

extension CertificateStore {

    // MARK: - openssl

    /// The `openssl` binaries this store will run, best first.
    ///
    /// `/usr/bin/openssl` is the one macOS ships and is owned by root. The Homebrew prefixes are kept as a
    /// fallback — a machine can be without the system binary — but a candidate is only used when no other
    /// user could have replaced it, because this program's argument list carries the path of the private
    /// key it is about to write: a binary someone else can write is a binary that can read the key.
    static let opensslSearchPaths = [
        "/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl",
    ]

    static func whichOpenSSL(in paths: [String] = opensslSearchPaths) -> String? {
        paths.first(where: isTrustworthyExecutable)
    }

    /// Whether `path` is executable by this user and cannot be written by any other user.
    ///
    /// Symlinks are followed — `/opt/homebrew/bin/openssl` is one — because the file that runs is the one at
    /// the end of the chain, and group-write is refused along with other-write: on macOS an admin group can
    /// write files its members cannot, which is the same exposure one step narrower.
    static func isTrustworthyExecutable(_ path: String) -> Bool {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: path),
            let attributes = try? manager.attributesOfItem(
                atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path),
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
        else { return false }
        return mode & 0o022 == 0
    }

    /// SHA-256 over the certificate's DER, which is the value in the certificate itself.
    ///
    /// Taken from the certificate rather than from the PKCS#12, because the fingerprint a
    /// client reports is the certificate's, and the two must be comparable by eye.
    static func fingerprint(ofPEMCertificate certificate: URL) throws -> Data {
        guard let openssl = whichOpenSSL() else { throw CertificateStoreError.opensslUnavailable }
        let der = try run(openssl, ["x509", "-in", certificate.path, "-outform", "DER"])
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
    static func derFromPEM(_ file: URL, kind: String) throws -> Data {
        guard let openssl = whichOpenSSL() else { throw CertificateStoreError.opensslUnavailable }
        let arguments: [String]
        switch kind {
        case "certificate":
            arguments = ["x509", "-in", file.path, "-outform", "DER"]
        default:
            arguments = ["rsa", "-in", file.path, "-outform", "DER"]
        }
        let result = try run(openssl, arguments)
        guard result.status == 0, !result.output.isEmpty else {
            throw CertificateStoreError.generationFailed(
                "could not read the \(kind): \(result.error)")
        }
        return result.output
    }

    /// How long one `openssl` call may take.
    ///
    /// Shorter than the document converters' budget: this runs at engine start, and a certificate
    /// operation that has not finished in twenty seconds is not going to.
    static let opensslTimeout: TimeInterval = 20

    /// Run `openssl`, collected by the project's own runner.
    ///
    /// This file had a runner of its own that read stdout to EOF before it looked at stderr, which is the
    /// two-pipe deadlock `SystemProcess` was written to avoid: a child that fills the error pipe — a bad
    /// argument list does it — blocks writing while this side blocks reading, and the engine never starts.
    /// The shared runner polls both pipes against a deadline.
    static func run(_ executable: String, _ arguments: [String]) throws -> SystemProcess.Result {
        do {
            return try SystemProcess.run(
                executable, arguments, timeout: opensslTimeout,
                maximumOutputBytes: maximumOpenSSLOutputBytes)
        } catch {
            // `SystemProcess` reports its refusals as document errors; through this door they are a
            // certificate that could not be read or made.
            throw CertificateStoreError.generationFailed(error.localizedDescription)
        }
    }

    /// A ceiling on what one `openssl` call may print.
    ///
    /// The certificate and key are kilobytes; the shared runner's default is the 64 MB an attachment may
    /// be, which is a budget this path has no use for.
    static let maximumOpenSSLOutputBytes = 4 * 1_024 * 1_024
}
