// chatbots-probe — connect to a running engine's WebTransport endpoint and report what it says.
//
// This exists because the desktop app is a poor instrument for diagnosing the transport: its
// failures are a banner with one line in it, and reproducing one means launching a window,
// waiting for a model to load and reading a screenshot. This is the same client the app uses,
// started from a terminal, where a failure is a line of text and a repeat is a shell loop.
//
//     swift run chatbots-probe                    # one connect, print the state, close
//     swift run chatbots-probe --cycles 20        # twenty connects in sequence
//     swift run chatbots-probe --port 7790        # a different engine
//     swift run chatbots-probe --hold 10          # stay attached for ten seconds, printing
//                                                 # every push the engine sends
//
// The `--cycles` shape is the one that matters for the app: the supervisor probes before the
// app connects, so a connection that only works the first time is the bug this reports.

import ChatBotsCore
import Foundation

struct Options {
    var port: UInt16 = 7_790
    var cycles = 1
    var holdSeconds = 0
    var quiet = false
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    /// The value that follows a flag, consumed so the loop does not read it as one.
    func next() -> String? {
        guard !arguments.isEmpty else { return nil }
        return arguments.removeFirst()
    }
    while let flag = arguments.first {
        arguments.removeFirst()
        switch flag {
        case "--port":
            // Validated rather than swallowed. `UInt16(String)` returns nil for a non-numeric or
            // out-of-range value, so `--port abc` or `--port 70000` used to fall through to 7790
            // and the probe reported on an engine the caller had not named — the silent-fallback
            // class removed from the CLI's `--transport-port`. Zero is refused too: it
            // announces a destination nothing can be listening on.
            let portRaw = next() ?? ""
            guard let port = UInt16(portRaw), port != 0 else {
                FileHandle.standardError.write(
                    Data(
                        "invalid port: \(portRaw.isEmpty ? "(nothing)" : portRaw) — expected 1–65535\n"
                            .utf8))
                exit(2)
            }
            options.port = port
        case "--cycles":
            // `Int(value)` with no positivity check meant `--cycles 0` ran nothing and left
            // `allSucceeded` true, so the probe printed "all cycles succeeded" over an
            // untested transport, and a negative value formed `0..<(-n)`, whose `Range`
            // has a precondition, killing the probe. This is the check the supervisor's
            // pre-connect probe runs, so a green light has to have probed something.
            let cyclesRaw = next() ?? ""
            guard let count = Int(cyclesRaw), count >= 1 else {
                FileHandle.standardError.write(
                    Data(
                        "invalid cycle count: \(cyclesRaw.isEmpty ? "(nothing)" : cyclesRaw) — expected 1 or more\n"
                            .utf8))
                exit(2)
            }
            options.cycles = count
        case "--hold":
            // A non-numeric or negative value used to be accepted and then ignored by the
            // `holdSeconds > 0` gate, so `--hold abc` and `--hold -5` both silently did not hold
            // while the probe went on to report success. A hold of nothing is not a hold,
            // so it is refused rather than quietly reinterpreted.
            let holdRaw = next() ?? ""
            guard let seconds = Int(holdRaw), seconds >= 1 else {
                FileHandle.standardError.write(
                    Data(
                        "invalid hold: \(holdRaw.isEmpty ? "(nothing)" : holdRaw) — expected 1 or more seconds\n"
                            .utf8))
                exit(2)
            }
            options.holdSeconds = seconds
        case "--quiet":
            options.quiet = true
        case "--help", "-h":
            print(
                """
                chatbots-probe — connect to a running engine over WebTransport

                  --port <n>     the engine's transport port (default 7790)
                  --cycles <n>   connect and close this many times (default 1)
                  --hold <n>     stay attached for this many seconds, printing every push
                  --quiet        print only failures
                """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown option: \(flag)\n".utf8))
            exit(2)
        }
    }
    return options
}

@MainActor
func probe(port: UInt16, cycles: Int, holdSeconds: Int, quiet: Bool) async -> Bool {
    // Defence in depth behind the parser: "no cycles ran" is not "all cycles succeeded", and
    // this must not depend on every caller having validated the count first.
    guard cycles >= 1 else {
        print("cycles must be at least 1 — a probe that runs no cycles proves nothing")
        return false
    }
    var allSucceeded = true
    for cycle in 0..<cycles {
        var configuration = WebTransportEngineClient.Configuration()
        configuration.port = port
        configuration.timeoutMilliseconds = 6_000
        let client = WebTransportEngineClient(configuration: configuration)

        do {
            try await client.connect()
            let snapshot = try await client.state()
            guard let snapshot else {
                print("cycle \(cycle): connected but the engine returned no state")
                allSucceeded = false
                await client.disconnect()
                continue
            }
            if !quiet {
                print(
                    "cycle \(cycle): ok — topic \"\(snapshot.topic)\", "
                        + "\(snapshot.seats.count) seats, \(snapshot.messages.count) messages, "
                        + "greeting \(client.greeting == nil ? "absent" : "present")")
            }

            if holdSeconds > 0 {
                // Attached and listening: anything the engine pushes is printed as it arrives.
                // A connection that is accepted but never subscribed shows nothing here, which
                // is the failure the app displays as an empty thread.
                print("holding for \(holdSeconds)s — pushes appear below")
                if let events = client.events {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(holdSeconds))
                    let reader = Task {
                        for await event in events {
                            switch event {
                            case .state(let pushed):
                                print("  push: state — topic \"\(pushed.topic)\", \(pushed.messages.count) messages")
                            case .output(let delta):
                                print("  push: output \(delta.agentID) \(delta.kind) \(delta.text.count) chars")
                            }
                        }
                    }
                    while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
                    reader.cancel()
                } else {
                    print("  no event stream: the client did not subscribe")
                }
            }
        } catch {
            print("cycle \(cycle): FAILED — \(error.localizedDescription)")
            allSucceeded = false
        }
        await client.disconnect()
    }
    return allSucceeded
}

let options = parseOptions()
let succeeded = await probe(
    port: options.port, cycles: options.cycles,
    holdSeconds: options.holdSeconds, quiet: options.quiet)
print(succeeded ? "all cycles succeeded" : "at least one cycle failed")
exit(succeeded ? 0 : 1)
