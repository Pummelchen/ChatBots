// ChatBotsCore — the per-run secret that says which engine is which
//
// The desktop app starts an engine as a child process, and it also adopts one that is already
// running. Both mean the app has to answer "is the thing on the transport port the engine this
// user started, or something else that took the port?" — and it cannot answer that from the
// certificate, because the channel is `localDevelopmentSelfSigned`, which does not verify the
// peer. A same-user process that binds 127.0.0.1:7790 before the real engine starts would
// otherwise be adopted, and the app fills each seat's cloud key from the Keychain and sends it.
//
// So the engine writes a random token to the run directory, mode 0600, before its transports
// accept a connection, and answers `.identify` with it. The app reads the same file and adopts an
// engine only when the echo matches. The token is deliberately transport-only: there is no route
// that puts it on the HTTP API, and no `APISnapshot` carries it, so the unauthenticated web
// surface cannot learn it even by asking.
//
// What this does not claim: the file is readable by any process running as this user, so this
// closes the window in which the port is taken *before* the engine starts rather than making a
// same-user attacker impossible. It is the identity check the transport library does not offer,
// and it is strictly more than the app had.
//
// One path rule, from `RunDirectory`: every function here takes the run directory its caller
// already resolved, rather than asking for a location of its own.

import Foundation

/// The random token one engine run writes and answers `.identify` with.
public enum SessionToken {

    /// The name of the file inside the run directory.
    public static let filename = "session-token"

    /// 256 bits of randomness. Long enough that guessing is not a threat even against a process
    /// that can open connections as fast as the port accepts them.
    private static let byteCount = 32

    /// The token file's mode: readable and writable by its owner only.
    private static let fileMode: mode_t = 0o600

    /// The mode a missing run directory is created with.
    private static let directoryMode: mode_t = 0o700

    /// Write a fresh token for a run, replacing any left by an earlier one.
    ///
    /// The token goes to a sibling file created at `fileMode` with `O_CREAT|O_EXCL`, and is then
    /// renamed over the destination. A reader therefore never sees a partly written token, and
    /// never sees one with wider permissions first: there is no moment at which the bytes exist
    /// at anything but 0600. The mode is set with the create call and `fchmod` rather than left to
    /// the process umask.
    @discardableResult
    public static func issue(in runDirectory: URL) throws -> String {
        try ensureDirectory(runDirectory)
        let token = randomHex()
        let temporary = runDirectory.appending(path: "\(filename).\(UUID().uuidString).tmp")
        let destination = fileURL(in: runDirectory)
        do {
            try writeToken(token, to: temporary)
            try move(temporary, to: destination)
        } catch {
            // A run that cannot leave a complete token behind must not leave a fragment either.
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return token
    }

    /// The token on disk, or nil when there is none — or when the file is empty.
    ///
    /// Nil rather than an empty string, so "no token" is one answer everywhere: a caller cannot
    /// mistake an empty file for an identity.
    public static func read(from runDirectory: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL(in: runDirectory)),
            !data.isEmpty,
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether `candidate` is this run's token.
    ///
    /// Compared without stopping at the first differing byte, so how much of a guess was right is
    /// not readable from how long the answer took.
    public static func matches(_ candidate: String, in runDirectory: URL) -> Bool {
        guard let token = read(from: runDirectory) else { return false }
        return equalsWithoutEarlyExit(candidate, token)
    }

    /// Forget the token of a run that has stopped, so a later process cannot present it.
    public static func remove(from runDirectory: URL) {
        try? FileManager.default.removeItem(at: fileURL(in: runDirectory))
    }

    private static func fileURL(in runDirectory: URL) -> URL {
        runDirectory.appending(path: filename)
    }

    /// Create the run directory at `directoryMode` when it is missing.
    ///
    /// An existing directory is left as it is: `.run` is shared with the certificate installer,
    /// and this is not the place to rewrite a directory somebody else created.
    private static func ensureDirectory(_ runDirectory: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: runDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SessionTokenError.notADirectory(runDirectory)
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: runDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: directoryMode)])
            // The create attributes are filtered through the umask, so the mode is stated again
            // explicitly. A run directory another account can read is part of the defect.
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: directoryMode)],
                ofItemAtPath: runDirectory.path)
        } catch {
            throw SessionTokenError.cannotCreateDirectory(
                runDirectory, error.localizedDescription)
        }
    }

    /// Write `token` to a file that must not already exist, with `fileMode`.
    private static func writeToken(_ token: String, to url: URL) throws {
        let descriptor = openExclusively(url)
        guard descriptor >= 0 else {
            throw SessionTokenError.cannotWrite(url, String(cString: strerror(errno)))
        }
        // `O_CREAT`'s mode is masked by the umask; this makes 0600 the answer regardless of it.
        guard fchmod(descriptor, fileMode) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw SessionTokenError.cannotWrite(url, reason)
        }

        let bytes = Data(token.utf8)
        let written = writeAll(bytes, to: descriptor)
        guard written == bytes.count else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw SessionTokenError.cannotWrite(url, reason)
        }
        guard close(descriptor) == 0 else {
            throw SessionTokenError.cannotWrite(url, String(cString: strerror(errno)))
        }
    }

    /// Open `url` for writing, creating it at `fileMode` and refusing one that exists.
    private static func openExclusively(_ url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, fileMode)
        }
    }

    /// Write every byte, or return how many were written before it stopped.
    private static func writeAll(_ bytes: Data, to descriptor: Int32) -> Int {
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                guard let base = raw.baseAddress else { return }
                let result = write(descriptor, base.advanced(by: offset), raw.count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += result
            }
        }
        return offset
    }

    /// Rename `temporary` over `destination`, replacing an earlier token in one step.
    private static func move(_ temporary: URL, to destination: URL) throws {
        let result = temporary.withUnsafeFileSystemRepresentation { from -> Int32 in
            destination.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return -1 }
                return rename(from, to)
            }
        }
        guard result == 0 else {
            throw SessionTokenError.cannotWrite(
                destination, String(cString: strerror(errno)))
        }
    }

    /// 32 random bytes, lowercased hex.
    private static func randomHex() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteCount)
        for _ in 0..<byteCount {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Equality without an early exit on the first differing byte.
    ///
    /// The lengths are folded in rather than compared first, so the loop runs over the whole of
    /// the longer input whatever the answer is.
    private static func equalsWithoutEarlyExit(_ candidate: String, _ token: String) -> Bool {
        let left = Array(candidate.utf8)
        let right = Array(token.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            let first = index < left.count ? left[index] : 0
            let second = index < right.count ? right[index] : 0
            difference |= Int(first ^ second)
        }
        return difference == 0
    }
}

/// Why a token could not be written.
public enum SessionTokenError: LocalizedError {
    case notADirectory(URL)
    case cannotCreateDirectory(URL, String)
    case cannotWrite(URL, String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            "The run directory \(url.path) is not a directory."
        case .cannotCreateDirectory(let url, let reason):
            "The run directory \(url.path) could not be created: \(reason)"
        case .cannotWrite(let url, let reason):
            "The session token could not be written to \(url.path): \(reason)"
        }
    }
}
