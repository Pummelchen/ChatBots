// ChatBotsCore — the context window, how full it is and how it is condensed
//
// Split out of `ConversationEngine.swift`, which held the orchestrator, its turn loop, its
// transcript plumbing, its context bookkeeping and its research mode in one 1613-line file.
// Measuring a seat's real window and rewriting older turns into a digest are one algorithm,
// so they stayed together; nothing changed but which file the code lives in.

import Foundation

extension ConversationEngine {

    /// Rough prompt size and how full the tightest seat's window is.
    ///
    /// Measured from the last prompt a seat actually received, not from the transcript's
    /// own text. That distinction matters: the system prompt, the persona and the opening
    /// brief are rendered into every prompt and account for roughly nine hundred tokens
    /// before a single turn of conversation — enough that estimating from transcript text
    /// alone made the threshold unreachable. The transcript estimate is used only until a
    /// first turn has run.
    ///
    /// The window is the tightest of what the seats' engines actually report, so this and the
    /// auto-compaction threshold are measured against the same number. `refreshContextWindow`
    /// keeps `reportedContextWindows` current; before any turn has run the spec's value stands
    /// in, which is all that is known then.
    public var contextUsage: (tokens: Int, window: Int, fraction: Double) {
        let dialogue =
            conversation.dialogueTurns.reduce(0) { $0 + max(1, $1.content.count / 4) }
            + PromptBuilder.attachmentCharacters(conversation.attachments) / 4
        // A completed turn's prompt is the closest thing to ground truth available, plus
        // the prompt for the turn being composed now.
        let measured = measuredPromptTokens.map { $0 + dialogue - lastMeasuredDialogueTokens } ?? dialogue
        let tokens = max(dialogue, measured)
        let window =
            seats.map { knownContextWindow(for: $0) }.min() ?? AgentSpec.defaultContextWindow
        let fraction = window > 0 ? Double(tokens) / Double(window) : 0
        return (tokens, window, fraction)
    }

    /// What a seat's window falls back to when its engine reports nothing useful: the spec's
    /// own value, or the shared default when even that is unset.
    private func fallbackContextWindow(for seat: Seat) -> Int {
        seat.spec.contextWindow > 0 ? seat.spec.contextWindow : AgentSpec.defaultContextWindow
    }

    /// The window last heard from a seat's engine, for the synchronous display path.
    private func knownContextWindow(for seat: Seat) -> Int {
        if let reported = reportedContextWindows[seat.spec.id], reported > 0 { return reported }
        return fallbackContextWindow(for: seat)
    }

    /// Ask a seat's engine for its real context window and remember it.
    ///
    /// This is what `compactIfNeeded` measures the threshold against and what `contextUsage`
    /// reports, so a learned window reaches both. An engine that reports zero or less — a
    /// stub, or a backend that cannot discover one — falls back to the spec.
    @discardableResult
    func refreshContextWindow(for seat: Seat) async -> Int {
        let reported = await seat.engine.contextWindow
        if reported > 0 {
            reportedContextWindows[seat.spec.id] = reported
            return reported
        }
        return fallbackContextWindow(for: seat)
    }
    /// Condense older turns when the log approaches the context window.
    ///
    /// This replaces dropping the oldest entries, which silently destroyed the beginning of
    /// the discussion. A digest keeps the thread's conclusions, positions and open
    /// questions at a fraction of the tokens.
    ///
    /// Returns true when compaction ran, so the caller can tell that the transcript has
    /// been rewritten underneath it.
    @discardableResult
    func compactIfNeeded(using seat: Seat, force: Bool = false, window: Int? = nil) async -> Bool {
        _ = force  // an explicit call always runs; see `compactNow`

        let spec = await seat.engine.currentSpec
        // The caller in `runTurn` has already asked the engine; `compactNow` has not, so ask
        // here. Either way this is the seat's real window, and the spec is only the fallback.
        let effectiveWindow: Int
        if let window {
            effectiveWindow = window
        } else {
            effectiveWindow = await refreshContextWindow(for: seat)
        }
        let usage = contextUsage
        let tokens = usage.tokens
        let fraction = Double(tokens) / Double(effectiveWindow)
        guard force || fraction >= configuration.compactThreshold else { return false }

        let dialogue = conversation.turns.filter { $0.kind != .tool }
        guard dialogue.count > configuration.compactKeepRecentTurns + 2 else {
            // Too little to condense usefully — the window is simply small for this topic.
            note(
                "Prompt is \(tokens) tokens of a \(effectiveWindow)-token window but there is not enough history to condense yet."
            )
            return false
        }

        let pinned = Set(
            dialogue.filter { $0.kind == .topic || $0.kind == .introduction || $0.kind == .summary }
                .map(\.id))
        let older = dialogue.dropLast(configuration.compactKeepRecentTurns).filter { !pinned.contains($0.id) }
        guard !older.isEmpty else { return false }

        let previous = conversation.summaryTurn?.content
        let prompt = PromptBuilder.compactionPrompt(
            for: spec, turns: Array(older), topic: conversation.topic, previousSummary: previous)

        note(
            "Context \(Int(fraction * 100))% full — condensing \(older.count) older entries with \(spec.id).")

        let digest: String
        do {
            digest = try await seat.engine.compact(
                prompt: prompt, maxTokens: configuration.compactSummaryTokens)
        } catch {
            note("Compaction with \(spec.id) failed: \(error.localizedDescription)")
            return false
        }
        guard !digest.isEmpty else {
            note("Compaction with \(spec.id) returned nothing; the log is unchanged.")
            return false
        }

        // Replace: drop whatever was condensed, drop any previous summary (it is folded
        // into the new one), and keep the rest in order.
        let removedIDs = Set(older.map(\.id))
        var replacement = conversation.turns.filter { turn in
            turn.kind != .summary && !removedIDs.contains(turn.id)
        }
        let condensed = Turn(
            sequence: 0,
            speakerName: "Condensed",
            kind: .summary,
            content: digest
        )
        // The digest belongs *after* the opening, not in front of it: the topic and brief
        // are the frame the digest summarises, and a model reading the digest first would
        // meet the discussion's conclusions before its subject.
        let pinnedPrefixCount = replacement.prefix { $0.kind == .topic || $0.kind == .introduction }.count
        replacement.insert(condensed, at: pinnedPrefixCount)
        // Renumber so ordering stays obvious and unique.
        replacement = replacement.enumerated().map { index, turn in
            var copy = turn
            copy.sequence = index + 1
            return copy
        }
        conversation.turns = replacement
        publishTranscript()
        note(
            "Condensed \(older.count) entries into \(digest.count / 4) tokens; context is now about \(contextUsage.tokens) tokens."
        )
        return true
    }
}
