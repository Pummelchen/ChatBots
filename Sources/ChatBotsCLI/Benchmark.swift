// ChatBotsCLI — the `--benchmark` mode
//
// Measures how two seats behave when they share the GPU: each answers the same prompt alone, then
// both answer simultaneously. Also the cheapest way to prove a given checkpoint loads and generates
// at all. Split out of `main.swift`, which held the entry point, the command line and every mode in
// one 1132-line file.

import ChatBotsCore
import Foundation

@MainActor
enum Benchmark {

    /// Returns the process exit code, and `0` means every seat loaded and every measurement
    /// produced tokens. The load result used to be logged and then discarded, so a corrupt or
    /// incompatible checkpoint printed `A loaded: false` and the caller still exited 0 — an
    /// install or CI script checking the status code accepted a broken checkpoint. A
    /// generation that failed is the same false success in the second place the doc claims to
    /// prove, so it fails the run too.
    static func run(context: RunContext) async -> Int32 {
        let options = context.options
        let engines = context.engines
        log("max tokens per turn: \(options.maxTokens.map(String.init) ?? "seat default")")
        let prompt = [
            PromptMessage(role: .system, content: "Answer in about 120 words. Be concrete."),
            PromptMessage(
                role: .user,
                content: "In about 120 words: why are bird eggs ovoid rather than spherical?"),
        ]

        /// The measured rate, or nil when the seat failed to generate. Nil rather than `0`,
        /// because "failed" and "measured zero tokens per second" are different facts and only
        /// one of them is a measurement.
        func measure(_ engine: MLXEngine, label: String) async -> Double? {
            log("  starting \(label)…")
            do {
                _ = try await engine.generate(
                    messages: prompt, tools: [], onToolCall: { _, _ in }, onEvent: { _ in })
                let stats = await engine.lastStats
                let rate = stats?.tokensPerSecond ?? 0
                log(
                    "  \(label): \(String(format: "%.1f", rate)) tok/s "
                        + "(\(stats?.generationTokens ?? 0) tok in "
                        + "\(String(format: "%.1f", stats?.seconds ?? 0))s)")
                return rate
            } catch {
                log("  \(label): FAILED — \(error.localizedDescription)")
                return nil
            }
        }

        // The two-seat comparison genuinely needs a second seat. A one-seat roster is a
        // supported configuration (`CHATBOTS_SEATS=1`), so this is a usage answer before any
        // model is loaded, rather than the "Fatal error: Index out of range" that `engines[1]`
        // produced.
        guard options.solo || engines.count > 1 else {
            log(
                "benchmark: the two-seat comparison needs a second seat — "
                    + "use --solo to measure one seat, or set CHATBOTS_SEATS=2")
            return 2
        }

        log("loading…")
        let loadedA = await loadSeat(engines[0], label: "A")
        log("  A loaded: \(loadedA)")
        guard loadedA else { return 1 }
        if options.solo {
            return await measure(engines[0], label: "A") == nil ? 1 : 0
        }

        let loadedB = await loadSeat(engines[1], label: "B")
        log("  B loaded: \(loadedB)")
        guard loadedB else { return 1 }

        log("alone, sequential:")
        let aloneA = await measure(engines[0], label: "A")
        let aloneB = await measure(engines[1], label: "B")

        log("simultaneous:")
        async let concurrentA = measure(engines[0], label: "A")
        async let concurrentB = measure(engines[1], label: "B")
        let (sharedA, sharedB) = await (concurrentA, concurrentB)

        func verdict(_ alone: Double?, _ shared: Double?) -> String {
            guard let alone, let shared, alone > 0, shared > 0 else { return "n/a" }
            return String(format: "%.0f%% of its solo rate", shared / alone * 100)
        }
        log("verdict:")
        log("  A: \(verdict(aloneA, sharedA))")
        log("  B: \(verdict(aloneB, sharedB))")

        guard aloneA != nil, aloneB != nil, sharedA != nil, sharedB != nil else { return 1 }
        return 0
    }
}
