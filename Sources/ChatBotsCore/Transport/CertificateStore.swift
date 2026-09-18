// ChatBotsCore — the engine's TLS identity, generated once and kept
//
// WebTransport runs over QUIC, which is always encrypted. A local engine therefore needs a
// certificate, and this store keeps the same one across restarts.
//
// **What the fingerprint is for, and what it is not.** The client does *not* verify it: the transport
// is configured with the library's `.localDevelopmentSelfSigned` policy, a loopback-only bypass of
// platform certificate validation, so the engine's SHA-256 is **reported and logged but not
// enforced** — that is the trade `SECURITY.md` states, and the note at the top of
// `WebTransportClient.swift` says the same from the client's side. A stable identity is what makes
// the report worth anything (the value a person compares against a log is the same one today as
// yesterday), and it is what a trust callback would need if the trade is ever revisited.
//
// **The certificate has to survive a restart.** The library's `.developmentSelfSigned` case
// generates a fresh key and certificate every time a server is constructed, and says so in its
// own documentation: the fingerprint changes across restarts. So the identity is generated once,
// stored, and reused — the same self-signed certificate on every launch, and the same fingerprint
// reported for it.
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
import Security

/// A TLS identity on disk, with the SHA-256 fingerprint the engine reports for it.
public struct EngineIdentity: Sendable, Equatable {
    /// The certificate, DER encoded, leaf first.
    public var certificateChainDER: [Data]
    /// The private key, DER encoded.
    public var privateKeyDER: Data
    /// Which curve or size the key is, so the transport can build it.
    public var keyKind: KeyKind
    /// SHA-256 of the certificate — the value a client would pin, reported and logged rather than
    /// enforced. See the note at the top of this file.
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
    case insecurePrivateKey(String)

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
        case .insecurePrivateKey(let path):
            """
            The engine's private key at \(path) is readable by other users on this Mac and could \
            not be made private. Anyone who can read it can impersonate the engine to the app. \
            Fix it with `chmod 600 "\(path)"`, or delete it and let the engine generate a new \
            identity.
            """
        }
    }
}

/// Generates and loads the engine's certificate.
public enum CertificateStore {

    /// Load the identity, generating it if this is the first run.
    ///
    /// - Parameter directory: where to keep it. Required rather than defaulted: the caller is the
    ///   only thing that knows whether this process is a checkout, which uses `.run`, or an
    ///   installed build, which uses `~/Library/Application Support/ChatBots`. `RunDirectory` is
    ///   that one answer. Either way the directory is private to the user, so a developer's
    ///   identity is never committed and two checkouts do not fight over one file.
    public static func loadOrCreate(
        in directory: URL,
        hostnames: [String] = ["localhost", "127.0.0.1", "::1"],
        validityDays: Int = 3650
    ) throws -> EngineIdentity {
        // A long validity, deliberately. Nothing here carries trust by expiry — the client accepts the
        // loopback certificate without checking it (see the note at the top of this file) — but an
        // identity that expires mid-use would break a running install for no benefit.
        let certificate = directory.appending(path: "webtransport-cert.pem")
        let privateKey = directory.appending(path: "webtransport-key.pem")

        // Generate only when there is nothing to read. This was `if let identity = try? existing(…)`, so
        // *any* read failure — a permission change, a truncated file, a half-finished copy — was
        // indistinguishable from a first run, and the store quietly replaced the identity: the
        // certificate the engine serves changed with no explanation, and the fingerprint recorded in a
        // log or a check no longer matched what came back. One file present is still "an identity
        // exists": the other being gone is a failure to report, not a reason to rotate the identity out
        // from under the run that is serving with it.
        let manager = FileManager.default
        guard
            !manager.fileExists(atPath: certificate.path),
            !manager.fileExists(atPath: privateKey.path)
        else {
            return try existing(certificate: certificate, privateKey: privateKey, hostnames: hostnames)
        }

        return try generate(
            in: directory, certificate: certificate, privateKey: privateKey,
            hostnames: hostnames, validityDays: validityDays)
    }

    /// Read an identity that is already on disk.
    ///
    /// Both files are converted to DER here, from PEM, because that is what the transport
    /// takes. It is a cheap read of two small local files and it touches no keychain.
    private static func existing(
        certificate: URL, privateKey: URL, hostnames: [String]
    ) throws -> EngineIdentity {
        let manager = FileManager.default
        // Which file is missing is the one thing an operator can act on, and the old message — "not
        // generated yet" — was also what a *half* identity reported, which reads as "nothing here" rather
        // than "this install is damaged".
        guard manager.fileExists(atPath: certificate.path) else {
            throw incomplete(missing: certificate.lastPathComponent, surviving: privateKey.lastPathComponent)
        }
        guard manager.fileExists(atPath: privateKey.path) else {
            throw incomplete(missing: privateKey.lastPathComponent, surviving: certificate.lastPathComponent)
        }

        // Before the key is read, not after: the load path used to trust whatever mode it found, so a
        // key that was already too open stayed that way for the life of the install.
        try restrictToThisUser(privateKey)

        let chain = try derFromPEM(certificate, kind: "certificate")
        let key = try derFromPEM(privateKey, kind: "key")
        let fingerprint = try fingerprint(ofPEMCertificate: certificate)
        try checkPair(certificate: certificate, privateKey: privateKey)
        try check(certificateDER: chain, covers: hostnames, in: certificate.deletingLastPathComponent())
        return EngineIdentity(
            certificateChainDER: [chain],
            privateKeyDER: key,
            keyKind: .rsa(sizeInBits: try rsaSizeInBits(ofKey: privateKey)),
            fingerprintSHA256: fingerprint)
    }

    /// The refusal for an identity that is only half on disk.
    ///
    /// The message names the file to delete, because refusing without a way forward would leave an
    /// install that cannot start: the surviving half is useless on its own, so the operator's move is to
    /// remove it and let the next start generate a new identity — which they are told changes the
    /// fingerprint the engine reports.
    private static func incomplete(missing: String, surviving: String) -> CertificateStoreError {
        .unusableIdentity(
            """
            \(missing) is missing, so the stored identity is incomplete. Delete \(surviving) beside it to \
            generate a new one — which changes the fingerprint the engine reports.
            """)
    }

    // MARK: - What the stored files actually are

    /// The size of the RSA key, read from the key.
    ///
    /// `.rsa(sizeInBits: 2048)` used to be written into the identity whatever the file held, and the
    /// transport was handed its own hardcoded 2048 as well, so a key of another size was described
    /// wrongly to `SecKeyCreateWithData` — which fails with an error that names nothing an operator can
    /// act on. `openssl rsa -modulus` prints the modulus as hex, and one hex digit is four bits.
    static func rsaSizeInBits(ofKey privateKey: URL) throws -> Int {
        guard let openssl = whichOpenSSL() else { throw CertificateStoreError.opensslUnavailable }
        let result = try run(openssl, ["rsa", "-in", privateKey.path, "-noout", "-modulus"])
        guard result.status == 0 else {
            throw CertificateStoreError.unusableIdentity(
                "the private key is not an RSA key this store can use: \(result.error)")
        }
        let line = (String(bytes: result.output, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(modulusPrefix) else {
            throw CertificateStoreError.unusableIdentity("the private key has no modulus")
        }
        let hex = line.dropFirst(modulusPrefix.count)
        guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit) else {
            throw CertificateStoreError.unusableIdentity(
                "the private key's modulus is not a run of hex digits")
        }
        return hex.count * 4
    }

    private static let modulusPrefix = "Modulus="

    /// Refuse a certificate and a key that are not a pair.
    ///
    /// A key restored from a backup beside a certificate from another install loads here and fails in the
    /// handshake, where an operator is told nothing about which file is wrong. The public key
    /// derived from each has to be the same bytes.
    static func checkPair(certificate: URL, privateKey: URL) throws {
        guard let openssl = whichOpenSSL() else { throw CertificateStoreError.opensslUnavailable }
        let fromCertificate = try run(
            openssl, ["x509", "-in", certificate.path, "-noout", "-pubkey"])
        let fromKey = try run(openssl, ["rsa", "-in", privateKey.path, "-pubout"])
        guard fromCertificate.status == 0, fromKey.status == 0 else {
            throw CertificateStoreError.unusableIdentity(
                "the certificate's public key could not be read: \(fromCertificate.error)")
        }
        guard withoutWhitespace(fromCertificate.output) == withoutWhitespace(fromKey.output) else {
            throw CertificateStoreError.unusableIdentity(
                """
                the stored certificate and private key are not a pair, so the engine cannot prove it owns \
                the certificate it presents. Delete both files beside \(certificate.lastPathComponent) to \
                generate a new identity — which changes the fingerprint the engine reports.
                """)
        }
    }

    /// PEM text with every run of whitespace removed, for comparing two exports of the same key.
    ///
    /// The body of a PEM block is base64 wrapped at a fixed width, so two exports of the same key differ
    /// only in line endings — and they come from the same program, so removing the whitespace compares the
    /// material rather than the formatting.
    private static func withoutWhitespace(_ data: Data) -> String {
        (String(bytes: data, encoding: .utf8) ?? "").split(whereSeparator: \.isWhitespace).joined()
    }

    /// Refuse a certificate that does not name every hostname the caller asked for.
    ///
    /// `hostnames` was honoured only when the identity was generated: on every later load it was ignored,
    /// so a caller asking for a name the certificate does not carry got a server that came up and a client
    /// whose own verification refused it, with an error that mentions no certificate.
    static func check(certificateDER: Data, covers hostnames: [String], in directory: URL) throws {
        guard !certificateCovers(certificateDER, hostnames: hostnames) else { return }
        throw CertificateStoreError.unusableIdentity(
            """
            the stored certificate does not cover \(hostnames.joined(separator: ", ")). Delete the \
            identity in \(directory.path) to generate one that does — which changes the fingerprint the \
            engine reports.
            """)
    }

    /// Whether the certificate's subject alternative names cover every hostname asked for.
    ///
    /// Read through Security rather than by parsing `openssl`'s text: the same IPv6 address prints as
    /// `0:0:0:0:0:0:0:1` in one version and `::1` in another, and `inet_pton` reads both. A hostname is
    /// matched case-insensitively, an address by its bytes.
    static func certificateCovers(_ certificateDER: Data, hostnames: [String]) -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
            let values = SecCertificateCopyValues(certificate, [kSecOIDSubjectAltName] as CFArray, nil)
                as? [CFString: Any],
            let section = values[kSecOIDSubjectAltName] as? [CFString: Any],
            let items = section[kSecPropertyKeyValue] as? [[CFString: Any]]
        else { return false }

        // The labels are not used: an address is recognised by parsing as one, which is the same rule the
        // comparison uses, and no label has to be spelled the way this code hopes.
        let names = items.compactMap { $0[kSecPropertyKeyValue] as? String }
        return hostnames.allSatisfy { host in
            if let address = addressBytes(host) {
                return names.contains { addressBytes($0) == address }
            }
            let wanted = host.lowercased()
            return names.contains { addressBytes($0) == nil && $0.lowercased() == wanted }
        }
    }

    /// The bytes of an IP address literal, or nil when the text is not one.
    static func addressBytes(_ text: String) -> Data? {
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, text, &ipv6) == 1 {
            return withUnsafeBytes(of: ipv6) { Data($0) }
        }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, text, &ipv4) == 1 {
            return withUnsafeBytes(of: ipv4) { Data($0) }
        }
        return nil
    }

    /// Readable and writable by this user only.
    private static let privateKeyPermissions = 0o600

    /// Make sure the private key is not readable by anyone else, and refuse to go on if it is.
    ///
    /// openssl writes the key under the process umask, so a permissive umask, a restored backup or a
    /// copy by hand is all it takes for the engine's identity to be readable by every user on the
    /// machine. The result of the `setAttributes` call used to be discarded with `try?`, which meant a
    /// failed chmod was silent; the mode is now applied and *read back*, and a key that is
    /// still exposed stops the engine with a message naming the file and the fix, rather than starting
    /// with a hole in it.
    private static func restrictToThisUser(_ privateKey: URL) throws {
        let manager = FileManager.default
        if let current = permissions(of: privateKey), current & 0o077 != 0 {
            try manager.setAttributes(
                [.posixPermissions: privateKeyPermissions], ofItemAtPath: privateKey.path)
        }
        guard let applied = permissions(of: privateKey), applied & 0o077 == 0 else {
            throw CertificateStoreError.insecurePrivateKey(privateKey.path)
        }
    }

    /// The mode of `url`, or `nil` if it cannot be read.
    private static func permissions(of url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
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

        let result = try run(
            openssl,
            [
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
            throw CertificateStoreError.generationFailed(result.error)
        }
        // Readable only by this user. It is not a secret in the usual sense — it is local to
        // the machine — but there is no reason for it to be world-readable either, and the mode is
        // now checked rather than assumed: `try?` here used to swallow a failed chmod.
        try restrictToThisUser(privateKey)

        return try existing(certificate: certificate, privateKey: privateKey, hostnames: hostnames)
    }

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
    private static func fingerprint(ofPEMCertificate certificate: URL) throws -> Data {
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
    private static func derFromPEM(_ file: URL, kind: String) throws -> Data {
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
    private static func run(_ executable: String, _ arguments: [String]) throws -> SystemProcess.Result {
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
