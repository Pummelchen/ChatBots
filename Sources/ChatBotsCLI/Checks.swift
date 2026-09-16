// ChatBotsCLI — the checks that run before any conversation
//
// `--prepare-identity`, `--check-client`, `--check-transport` and `--check` each answer one
// question about this machine and exit, and none of them needs a conversation. Split out of
// `main.swift`, which held the entry point, the command line and every mode in one 1132-line file.

import ChatBotsCore
import Foundation

@MainActor
enum Checks {

    /// Generate the engine's certificate, if it is not there yet.
    ///
    /// Run by the installer so the first launch does not do it. Two reasons: the work happens
    /// during setup, where a pause is expected, rather than in the app where it looks like a hang,
    /// and the fingerprint is printed where someone installing can see it.
    static func prepareIdentity(in directory: URL) {
        do {
            let identity = try CertificateStore.loadOrCreate(in: directory)
            print("engine certificate: \(identity.fingerprintDisplay)")
            print("  stored in \(directory.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(
                Data("could not create the engine certificate: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// `--check-client`: connect to a running engine from a second process.
    ///
    /// A client-only mode, so the transport can be tested across two processes rather than one.
    /// An in-process check can pass while a real client cannot connect at all — which is exactly
    /// what happened here, and is the reason this exists.
    static func runClient(options: Options, runDirectory: URL) async {
        _ = try? CertificateStore.loadOrCreate(in: runDirectory)
        var configuration = WebTransportEngineClient.Configuration()
        configuration.port = options.transportPort
        let client = WebTransportEngineClient(configuration: configuration)
        var connected = false
        var last = "?"
        for attempt in 0..<8 {
            do {
                try await client.connect()
                connected = true
                break
            } catch {
                last = error.localizedDescription
                try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
            }
        }
        guard connected else {
            print("client: could NOT connect to 127.0.0.1:\(options.transportPort)")
            print("  \(last)")
            exit(3)
        }
        let snapshot = try? await client.state()
        print("client: connected cross-process")
        print("  topic: \(snapshot?.topic ?? "none")")
        print("  seats: \(snapshot?.seats.map(\.name).joined(separator: ", ") ?? "none")")
        await client.disconnect()
        exit(0)
    }

    /// `--check-transport`: start a real WebTransport server and drive it with a real client, so a
    /// broken channel is found here rather than in the app.
    static func runTransport(in directory: URL) async {
        let report = await TransportCheck.run(in: directory)
        print("WebTransport check")
        print(report.describe())
        if report.succeeded {
            print("\nThe transport works: requests, replies, refusals and events all arrived.")
            exit(0)
        }
        print("\nThe transport does NOT work.")
        exit(2)
    }

    /// `--check`: the self-test an installer runs. It proves the runtime, the Metal library and the
    /// checkpoint all work together on this machine, and it does so without needing to read or
    /// interpret a conversation.
    static func runModel(options: Options) async {
        let spec = AgentSpec.seat(index: 0, modelID: options.modelA)
        log("Checking seat A: \(spec.modelID)")
        let engine = MLXEngine(spec: spec)
        do {
            try await engine.load()
            let window = await engine.contextWindow
            log("  model loaded — context window \(window) tokens")
            let started = Date.now
            let reply = try await engine.generate(
                messages: [
                    .init(role: .system, content: "You are terse."),
                    .init(role: .user, content: "Reply with the single word: ready"),
                ],
                tools: [], onToolCall: { _, _ in }, onEvent: { _ in })
            let seconds = Date.now.timeIntervalSince(started)
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            log(String(format: "  generated %d characters in %.1fs", trimmed.count, seconds))
            if trimmed.isEmpty {
                FileHandle.standardError.write(Data("check failed: the model produced no output\n".utf8))
                exit(1)
            }
            log("Check passed — the app is ready to run")
            exit(0)
        } catch {
            FileHandle.standardError.write(
                Data("check failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
