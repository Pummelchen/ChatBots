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

import Combine
import Foundation
import ChatBotsCore

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

    public init(configuration: Configuration = .init(), logURL: URL) {
        self.configuration = configuration
        self.logURL = logURL
    }

    /// True when this app started the engine and is responsible for stopping it.
    public var ownsEngine: Bool {
        if case .running(let owned) = state { return owned }
        return false
    }

    // MARK: - Starting

    /// Ensure an engine is answering, starting one if none is.
    ///
    /// Adopting an engine that is already running is deliberate: a developer with `start.sh`
    /// going, or a second copy of the app, should share one conversation rather than silently
    /// starting a rival on a different port that the website cannot see.
    public func start() async {
        if case .running = state { return }

        state = .starting

        // Anything already listening is adopted rather than duplicated.
        if await isEngineAnswering() {
            state = .running(owned: false)
            return
        }

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

        // Wait for it to answer. A cold start loads nothing yet — the weights are loaded when
        // a conversation begins — so this is usually quick, but a first run after an install
        // can take a while and giving up early would look like a failure.
        let deadline = ContinuousClock.now.advanced(by: configuration.startupTimeout)
        while ContinuousClock.now < deadline {
            if await isEngineAnswering() {
                state = .running(owned: true)
                return
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
            try? await Task.sleep(for: .milliseconds(400))
        }

        // Stop the child, then report the failure — in that order.
        //
        // This used to set `.failed` and then call `stop()`, whose last act was `state = .idle`,
        // so the reason the app exists to show was overwritten before `ChatBotsApp` could read
        // it and no banner ever appeared (audit A50). The teardown here does not touch `state`,
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

        candidates.append(URL(fileURLWithPath: "/usr/local/bin/chatbots-cli"))

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
        ]
        // Run it from the project directory when there is one, because that is where `.run/`
        // and the certificate live, and a second identity would be a second fingerprint.
        //
        // Otherwise from the runtime directory, **not** from beside the executable: that is
        // inside the bundle, and anything the engine writes relative to its working directory
        // would land there and invalidate the app's signature. This is the same folder the engine
        // resolves for itself through `RunDirectory`, so the two cannot disagree.
        process.currentDirectoryURL = projectDirectory() ?? RunDirectory.current

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

        try process.run()
        self.process = process
    }

    /// The project root, when the app is running from a checkout.
    private func projectDirectory() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = directory.appending(path: "Package.swift")
            if FileManager.default.fileExists(atPath: marker.path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Health

    /// Whether an engine is answering on the WebTransport port.
    ///
    /// Asked over WebTransport rather than HTTP, because that is the channel the app will use:
    /// an engine whose HTTP side is up but whose transport is not would otherwise be adopted
    /// and then fail to connect.
    /// Retried, because the first attempt after a launch pays for the QUIC handshake, the
    /// certificate check and a cold TLS stack, and a single two-second attempt occasionally lost
    /// that race. The consequence was not a retry: it was this app starting a *second* engine on
    /// the same ports, which SO_REUSEADDR allowed, leaving the browser and the app talking to
    /// different processes. Three seconds of patience is cheaper than that.
    private func isEngineAnswering(attempts: Int = 3) async -> Bool {
        for attempt in 0..<attempts {
            if await probeEngine() { return true }
            if attempt < attempts - 1 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        return false
    }

    private func probeEngine() async -> Bool {
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
            return false
        }
        let answered: Bool
        do {
            answered = try await client.state() != nil
        } catch {
            answered = false
        }
        // Awaited rather than handed to a detached task: the sockets must be back before the
        // caller tries again, which is the whole point of closing them here.
        await client.disconnect()
        return answered
    }

    /// The end of the engine log, for saying what went wrong.
    private func tailOfLog(maximumCharacters: Int = 400) -> String? {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8), !text.isEmpty else {
            return nil
        }
        let tail = text.suffix(maximumCharacters)
        let cleaned = tail
            .split(separator: "\n")
            .suffix(4)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
