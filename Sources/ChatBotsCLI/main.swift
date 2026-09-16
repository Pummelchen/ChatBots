// chatbots-cli — drive the two-seat conversation without the GUI
//
// Used both as a smoke test for the real MLX engines and as a way to run the
// conversation from a terminal. It consumes exactly the same core types the app does.
//
//   chatbots-cli --topic "…" --turns 4                  converse
//   chatbots-cli --benchmark                            measure both seats' throughput
//   chatbots-cli --benchmark --solo                     measure one seat, then exit
//
// This file is only the entry point: it prepares the model store, reads the command line and
// resolves where the run keeps its state, then hands both to `CLI`. The flags and `--help` text are
// in `CommandLine.swift`, each mode is in a sibling file, and the engines they share are built by
// `RunContext`. It was one 1132-line file.

import ChatBotsCore
import Foundation

// Model storage lives in the project's `models/` folder; set before any engine loads.
let modelsRoot = ModelStore.prepare()
let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

// The one answer to "where does this run keep its state", decided once.
//
// Every mode below — preparing the identity, checking the transport, serving it — has to agree,
// and so does the engine process the serve path starts, which asks the same question again on its
// own. `--run-directory` is how that answer is given; without it the answer is the same one
// `RunDirectory` has always produced for this process.
let runDirectory = RunDirectory.resolve(
    override: options.runDirectory, projectRoot: ModelStore.projectRoot())

await CLI.run(options: options, modelsRoot: modelsRoot, runDirectory: runDirectory)
