// ChatBotsCLI — the `--session-probe` and `--memory-probe` modes
//
// Both answer a question about the engines rather than holding a conversation: what a retained
// session saves, and what the GPU memory does across loading and turns. Split out of `main.swift`,
// which held the entry point, the command line and every mode in one 1132-line file.

import ChatBotsCore
import Foundation
import MLX

@MainActor
enum Probes {

    /// Measures what keeping one conversation alive across turns would save: three prompts
    /// that share a growing prefix, through one engine, with prefill reported each time.
    static func runSession(context: RunContext) async {
        let engine = context.engines[0]
        // The load has to be believed: this probe exists to measure what retaining a session
        // saves, and a process that could not load has measured nothing. This was
        // `try? await engine.load()`, whose failure was discarded, and the probe exited 0
        // having run against no model at all.
        guard await loadSeat(engine, label: "A") else { exit(1) }
        var turns: [PromptMessage] = [
            .init(role: .system, content: "You are a participant in a discussion about eggs.")
        ]
        log("session probe — one engine, three prompts sharing a growing prefix")
        do {
            let results = try await engine.sessionReuseProbe()
            log("  one ChatSession, three successive calls:")
            for (index, result) in results.enumerated() {
                log(
                    String(
                        format: "    call %d: prefilled %d tok in %.2fs",
                        index + 1, result.prefilled, result.prefillSeconds))
            }
        } catch {
            log("  session reuse probe failed: \(error.localizedDescription)")
            exit(1)
        }
        for turn in 1...3 {
            turns.append(
                .init(
                    // Every turn here is a question put to the model, so every turn is a user
                    // message. `turn == 1 ? .user : .assistant` sent the follow-ups as if the
                    // model had said them, so the prompt was system, user(Q1), assistant(Q2),
                    // assistant(Q3) — not the shared-prefix conversation this probe claims to
                    // measure. The assistant slot is filled by the placeholder appended below.
                    role: .user,
                    content: turn == 1
                        ? "Why are bird eggs ovoid rather than spherical? Answer in one sentence."
                        : "And what does that imply for shell thickness? Answer in one sentence."))
            do {
                _ = try await engine.generate(
                    messages: turns, tools: [], onToolCall: { _, _ in }, onEvent: { _ in })
            } catch {
                // A swallowed `try?` here was the same false success: the probe reported a
                // window of statistics for a turn that never happened.
                log("  turn \(turn) failed: \(error.localizedDescription)")
                exit(1)
            }
            if let stats = await engine.lastStats {
                log(
                    String(
                        format: "  turn %d: prompt %d tok, prefill %.2fs (%.0f tok/s), gen %.1f tok/s",
                        turn, stats.promptTokens, stats.prefillSeconds,
                        stats.prefillTokensPerSecond, stats.tokensPerSecond))
            }
            // The reply would be appended as an assistant message in the real loop.
            turns.append(.init(role: .assistant, content: "…"))
        }
        exit(0)
    }

    /// `--memory-probe`: report the GPU memory the process holds across loading and turns.
    static func runMemory(context: RunContext) async {
        let engines = context.engines
        let mib = 1024.0 * 1024.0
        /// The five quantities MLX's `Memory` actually exposes: active and cached allocations,
        /// their peak, the cache cap and the overall cap. There is no separate GPU limit — the
        /// table printed `memoryLimit` twice, once under `gpuLimit` and once under `memLimit`,
        /// so one of the five was never shown and one number wore two names.
        func report(_ label: String) {
            log(
                String(
                    format:
                        "  %-22@ active=%7.1f MiB  cache=%7.1f MiB  peak=%7.1f MiB  cacheLimit=%7.1f MiB  memLimit=%7.1f MiB",
                    label as NSString,
                    Double(Memory.activeMemory) / mib,
                    Double(Memory.cacheMemory) / mib,
                    Double(Memory.peakMemory) / mib,
                    Double(Memory.cacheLimit) / mib,
                    Double(Memory.memoryLimit) / mib))
        }
        log(
            engines.count > 1
                ? "GPU memory (one seat, then both, then a turnaround):"
                : "GPU memory (one seat, then a turnaround):")
        report("start")
        // A failed load makes every number below it meaningless; exiting 0 after logging the
        // failure is the same false success as the benchmark's.
        guard await loadSeat(engines[0], label: "A") else { exit(1) }
        report("after load A")
        // The second seat is optional: a one-seat roster is a supported configuration, and
        // `engines[1]` used to trap rather than report anything.
        if engines.count > 1 {
            guard await loadSeat(engines[1], label: "B") else { exit(1) }
            report("after load B")
        }
        let prompt = [
            PromptMessage(role: .system, content: "Answer briefly."),
            PromptMessage(role: .user, content: "Name three shapes."),
        ]
        for turn in 1...3 {
            // Alternates A and B when both exist, and stays on A when the roster has one seat:
            // `turn % 2` asked for `engines[1]` on a one-seat roster and trapped.
            do {
                _ = try await engines[turn % min(2, engines.count)].generate(
                    messages: prompt, tools: [], onToolCall: { _, _ in }, onEvent: { _ in })
            } catch {
                // `try?` here swallowed the failure, so a model that loaded but could not
                // generate produced a plausible memory table for turns that made no tokens, and
                // the probe exited 0 — the same false success the session probe and the
                // benchmark were fixed for.
                log("  turn \(turn) failed: \(error.localizedDescription)")
                exit(1)
            }
            report("after turn \(turn)")
        }
        exit(0)
    }
}
