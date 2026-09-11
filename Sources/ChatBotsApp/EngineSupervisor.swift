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
        /// The engine's HTTP port, which Caddy and the website use.
        public var httpPort: UInt16 = 7789
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

        // Answering on the HTTP port but not on the transport: an engine is running that this
        // app cannot talk to. Starting a second one used to "work" — SO_REUSEADDR let both
        // bind the same ports — and the two then split incoming connections, so the browser and
        // the app showed different conversations. Saying so is the honest answer.
        if HTTPServer.isSomethingListening(on: configuration.httpPort) {
            state = .failed(
                """
                An engine is already running on port \(configuration.httpPort), but it is not \
                answering over WebTransport, which is how this app talks to it. Stop the other \
                engine and start again, or point the app at a free port.
                """)
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

        state = .failed("The engine did not answer within \(configuration.startupTimeout).")
        stop()
    }

    /// Stop the engine, if this app started it.
    ///
    /// An adopted engine is left alone. Terminating a process this app did not start would be
    /// taking away something the user is using.
    public func stop() {
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        process.terminate()
        self.process = nil
        try? logHandle?.close()
        logHandle = nil
        state = .idle
    }

    /// Wait briefly for the process to exit, so quitting does not leave an orphan.
    public func shutdown(timeout: Duration = .seconds(5)) async {
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            // It did not take the hint. SIGKILL, so quitting the app does not leave a process
            // holding the GPU and the port.
            kill(process.processIdentifier, SIGKILL)
        }
        self.process = nil
        try? logHandle?.close()
        logHandle = nil
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
            // Both channels: the app uses WebTransport, and the website needs HTTP.
            "--transport", "both",
            "--transport-port", String(configuration.port),
            "--port", String(configuration.httpPort),
        ]
        // Run it from the project directory when there is one, because that is where `.run/`
        // and the certificate live, and a second identity would be a second fingerprint.
        process.currentDirectoryURL = projectDirectory() ?? executable.deletingLastPathComponent()

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
        do {
            try await client.connect()
            let snapshot = try await client.state()
            await client.disconnect()
            return snapshot != nil
        } catch {
            return false
        }
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
