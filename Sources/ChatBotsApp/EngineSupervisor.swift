// ChatBotsApp — starting and owning the conversation engine
//
// The app no longer contains an engine. Something has to run one, and on a Mac that the user
// double-clicks, that something is this: it finds the engine's executable, starts it as a
// separate process, waits until it answers, and stops it on quit.
//
// **Why a separate process rather than hosting the engine in the app.**
//
// Hosting it in-process would be less code and would still talk over WebTransport, so the app
// would be no less decoupled in the way that matters for the code. It is rejected for two
// reasons that are about behaviour rather than tidiness:
//
//   · A model crash is an engine crash. MLX runs on the GPU and its failures are the kind that
//     take a process down. In-process, that closes the window and loses the conversation. As a
//     child process, the app survives it, says what happened, and can restart the engine.
//   · The engine can outlive an app restart. Quitting and reopening the interface does not
//     reload several gigabytes of weights.
//
// The cost is that a child process has to be found, started, waited for and reaped, which is
// what this file is.

import ChatBotsCore
import Combine
import Foundation

@MainActor
public final class EngineSupervisor: ObservableObject {

    public enum State: Equatable, Sendable {
        case idle
        /// Looking for an engine, or starting one.
        case starting
        /// An engine is answering. `owned` means this app started it and will stop it.
        case running(owned: Bool)
        case failed(String)

        public var label: String {
            switch self {
            case .idle: "Not connected"
            case .starting: "Starting the engine…"
            case .running(let owned): owned ? "Engine running" : "Using a running engine"
            case .failed(let reason): reason
            }
        }
    }

    public struct Configuration: Sendable {
        /// Where the engine serves WebTransport. Loopback only.
        public var port: UInt16 = 7790
        /// How long to wait for a freshly started engine to answer.
        public var startupTimeout: Duration = .seconds(90)

        public init() {}
    }

    @Published public private(set) var state: State = .idle
    public let configuration: Configuration

    private var process: Process?
    private var logHandle: FileHandle?
    private let logURL: URL
    /// Where this run's session token lives.
    ///
    /// The same answer the app uses for the engine log, and the directory the engine is told to
    /// use with `--run-directory`: the file this app reads is the file that engine wrote, rather
    /// than two independent path rules that happen to agree in the common case.
    private let runDirectory: URL

    /// - Parameter runDirectory: the directory to read the session token from. The default is the
    ///   one this app's engine writes to; a test passes its own so the decision can be exercised
    ///   against a directory it owns.
    public init(
        configuration: Configuration = .init(), logURL: URL, runDirectory: URL? = nil
    ) {
        self.configuration = configuration
        self.logURL = logURL
        self.runDirectory = runDirectory ?? RunDirectory.current
    }

    /// True when this app started the engine and is responsible for stopping it.
    public var ownsEngine: Bool {
        if case .running(let owned) = state { return owned }
        return false
    }

    /// True when the supervisor reached an engine that proved it is this run's engine.
    ///
    /// `.running` is only ever assigned after `.identify` echoed the token this run wrote, so this
    /// is the gate for anything that carries credentials: the app must never hand a key to a
    /// process that cannot prove who it is. An adopted engine is verified; an engine this app owns
    /// is verified too.
    public var hasVerifiedEngine: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: - Starting

    /// Ensure an engine is answering, starting one if none is.
    ///
    /// Adopting an engine that is already running is deliberate: a developer with `start.sh`
    /// going, or a second copy of the app, should share one conversation rather than silently
    /// starting a rival on a different port that the website cannot see.
    public func start() async {
        // `.starting` as well as `.running`: the wait below is cancellation-blind, so a second
        // call while the first is still waiting would launch a second child, and `launch` assigns
        // `self.process` — the first child would become unreachable and would be left holding the
        // GPU and the transport port. This is the failure mode the comment on `launch` records.
        switch state {
        case .running, .starting: return
        default: break
        }

        state = .starting

        // Anything already listening is adopted rather than duplicated — but only if it can prove
        // it is this run's engine. A process on the port that cannot echo the token this run wrote
        // is not adopted, and the app never sends it credentials.
        if await adoptExistingEngine() { return }

        guard let executable = locateEngineExecutable() else {
            state = .failed(
                """
                The engine could not be found. ChatBots.app should include it; if this copy \
                was assembled by hand, run tools/make-app.sh to rebuild it.
                """)
            return
        }

        do {
            try launch(executable: executable)
        } catch {
            state = .failed("The engine could not be started: \(error.localizedDescription)")
            return
        }

        await waitForLaunchedEngine()
    }

    /// Adopt an engine already answering on the port, when it can prove it is this run's.
    ///
    /// `true` means a terminal decision has been taken — adopted, or refused — and the caller must
    /// not start a second engine. `false` means there was nothing there, so starting one is right.
    private func adoptExistingEngine() async -> Bool {
        switch await probe() {
        case .verified:
            state = .running(owned: false)
            return true
        case .unverified:
            state = .failed(Self.unverifiedEngineMessage(port: configuration.port))
            return true
        case .silent:
            return false
        }
    }

    /// Wait for the engine this app started to answer and prove itself.
    ///
    /// A cold start loads nothing yet — the weights are loaded when a conversation begins — so
    /// this is usually quick, but a first run after an install can take a while and giving up
    /// early would look like a failure. Every exit from here leaves `state` at its terminal value.
    private func waitForLaunchedEngine() async {
        let deadline = ContinuousClock.now.advanced(by: configuration.startupTimeout)
        while ContinuousClock.now < deadline {
            // A cancelled window must stop the loop, not become a hot spin: `try?` discarded
            // the CancellationError, `Task.sleep` then returned immediately, and the 400 ms
            // pacing was gone — a continuous probe for the whole startup budget that finished
            // by overwriting the `.idle` that shutdown() had set.
            if Task.isCancelled { return }
            switch await probeEngine() {
            case .verified:
                state = .running(owned: true)
                return
            case .unverified:
                // Something took the port between the probe above and this launch. Stop the child
                // rather than leave it fighting for the port, and keep the reason for the user.
                await terminateChild(timeout: .seconds(2))
                state = .failed(Self.unverifiedEngineMessage(port: configuration.port))
                return
            case .silent:
                break
            }
            if let process, !process.isRunning {
                // It exited. The log is the only place that says why.
                state = .failed(
                    """
                    The engine stopped while starting. \
                    \(tailOfLog() ?? "See \(logURL.path)")
                    """)
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
        }

        // Stop the child, then report the failure — in that order.
        //
        // This used to set `.failed` and then call `stop()`, whose last act was `state = .idle`,
        // so the reason the app exists to show was overwritten before `ChatBotsApp` could read
        // it and no banner ever appeared. The teardown here does not touch `state`,
        // and the failure is assigned after it, so nothing can overwrite it.
        //
        // The child is still running — it is the answering that timed out, not the process — so
        // it is stopped rather than left behind. The wait is short: the startup budget has
        // already been spent, and a child that has not answered in 90 seconds does not deserve
        // another five before the moderator is told.
        await terminateChild(timeout: .seconds(2))
        state = .failed("The engine did not answer within \(configuration.startupTimeout).")
    }

    /// Terminate the child and return once this app is done with it, without touching `state`.
    ///
    /// Shared by quitting, which then reports `.idle`, and by a startup timeout, which must keep
    /// the failure it is about to report. SIGTERM first, then SIGKILL after `timeout`: a child
    /// that ignores or outlives the signal would otherwise keep holding the GPU and the
    /// WebTransport port after the app is gone. The process reference is taken before the first
    /// suspension point, so two callers cannot both run the wait and the escalation.
    private func terminateChild(timeout: Duration) async {
        guard let process else { return }
        self.process = nil
        if process.isRunning { process.terminate() }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            // It did not take the hint. SIGKILL, so nothing is left holding the GPU and the port.
            kill(process.processIdentifier, SIGKILL)
        }
        try? logHandle?.close()
        logHandle = nil
    }

    /// Wait for the process to exit, and kill it if it will not, so quitting does not leave an
    /// orphan.
    ///
    /// This is the teardown the termination path uses. `terminateChild` does the work; this adds
    /// the state a stopped engine reports.
    public func shutdown(timeout: Duration = .seconds(5)) async {
        await terminateChild(timeout: timeout)
        state = .idle
    }

    // MARK: - The executable

    /// Find the engine binary.
    ///
    /// Checked in order of how likely each is to be the right one, and the app bundle comes
    /// first: a shipped app must not pick up a stale build from a developer's checkout.
    private func locateEngineExecutable() -> URL? {
        let manager = FileManager.default
        var candidates: [URL] = []

        // Inside the app bundle, where make-app.sh puts it.
        if let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appending(path: "chatbots-cli")
        {
            candidates.append(bundled)
        }

        // Beside the app, for a build tree that has been assembled but not packaged.
        if let executable = Bundle.main.executableURL {
            var directory = executable.deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(directory.appending(path: ".build/release/chatbots-cli"))
                directory = directory.deletingLastPathComponent()
            }
        }

        // The fixed-path fallback was removed. `/usr/local/bin` is writable by an administrator
        // and by anything running as one, and the app execs whatever it finds there with the
        // user's whole environment — including any exported API keys — and then sends it every
        // seat key over the wire. The bundled helper is the supported path; a hand-assembled
        // copy gets the "could not be found" message, which names `tools/make-app.sh`.
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }

    private func launch(executable: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--serve",
            // WebTransport only. The app does not use the engine's HTTP server, and asking for
            // it was actively harmful: running both transports in one process is what stopped
            // the app ever receiving state. The website is served separately, by `tools/start.sh`
            // and Caddy, so nothing needs this child to open an HTTP port.
            "--transport", "webtransport",
            "--transport-port", String(configuration.port),
            // Stated rather than inferred. The engine writes its session token here, and this app
            // reads it from here; two independent path rules that agree in the common case would
            // make the app refuse to adopt its own engine on the day they did not.
            "--run-directory", runDirectory.path,
        ]
        // Run it from the project directory when there is one, because that is where `.run/`
        // and the certificate live, and a second identity would be a second fingerprint.
        //
        // Otherwise from the runtime directory, **not** from beside the executable: that is
        // inside the bundle, and anything the engine writes relative to its working directory
        // would land there and invalidate the app's signature. `--run-directory` above is the one
        // answer either way; this only decides where the child's other relative reads land.
        process.currentDirectoryURL = Self.projectDirectory() ?? runDirectory

        // The engine's output goes to a file rather than a pipe. A pipe would block the child
        // once its buffer filled, and an engine that blocks on logging is an engine that stops
        // answering — a failure that looks exactly like a hang.
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        process.standardOutput = handle
        process.standardError = handle
        logHandle = handle

        do {
            try process.run()
        } catch {
            // The handle was opened and assigned before the launch, so a failed `run()` used to
            // leave it open: `terminateChild` returns early on a nil `process`, and the close at
            // its end never ran. One descriptor leaked per failed launch.
            try? handle.close()
            logHandle = nil
            throw error
        }
        self.process = process
    }

    /// The project root, when the app is running from a checkout.
    ///
    /// Static because `init` resolves the run directory before an instance exists, and the two
    /// must agree about which project this app belongs to.
    private static func projectDirectory() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = directory.appending(path: "Package.swift")
            if FileManager.default.fileExists(atPath: marker.path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Health and identity

    /// What one attempt to reach an engine on the transport port found.
    private enum Probe: Equatable {
        /// Nothing answered: no listener, or a listener that could not complete the request.
        case silent
        /// An engine answered and echoed the token this run wrote.
        case verified
        /// Something answered, but could not prove it is this run's engine.
        case unverified
    }

    /// A few attempts at the port before deciding nothing is there.
    ///
    /// Retried for the reason the single-attempt version was: the first attempt after a launch pays
    /// for the QUIC handshake, the certificate check and a cold TLS stack, and a single two-second
    /// attempt occasionally lost that race. The consequence was not a slow start: it was this app
    /// starting a *second* engine on the same ports, which SO_REUSEADDR allowed, leaving the browser
    /// and the app talking to different processes. Three seconds of patience is cheaper than that.
    /// A verified or unverified answer is final; only silence is retried.
    private func probe(attempts: Int = 3) async -> Probe {
        for attempt in 0..<attempts {
            if Task.isCancelled { return .silent }
            let result = await probeEngine()
            if result != .silent { return result }
            if attempt < attempts - 1 {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return .silent
                }
            }
        }
        return .silent
    }

    /// Ask the engine on the port to prove itself, once.
    ///
    /// Asked over WebTransport rather than HTTP, because that is the channel the app will use: an
    /// engine whose HTTP side is up but whose transport is not would otherwise be adopted and then
    /// fail to connect. `.identify` is also the liveness check — a reply is the proof something is
    /// there, and its token is the proof of *what* — so a peer that takes the port without echoing
    /// this run's token is `.unverified` rather than a healthy engine.
    private func probeEngine() async -> Probe {
        var configuration = WebTransportEngineClient.Configuration()
        configuration.port = self.configuration.port
        configuration.timeoutMilliseconds = 4_000
        let client = WebTransportEngineClient(configuration: configuration)
        // Every path closes the connection, including the failure one.
        //
        // This looked harmless — a client that fails to connect holds nothing — and it was not:
        // a probe that connected and then failed to fetch state used to return here leaving a
        // live QUIC session behind, and a startup loop that retried left one per attempt. The
        // cost turned up later as "Network.NWError error 12 - Cannot allocate memory" on the
        // *next* connection, so the app's own real connection failed because of the probes that
        // went before it.
        do {
            try await client.connect()
        } catch {
            await client.disconnect()
            return .silent
        }
        let echoed: String?
        do {
            echoed = try await client.identify()
        } catch {
            await client.disconnect()
            return .silent
        }
        // Awaited rather than handed to a detached task: the sockets must be back before the
        // caller tries again, which is the whole point of closing them here.
        await client.disconnect()
        return identityMatches(echoed) ? .verified : .unverified
    }

    /// Whether an engine that echoed `token` is the engine this app is attached to.
    ///
    /// Internal rather than private so a test can drive the decision without a socket: an engine
    /// that answers with anything but this run's token — or with no token at all — is never
    /// adopted.
    func identityMatches(_ token: String?) -> Bool {
        guard let token else { return false }
        return SessionToken.matches(token, in: runDirectory)
    }

    /// The failure shown when the port is answering, but not as this run's engine.
    ///
    /// A sentence a user can act on: it names the port, says the app will not hand over
    /// credentials, and says what to do. A same-user process that binds the port before the engine
    /// starts is exactly the process this refuses to talk to.
    static func unverifiedEngineMessage(port: UInt16) -> String {
        """
        A process is answering on port \(port) that could not prove it is this user's engine. \
        ChatBots will not send it your API keys. Stop that process, or quit ChatBots and start it \
        again when the port is free.
        """
    }

    /// The end of the engine log, for saying what went wrong.
    private func tailOfLog(maximumCharacters: Int = 400) -> String? {
        // Only the end of the file is read. The whole file used to be decoded on the main actor,
        // and nothing rotates `app-engine.log` — the child is given it append-only — so with
        // `CHATBOTS_TRACE_API` set it also carries conversation content and grows for the life of
        // the install. A cut can land inside a multi-byte character, so the bytes are decoded
        // lossily rather than with a strict `String(contentsOf:)`.
        let maximumBytes = 4 * maximumCharacters
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
            let data = try? handle.readToEnd(), !data.isEmpty,
            let text = UTF8Text.decodeTruncated(data), !text.isEmpty
        else { return nil }
        let tail = text.suffix(maximumCharacters)
        let cleaned =
            tail
            .split(separator: "\n")
            .suffix(4)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
