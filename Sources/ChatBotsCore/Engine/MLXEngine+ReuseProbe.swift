// ChatBotsCore — the session-reuse diagnostic
//
// Split out of `MLXEngine.swift`, which held the engine, its loading path and this one-off probe in one
// file. The probe answers a structural question — whether one `ChatSession` reuses its KV cache across
// calls, and therefore whether keeping a session alive per seat would save prefill — and it is the only
// code that drives a session directly rather than through `runTurn`. The code did not change.

import Foundation
import MLXLMCommon

extension MLXEngine {

    /// One step of the session-reuse probe.
    public struct ReuseProbeStep: Sendable {
        public var prefilled: Int
        public var prefillSeconds: Double
    }

    /// Diagnostic: does one `ChatSession` reuse its KV cache across calls?
    ///
    /// This decides whether a larger restructure — keeping a session alive per seat and
    /// sending only new turns — would actually save prefill, or whether MLX re-prefills
    /// regardless. It reports what the session itself says it reused.
    public func sessionReuseProbe() async throws -> [ReuseProbeStep] {
        try await load()
        guard let container else { throw ChatBotsError.engineNotLoaded }
        let thinking = currentThinking
        let parameters = GenerateParameters(maxTokens: 24, temperature: 0, topP: 1.0, seed: 1)
        let context = thinking.templateContext

        // Through the gate, like every other Metal-touching call. This probe drives
        // `container.perform` directly, and `MLXGate` is the process-wide serialisation that keeps
        // two evaluations from overlapping — which aborts inside MLX with `EXC_BAD_ACCESS`.
        await MLXGate.shared.acquire()
        let results: [ReuseProbeStep]
        do {
            results = try await container.perform { (modelContext: ModelContext) async throws -> [ReuseProbeStep] in
                let session = ChatSession(
                    modelContext, generateParameters: parameters, additionalContext: context)
                var steps: [ReuseProbeStep] = []
                for index in 1...3 {
                    // A long first prompt and short follow-ups: reuse shows up as the
                    // follow-ups prefilling only their own tokens, no reuse as prefilling
                    // the whole thing again.
                    // Deliberately long, so that reuse is unmistakable in the numbers.
                    let notes = String(repeating: "egg shell ovoid pressure membrane. ", count: 400)
                    let prompt =
                        index == 1
                        ? "Notes: \(notes)\n\nOne short sentence: what shape is an egg?"
                        : "One sentence: what does that imply?"
                    var info: GenerateCompletionInfo?
                    for try await event in session.streamDetails(to: prompt) {
                        if case .info(let value) = event { info = value }
                    }
                    await session.clear()
                    steps.append(
                        ReuseProbeStep(
                            prefilled: info?.promptTokenCount ?? 0,
                            prefillSeconds: info?.promptTime ?? 0))
                }
                return steps
            }
            await MLXGate.shared.release()
        } catch {
            await MLXGate.shared.release()
            throw error
        }
        return results
    }
}
