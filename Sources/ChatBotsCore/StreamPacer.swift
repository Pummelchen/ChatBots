// ChatBotsApp — revealing model output smoothly instead of in bursts
//
// Two problems, one mechanism.
//
// **Bursty output.** A model does not emit at a constant rate: tokens arrive in clumps,
// sometimes several at once, and the pane therefore appears in jumps — a word, a pause,
// half a sentence. This smooths it by queueing what arrives and releasing it at a steady
// character rate every frame.
//
// **The gap between turns.** The obvious fix — buffer for a fixed few seconds — does not
// work here, and it is worth writing down why. A turn generates for twenty-odd seconds, so
// a five-second buffer drains long before the next turn is ready and the visible gap comes
// straight back. What actually removes the gap is matching the *reveal* rate to the
// *generation* rate: the queue then holds roughly a constant amount of unshown text, so a
// seat finishes displaying just as the next one finishes generating and starts speaking.
// The rate is measured from this conversation's own throughput rather than assumed, and it
// has a floor so text never crawls.
//
// The arithmetic is deliberately separate from the timer so it can be tested without
// waiting in real time.

import Foundation

/// Decides how much queued text to release and how fast.
public struct StreamPacer: Sendable {
    /// Characters per second when nothing has been measured yet. Roughly the pace of this
    /// hardware's generation, so the first turn is already close.
    public init() {}

    /// Start already knowing how fast this stream produced text last time.
    ///
    /// A pacer created with the default rate re-converges from 40 cps, so a stream whose model
    /// is slower than that drains its queue at the start of every turn — the visible gap this
    /// whole mechanism exists to remove (audit A63). `StreamPacerPool` remembers the last
    /// measured rate per stream and passes it here, so a new pacer starts where the previous
    /// one finished rather than where the default assumption began.
    ///
    /// The seed is the same ceiling `observeGeneration` converges to, so the first frames
    /// behave as the converged pacer did. A missing, zero or non-finite rate leaves the
    /// defaults alone — nothing has been measured, so nothing is assumed.
    public init(seedingFrom generationRate: Double?) {
        guard let generationRate, generationRate > 0, generationRate.isFinite else { return }
        self.generationRate = generationRate
        revealRate = max(minimumRate, min(maximumRate, generationRate * 0.95))
    }

    public var revealRate: Double = 40
    /// A safety net only.
    ///
    /// Deliberately *below* any real generation rate rather than an aesthetic floor: a
    /// floor above the model's rate would drain the queue, and an empty queue is exactly
    /// the pause this exists to remove. Smoothness is traded for the hand-off when the two
    /// conflict, because a slow model dribbling text is honest whereas a drained queue
    /// brings the visible gap straight back.
    public var minimumRate: Double = 5
    /// Hard cap, for when no generation rate has been measured yet.
    public var maximumRate: Double = 240
    /// The rate the model itself is producing at, measured.
    ///
    /// This is what the reveal rate converges to, and it matters that it is the model's
    /// rate rather than a fixed cap: revealing *faster* than the model generates would
    /// drain the queue, and an empty queue is exactly the pause this exists to remove. At
    /// the model's own rate the queue holds steady, so a seat finishes displaying as the
    /// next one finishes generating.
    public private(set) var generationRate: Double?
    /// How strongly a new measurement moves the rate. Low, because throughput is noisy and
    /// a visibly speeding-up or slowing-down transcript is worse than a steady one.
    public var responsiveness: Double = 0.25

    /// Unrevealed text.
    public private(set) var pending = ""
    /// Fractional characters carried between frames, so a slow frame does not lose text.
    private var carry: Double = 0

    /// Characters currently waiting to be shown. A steady queue is the point: it is what
    /// makes the next turn start without a visible pause.
    public var backlog: Int { pending.count }

    public mutating func enqueue(_ text: String) {
        pending += text
    }

    /// Fold in a measured generation rate, in characters per second.
    public mutating func observeGeneration(charactersPerSecond: Double) {
        guard charactersPerSecond > 0, charactersPerSecond.isFinite else { return }
        generationRate = charactersPerSecond
        let target = min(max(charactersPerSecond, minimumRate), maximumRate)
        revealRate += (target - revealRate) * responsiveness
        revealRate = min(max(revealRate, minimumRate), ceiling)
    }

    /// The fastest it may reveal.
    ///
    /// Just under the model's own rate once measured, so the queue grows very slightly
    /// rather than being emptied — an empty queue is the pause this whole mechanism is for.
    private var ceiling: Double {
        guard let generationRate else { return maximumRate }
        return max(minimumRate, min(maximumRate, generationRate * 0.95))
    }

    /// Release the text due for `elapsed` seconds.
    ///
    /// Cutting at the last word boundary within the due amount avoids the other blocky
    /// artefact: a word appearing letter by letter. If no boundary is near, the text is
    /// released anyway rather than being held back indefinitely.
    public mutating func drain(elapsed: Double) -> String {
        guard !pending.isEmpty, elapsed > 0 else { return "" }
        carry += revealRate * elapsed
        var due = Int(carry)
        guard due > 0 else { return "" }

        if due >= pending.count {
            let all = pending
            pending = ""
            carry = 0
            return all
        }

        // Prefer to stop after whitespace so words appear whole.
        let limit = pending.index(pending.startIndex, offsetBy: due)
        if let boundary = pending[..<limit].lastIndex(where: \.isWhitespace) {
            let distance = pending.distance(from: pending.startIndex, to: boundary) + 1
            // Do not hold text back for long chasing a boundary.
            if due - distance <= 12 {
                due = distance
            }
        }

        let cut = pending.index(pending.startIndex, offsetBy: due)
        let released = String(pending[..<cut])
        pending = String(pending[cut...])
        carry -= Double(due)
        return released
    }

    public mutating func reset() {
        pending = ""
        carry = 0
    }
}

/// Paces several streams at once — one per seat, and one for each seat's reasoning — while
/// the app keeps a single heartbeat.
///
/// Not `@MainActor`: it holds only value types and is driven from one place (the app's
/// display tick), so requiring the main actor would add an isolation hop without adding
/// any safety. Keeping it in Core rather than the app also makes the arithmetic testable.
public final class StreamPacerPool {
    public init() {}

    /// Which stream a piece of text belongs to.
    public enum Channel: Hashable, Sendable { case answer, reasoning }

    private struct Key: Hashable {
        var agentID: String
        var channel: Channel
    }

    private var pacers: [Key: StreamPacer] = [:]
    /// Per-channel generation rate, smoothed, for new pacers to start from.
    ///
    /// Kept across `clear`: the throughput belongs to the stream and the model behind it, not
    /// to the turn, so it is what seeds the next turn's pacer (audit A63). Written by
    /// `observe`, read by `enqueue`.
    private var generationRates: [Key: Double] = [:]

    public func enqueue(_ text: String, agentID: String, channel: Channel) {
        guard !text.isEmpty else { return }
        let key = Key(agentID: agentID, channel: channel)
        // A pacer created here starts from the rate this stream last produced at, not from the
        // default 40 cps. The app clears a seat's pacer at every `.turnStarted`, so without this
        // the learned rate was stored and never read back and each turn re-converged from 40 —
        // a slow stream drained its queue at the start of every turn (audit A63).
        var pacer = pacers[key] ?? StreamPacer(seedingFrom: generationRates[key])
        pacer.enqueue(text)
        pacers[key] = pacer
    }

    /// Record observed throughput for a seat, in characters per second.
    public func observe(agentID: String, charactersPerSecond: Double) {
        for channel in [Channel.answer, .reasoning] {
            let key = Key(agentID: agentID, channel: channel)
            guard pacers[key] != nil else { continue }
            generationRates[key] = charactersPerSecond
            var pacer = pacers[key]!
            pacer.observeGeneration(charactersPerSecond: charactersPerSecond)
            pacers[key] = pacer
        }
    }

    /// Release whatever is due. Returns per-agent text for each channel that produced any.
    public func drain(elapsed: Double) -> [(agentID: String, channel: Channel, text: String)] {
        var released: [(String, Channel, String)] = []
        for (key, var pacer) in pacers {
            let text = pacer.drain(elapsed: elapsed)
            pacers[key] = pacer
            if !text.isEmpty { released.append((key.agentID, key.channel, text)) }
        }
        return released
    }

    /// How much text is still queued for a seat's answer.
    public func backlog(agentID: String, channel: Channel = .answer) -> Int {
        pacers[Key(agentID: agentID, channel: channel)]?.backlog ?? 0
    }

    /// True while any answer still has text waiting to be shown.
    public var isDraining: Bool {
        pacers.contains { $0.key.channel == .answer && $0.value.backlog > 0 }
    }

    /// Drop a seat's queued text without forgetting how fast it was producing.
    ///
    /// Called at every `.turnStarted` so a new turn does not reveal the last one's tail. The
    /// pacer goes; the measured rate in `generationRates` stays, and seeds the next pacer.
    public func clear(agentID: String) {
        for channel in [Channel.answer, .reasoning] {
            pacers[Key(agentID: agentID, channel: channel)] = nil
        }
    }
}
