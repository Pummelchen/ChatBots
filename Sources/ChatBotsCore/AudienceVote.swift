// ChatBotsCore — the audience's verdict
//
// A conversation is watched, and the watcher has an opinion. Until now there was nowhere to put
// it: the human could cut in with a message, which changes the conversation, or say nothing,
// which loses the judgement. Neither is a vote. "That was the strongest thing said so far" and
// "that argument did not hold up" are observations *about* the transcript rather than
// contributions to it, and mixing them into the log would let one seat's turn be shaped by the
// audience's opinion of another's — which is the one thing a shared log is meant to prevent.
//
// So a vote is kept beside the conversation rather than in it. It is never sent to a model, it
// never enters a prompt, and it survives being saved and reopened. What it is for is the reader:
// a scorecard at the end of a debate, and a way to find the turns worth re-reading.
//
// **What it is not.** It is not a reward signal, it does not change sampling, and nothing in the
// engine reads it to decide who speaks. Calling it a vote is already generous — there is no
// election, nobody's turn depends on it — and making it into one would be a different feature
// with a different name.

import Foundation

/// What the audience thought of one contribution.
public struct AudienceVote: Sendable, Hashable, Codable, Identifiable {
    public enum Verdict: String, Sendable, Codable, CaseIterable, Identifiable {
        case strong
        case weak

        public var id: String { rawValue }

        /// What the verdict means, said as a judgement of the *contribution* rather than of the
        /// person. A scorecard that reads as a popularity contest makes the audience stop
        /// giving honest scores.
        public var label: String {
            switch self {
            case .strong: "moved it forward"
            case .weak: "did not hold up"
            }
        }

        public var symbol: String {
            switch self {
            case .strong: "arrow.up"
            case .weak: "arrow.down"
            }
        }
    }

    public var id: UUID
    /// The contribution being judged.
    public var turnID: UUID
    /// Who said it, so a tally does not have to walk the transcript to find out.
    public var seatID: String
    public var verdict: Verdict
    public var at: Date

    public init(
        id: UUID = UUID(), turnID: UUID, seatID: String, verdict: Verdict, at: Date = .now
    ) {
        self.id = id
        self.turnID = turnID
        self.seatID = seatID
        self.verdict = verdict
        self.at = at
    }
}

/// How one seat stands with the audience.
public struct AudienceScore: Sendable, Hashable, Codable {
    public var seatID: String
    public var strong: Int
    public var weak: Int

    public init(seatID: String, strong: Int, weak: Int) {
        self.seatID = seatID
        self.strong = strong
        self.weak = weak
    }

    /// Strong minus weak, which is the only number worth showing: a seat with four marks each
    /// way is not the same as one with none.
    public var score: Int { strong - weak }
    public var total: Int { strong + weak }
}

/// The audience's votes over a conversation.
///
/// A value type over the votes array rather than a second place to keep them, so there is one
/// source of truth and no chance of a tally drifting from what was actually cast.
public struct AudienceScorecard: Sendable, Hashable, Codable {
    public var votes: [AudienceVote]

    public init(votes: [AudienceVote] = []) {
        self.votes = votes
    }

    /// One vote per contribution, so voting twice changes the vote rather than counting twice.
    /// Anything else would let a reader inflate a score by clicking, which would make the
    /// scorecard worthless.
    public func vote(for turnID: UUID) -> AudienceVote? {
        votes.first { $0.turnID == turnID }
    }

    public mutating func cast(_ verdict: AudienceVote.Verdict, for turnID: UUID, seatID: String) {
        votes.removeAll { $0.turnID == turnID }
        votes.append(AudienceVote(turnID: turnID, seatID: seatID, verdict: verdict))
    }

    /// Withdraw a vote, so a mis-click does not have to be reversed by casting its opposite.
    public mutating func withdraw(turnID: UUID) {
        votes.removeAll { $0.turnID == turnID }
    }

    public mutating func clear() { votes.removeAll() }

    /// The scorecard, best first.
    ///
    /// Sorted by score and then by seat, so a tie is not resolved by whichever seat happened to
    /// be created first — the order has to be reproducible or two readers comparing scorecards
    /// would be looking at different things.
    public var scores: [AudienceScore] {
        var bySeat: [String: (strong: Int, weak: Int)] = [:]
        for vote in votes {
            var entry = bySeat[vote.seatID] ?? (0, 0)
            switch vote.verdict {
            case .strong: entry.strong += 1
            case .weak: entry.weak += 1
            }
            bySeat[vote.seatID] = entry
        }
        return bySeat
            .map { AudienceScore(seatID: $0.key, strong: $0.value.strong, weak: $0.value.weak) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.strong != rhs.strong { return lhs.strong > rhs.strong }
                return lhs.seatID < rhs.seatID
            }
    }

    /// The seat the audience scored highest, when anyone has been scored at all.
    ///
    /// Nil rather than a name when every score is level: picking one would be inventing a
    /// winner, and "nobody stood out" is a real answer.
    public var leader: AudienceScore? {
        let scored = scores.filter { $0.total > 0 }
        guard let best = scored.first, best.score > 0 else { return nil }
        let tied = scored.filter { $0.score == best.score }
        return tied.count == 1 ? best : nil
    }
}
