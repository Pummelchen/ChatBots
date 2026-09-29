// ChatBotsCore — keeping a fast backend from outrunning the person watching it
//
// A local model is limited by this Mac's GPU, so the app has never needed to slow one down. A hosted
// one is not: a flash-tier API answers at a couple of hundred tokens a second, several times reading
// speed, so a reply is finished before it can be read and the next turn is written on top of it.
// Holding the text back in the client does not fix that, it moves it — the transcript races ahead of
// the window and the gap grows with every turn, which is what "buffered" means here.
//
// So the delay belongs where the stream is consumed. Reading the socket more slowly is real
// backpressure: the server's send window fills and its own rate comes down, and nothing piles up in
// between. This type is that decision as arithmetic, so it can be tested without a clock.

import Foundation

/// A ceiling on how fast one turn's text may be produced, in characters per second.
public struct OutputBudget: Sendable {

    /// Characters per token, for reading a token rate as the character rate this measures.
    ///
    /// An approximation on purpose. The exact count is the model's own tokenizer, which this side does
    /// not have for a server's model, and the number only has to be close enough that "ten tokens a
    /// second" is a comfortable pace rather than an exact contract.
    public static let charactersPerToken: Double = 4

    /// The ceiling, in characters per second, or nil for none.
    public let charactersPerSecond: Double?

    private var emitted = 0
    private var started: Double?

    public init(charactersPerSecond: Double?) {
        self.charactersPerSecond = charactersPerSecond
    }

    /// The budget for a seat, from the ceiling it carries.
    ///
    /// Zero and negative both mean "no ceiling" rather than "no output": a caller turning the limit
    /// off has one value to send over the wire that is already a valid `Double`, and it must not be
    /// able to stop a seat dead.
    public init(tokensPerSecond: Double?) {
        if let tokensPerSecond, tokensPerSecond > 0 {
            self.charactersPerSecond = tokensPerSecond * Self.charactersPerToken
        } else {
            self.charactersPerSecond = nil
        }
    }

    /// Whether this budget would ever hold anything back.
    public var isActive: Bool { (charactersPerSecond ?? 0) > 0 }

    /// How long to wait before emitting `characters` more, in seconds, or nil when none is owed.
    ///
    /// `now` is seconds since any fixed point the caller likes; the first call starts the clock. The
    /// text is recorded as emitted, so the answer is about the average rate over the turn rather than
    /// about one delta — a stream that arrives in uneven bursts is smoothed, which is the point of
    /// pacing it here rather than in the interface.
    public mutating func delay(forEmitting characters: Int, now: Double) -> Double? {
        guard let charactersPerSecond, charactersPerSecond > 0, characters > 0 else { return nil }
        let start = started ?? now
        started = start
        emitted += characters
        let due = Double(emitted) / charactersPerSecond
        let owed = due - (now - start)
        return owed > 0 ? owed : nil
    }
}
