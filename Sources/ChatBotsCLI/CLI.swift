// ChatBotsCLI — which mode the flags chose, and the order they are considered in
//
// The entry point reads the command line and resolves the run directory, and everything after that
// starts here: the checks that exit, the listings that exit, and the modes that take over. Split out
// of `main.swift`, which held the entry point, the command line and every mode in one 1132-line file.

import ChatBotsCore
import Foundation

@MainActor
enum CLI {

    /// The order of these checks is the order the flags have always been considered in.
    ///
    /// Everything before `RunContext` needs no model; the context builds the engines the remaining
    /// modes share. Each earlier mode exits or returns before the next is reached.
    static func run(options: Options, modelsRoot: URL, runDirectory: URL) async {
        // A flag that would otherwise be accepted and then ignored: `--seed` fills the server's
        // engine with a sample conversation, and outside `--serve` there is no server engine to
        // fill, so the run used to proceed silently as a real model conversation instead.
        if options.seed, !options.serve {
            FileHandle.standardError.write(
                Data(
                    "--seed only applies with --serve: it seeds a sample conversation into the server's engine\n"
                        .utf8))
            exit(2)
        }

        // Generate the engine's certificate, if it is not there yet.
        if options.prepareIdentity {
            Checks.prepareIdentity(in: runDirectory)
        }

        // The transport check runs before anything else, and needs no model: it starts a real
        // WebTransport server and drives it with a real client, so a broken channel is found here
        // rather than in the app.
        if options.checkClient {
            await Checks.runClient(options: options, runDirectory: runDirectory)
        }
        if options.checkTransport {
            await Checks.runTransport(in: runDirectory)
        }
        if options.check {
            await Checks.runModel(options: options)
        }
        // Printing the export format, with no model involved: handy for checking what a saved
        // conversation looks like, and for support.
        if options.exportSample {
            ExportSample.run(options: options)
        }

        let context = RunContext(options: options, modelsRoot: modelsRoot, runDirectory: runDirectory)

        if options.benchmark {
            exit(await Benchmark.run(context: context))
        }
        if options.sessionProbe {
            await Probes.runSession(context: context)
        }
        if options.memoryProbe {
            await Probes.runMemory(context: context)
        }
        // Listing the persona libraries, so the pickers are discoverable from the terminal as well
        // as from the interface.
        if options.listCharacters {
            Listings.printCharacters()
            exit(0)
        }
        if options.listRoles {
            Listings.printRoles()
            exit(0)
        }
        // The same engine the printed run uses, behind HTTP and WebTransport instead of stdout.
        if options.serve {
            await ServeCommand.run(context: context)
        }

        await HeadlessRun.run(context: context)
    }
}
