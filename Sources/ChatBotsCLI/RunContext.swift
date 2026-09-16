// ChatBotsCLI — the seats every mode shares, and the one loader
//
// The conversation run, the benchmark, the probes and the server all need the same engines built
// from the same flags, so they are built once here rather than by each mode. Split out of
// `main.swift`, which held the entry point, the command line and every mode in one 1132-line file.

import ChatBotsCore
import Foundation

/// One engine per seat, built once and handed to whichever mode the flags chose.
///
/// The CLI wires its own engines so it can route events straight to stdout, and so the same seats
/// and the same tool registry serve a printed run and both front ends. The roster decides how many
/// seats, so `CHATBOTS_SEATS=4` gives four — the same rule the app uses.
@MainActor
struct RunContext {
    let options: Options
    let modelsRoot: URL
    let runDirectory: URL
    let specs: [AgentSpec]
    let engines: [MLXEngine]
    /// Kept because `--serve` builds a replacement engine for a seat a front end switches, and that
    /// engine has to carry the same tools as the seats built here.
    let registry: ToolRegistry

    init(options: Options, modelsRoot: URL, runDirectory: URL) {
        self.options = options
        self.modelsRoot = modelsRoot
        self.runDirectory = runDirectory

        // The first two seats keep the CLI's own flags; any beyond that take their defaults, so the
        // flags did not have to grow a third and fourth variant to make a four-seat run possible.
        var specs: [AgentSpec] = {
            let count = AgentSpec.SeatRoster.count()
            var built = [options.specA, options.specB]
            if count > 2 {
                built.append(contentsOf: AgentSpec.makeSeats(count: count).dropFirst(2))
            }
            built = Array(built.prefix(count))
            // Every seat gets this run's settings, not just the two the command line names directly.
            built = options.applyToAllSeats(built)
            // Named like the app: one female and one male, at random. The CLI built its own first two
            // seats, so it has to ask for this rather than inheriting it.
            var generator = SystemRandomNumberGenerator()
            AgentSpec.assignNames(to: &built, using: &generator)
            return built
        }()
        // The mode decides which library a persona comes from, so it is applied to every seat
        // before anything reads one. A seat holding an identifier from the other library resolves
        // to that mode's default rather than to nothing.
        for index in specs.indices {
            specs[index].mode = options.mode
            if !options.mode.owns(personaID: specs[index].personaID) {
                specs[index].personaID = options.mode.defaultPersonaID(forSeat: index)
            }
        }
        self.specs = specs

        // One engine per seat. The CLI wires its own so it can route events straight to stdout.
        let registry = WebToolbox.makeRegistry()
        self.registry = registry
        self.engines = specs.map { spec in
            MLXEngine(spec: spec, toolRegistry: registry) { state in
                if case .loading(let progress) = state, progress > 0, progress < 1 {
                    let percent = Int(progress * 100)
                    if percent % 25 == 0 { log("  \(spec.id): downloading \(percent)%") }
                }
            }
        }
    }
}

func loadSeat(_ engine: MLXEngine, label: String) async -> Bool {
    do {
        try await engine.load()
        return true
    } catch {
        log("  \(label) failed to load: \(error.localizedDescription)")
        return false
    }
}
