// ChatBotsApp — turning the engine's feed into pane state
//
// The engine sends two shapes of thing — a whole state whenever the conversation changes, and
// fragments of output as a model writes — and this is where both are read: the snapshot that
// fills the transcript, the seats and the statistics, and the fragments that are queued for
// the pacer and released a paragraph at a time. The pacing itself lives here too, because it
// exists only to serve those fragments.

import ChatBotsCore
import Foundation

@MainActor
extension ChatController {

    func startPumps() {
        // Two pumps, because the engine sends two shapes of thing: a whole state whenever
        // something changes, and fragments of output as a model writes.
        //
        // The state is authoritative and slow-moving; the fragments are fast and partial. The
        // transcript, the statistics and the seat settings come from states, so they cannot
        // drift. The visible text comes from fragments, so it arrives as it is written rather
        // than in whole answers — which is what the pacing below turns into a smooth reveal.
        pumpTasks.append(
            Task { [weak self] in
                guard let client = self?.client, let events = client.events else { return }
                for await event in events {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .state(let snapshot):
                        self.apply(snapshot)
                    case .output(let delta):
                        self.apply(delta)
                    }
                }
            }
        )
    }

    /// Applies buffered *non-text* deltas to the panes.
    ///
    /// Streamed text no longer passes through here: it goes into the pacer, which releases
    /// it at a steady rate. This only carries the cheap state changes.
    func flush() {
        guard !pending.isEmpty else { return }
        let buffered = pending
        pending.removeAll(keepingCapacity: true)

        for (agentID, delta) in buffered {
            guard let pane = pane(agentID) else { continue }
            if let activity = delta.activity { pane.activity = activity }
        }
    }

    /// Take one fragment of streamed output.
    ///
    /// Converted into the same event the in-process engine used to deliver, so the pacing,
    /// the block handling and the rate sampling below are unchanged.
    private func apply(_ delta: APISnapshot.OutputDelta) {
        switch delta.kind {
        case "token":
            apply(.token(agentID: delta.agentID, text: delta.text))
        case "reasoning":
            apply(.reasoning(agentID: delta.agentID, text: delta.text))
        case "tool":
            // Sent as one string because a fragment has one text field; split back into the
            // name and the query the display logic expects.
            let parts = delta.text.split(separator: "(", maxSplits: 1)
            apply(
                .toolCall(
                    agentID: delta.agentID,
                    name: String(parts.first ?? ""),
                    query: parts.count > 1
                        ? String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: ")"))
                        : ""))
        case "started":
            // The prompt itself is not sent to a client — it is the engine's rendering of the
            // log and can be enormous. The pacer only needs to know a turn has begun.
            pane(delta.agentID)?.beginTurn()
        default:
            break
        }
    }

    private func apply(_ event: TurnEvent) {
        switch event {
        // Streaming text is buffered and published on a timer. Republishing a growing
        // string (and re-laying-out the transcript) for every token is what makes a
        // streaming UI stutter; a turn finishes in well under a frame's worth of tokens
        // at these rates either way.
        case .token(let agentID, let text):
            // Straight into the pacer: what arrives is queued, not shown. The queue is what
            // absorbs a burst, and what builds the backfill that hides the next turn's wait.
            pacer.enqueue(text, agentID: agentID, channel: StreamPacerPool.Channel.answer)
            sampleGenerationRate(agentID: agentID, characters: text.count)

        case .reasoning(let agentID, let text):
            pacer.enqueue(text, agentID: agentID, channel: StreamPacerPool.Channel.reasoning)
            sampleGenerationRate(agentID: agentID, characters: text.count)

        case .toolCall(let agentID, let name, let query):
            // `prefix` on a String counts grapheme clusters, so a query full of emoji or
            // CJK is shortened without being cut mid-character.
            pending[agentID, default: Delta()].activity = "\(name)(\(UTF8Text.prefix(query, 48)))"

        case .turnStarted(let agentID, _):
            flush()  // the previous turn's tail must land before its row is cleared
            threadScrollSignal += 1
            // A new turn on this seat invalidates anything still queued for the last one.
            pacer.clear(agentID: agentID)
            rateSamples[agentID] = nil
            for pane in panes {
                if pane.spec.id == agentID {
                    pane.beginTurn()
                } else if pane.isGenerating {
                    pane.endTurn()
                }
            }

        // A turn's end, its tool results and its failure are deliberately *not* handled here.
        //
        // The protocol forwards four fragment kinds — `token`, `reasoning`, `tool` and
        // `started` — so these cases are unreachable from `apply(_ delta:)`. They are read
        // instead from the snapshot's `live` view in `apply(_ snapshot)`: `isGenerating` ends
        // the turn, `toolLog` carries the tool results and failures, and `activity` carries the
        // engine's own note of a failed turn. Spelled out rather than left to `default: break`
        // so the decision is visible and so a future fragment added to the protocol has to be
        // considered here. A dedicated per-turn error banner is not available over this
        // transport; the failure is still shown, in `notices`, which the snapshot carries.
        case .turnFinished, .toolResult, .toolFailure, .turnFailed:
            break
        }
    }

    /// Record how fast this seat is producing characters, so the reveal rate can match it.
    ///
    /// Sampled over a window rather than per token, because per-token arrival is bursty by
    /// nature and would make the reveal rate jitter with it.
    private func sampleGenerationRate(agentID: String, characters: Int) {
        let now = Date.now
        guard var sample = rateSamples[agentID] else {
            rateSamples[agentID] = (characters, now)
            return
        }
        sample.characters += characters
        let elapsed = now.timeIntervalSince(sample.since)
        guard elapsed >= 0.5 else {
            rateSamples[agentID] = sample
            return
        }
        let rate = Double(sample.characters) / elapsed
        rateSamples[agentID] = (0, now)
        // The rate the reveal is paced at, and the only thing the measurement is for: it was also
        // assigned to a `measuredGenerationRate` that no view read.
        pacer.observe(agentID: agentID, charactersPerSecond: rate)
    }
}
