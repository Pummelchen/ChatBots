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
    ///
    /// `lstat` rather than `FileManager.attributesOfItem`, which follows a symbolic link: a link
    /// pointing at a 0600 file would report 0600 while the thing being checked was something else.
    private static func permissions(of url: URL) -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Int(info.st_mode & 0o777)
    }

    private static func generate(
        in directory: URL, certificate: URL, privateKey: URL,
        hostnames: [String], validityDays: Int
    ) throws -> EngineIdentity {
        let manager = FileManager.default
        // 0700 from the moment it exists, and tightened when it already does. The directory used
        // to be created under the process umask and never checked, so under a permissive umask
        // the folder holding the private key was world-traversable.
        try? manager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        guard let openssl = whichOpenSSL() else { throw CertificateStoreError.opensslUnavailable }

        // The subject alternative names matter: a client verifying the certificate checks the
        // authority it connected to, and "localhost" and the loopback addresses all have to be
        // present or a connection to an address that is not listed is refused.
        var alternatives = ["DNS:localhost"]
        for host in hostnames where host != "localhost" {
            alternatives.append("IP:\(host)")
        }

        // The pair is generated inside a private staging directory and moved into place, rather
        // than written straight to its final path. `-keyout` writes under the process umask, so
        // the key existed as 0644 until the chmod below ran; inside this 0700 directory nothing
        // outside the user can reach it at any point, and a rename keeps the 0600 mode.
        let staging = directory.appending(path: ".staging-\(UUID().uuidString)")
        try manager.createDirectory(
            at: staging, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let stagedKey = staging.appending(path: "privateKey.pem")
        let stagedCertificate = staging.appending(path: "certificate.pem")

        let result = try run(
            openssl,
            [
                "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", stagedKey.path,
                "-out", stagedCertificate.path,
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
        // checked rather than assumed: `try?` here used to swallow a failed chmod.
        try restrictToThisUser(stagedKey)
        // Moved rather than copied, so the 0600 mode is the one that lands, and the previous pair
        // is removed first because `moveItem` refuses an existing destination.
        try? manager.removeItem(at: privateKey)
        try? manager.removeItem(at: certificate)
        try manager.moveItem(at: stagedCertificate, to: certificate)
        try manager.moveItem(at: stagedKey, to: privateKey)

        return try existing(certificate: certificate, privateKey: privateKey, hostnames: hostnames)
    }
}
