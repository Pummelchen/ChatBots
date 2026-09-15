// ChatBotsCore — reading what a turn did, from its text
//
// This is the weakest link in the conflict engine and is written to admit it. Detecting that
// an argument was *good* is not something a phrase list can do; a wrong signal is worse than
// no signal, because it produces hostility nobody earned and buries the beats the
// conversation actually had.
//
// So the reader only commits to what the text shows plainly:
//
//   · an explicit concession, an apology, an outright agreement
//   · a direct attack on a person rather than on an argument
//   · a contradiction held up as such
//   · whether material was brought in, and whether a claim was offered with nothing behind it
//
// It deliberately does **not** try to judge whether an argument was strong, interesting or
// persuasive. That is left to the trajectory: a seat that keeps getting challenged without
// conceding loses respect over several turns, which is a pattern a phrase list *can* see
// even though a single message cannot be judged.
//
// Phrases are matched on the text as written, which is why they are written the way people
// actually type them rather than as a tidy taxonomy.

import Foundation

public enum ConflictReader {

    /// Read one message, aimed at whoever spoke before.
    ///
    /// `others` is every other seat, used only for naming a target when the text names one.
    /// `names` maps a lowercased display name to the seat id the state is keyed by.
    ///
    /// Two different strings are in play: the models write a person's name, and the social state is
    /// keyed by seat id. Matching the text against the *ids* meant a peer addressed by name never
    /// resolved as a named target — "Otto, that's rubbish" produced no target at all — so the signal
    /// landed on whoever spoke last instead of on Otto (A199).
    public static func signals(
        in text: String,
        from speaker: String,
        others: [String],
        names: [String: String] = [:],
        addressing previousSpeaker: String?
    ) -> [TurnSignal] {
        let lowered = text.lowercased()
        var signals: [TurnSignal] = []

        // Named targets win over the previous speaker: "Otto, that's rubbish" is about Otto
        // even if someone else spoke in between.
        let target = namedTarget(in: lowered, names: names) ?? previousSpeaker

        // ── Concession ────────────────────────────────────────────────────────────────
        // The strongest signal available, and the one that most changes a relationship, so it
        // is matched narrowly: an admission, not a polite "I see your point".
        let concessionPhrases = [
            "you're right", "you are right", "you were right", "i was wrong", "i was mistaken",
            "i stand corrected", "fair enough", "i concede", "i'll concede", "that's a fair point",
            "that is a fair point", "i hadn't considered", "i had not considered",
            "i take that back", "i'll give you that", "i will give you that",
            "i have to admit you", "i admit you", "point taken",
        ]
        if let phrase = firstMatch(concessionPhrases, in: lowered) {
            signals.append(TurnSignal(kind: .concession, confidence: 0.9, target: target))
            _ = phrase
        }

        // ── Position change ───────────────────────────────────────────────────────────
        // The speaker moved their own position. The case was declared and handled from the
        // beginning, but the reader never emitted it, while the research engine counts
        // `positionChange` as progress — so the second branch of that check could never fire,
        // a turn that revised its conclusion without an evidence marker was counted as adding
        // nothing, and a session could report that the analysts had converged while their
        // positions were still moving (audit A71).
        //
        // The phrases are self-revision rather than disagreement with someone else. A
        // concession ("I was wrong") is the clearest instance and is included, because
        // conceding *is* a position moving. A false positive here costs a turn of budget, not
        // a false claim, so the list deliberately errs towards noticing a revision.
        let positionChangePhrases = [
            "you're right", "you are right", "i was wrong", "i was mistaken",
            "i stand corrected", "i take that back", "i concede", "i'll concede",
            "i hadn't considered", "i had not considered", "i've changed my mind",
            "i have changed my mind", "i changed my mind", "my position has changed",
            "i changed my position", "i now think", "i now believe", "on reflection",
            "having thought about", "having re-read", "having reread", "i revise",
            "i'll revise", "i will revise", "i no longer", "i've come round",
            "i have come round", "i was too quick", "in hindsight", "i withdraw",
            "i retract",
        ]
        if firstMatch(positionChangePhrases, in: lowered) != nil {
            signals.append(TurnSignal(kind: .positionChange, confidence: 0.7, target: target))
        }

        // ── Reconciliation ────────────────────────────────────────────────────────────
        let reconciliationPhrases = [
            "i'm sorry", "i am sorry", "i apologise", "i apologize", "that was uncalled for",
            "no offence meant", "no offense meant", "let's not", "i didn't mean to",
            "i did not mean to", "we're on the same side",
        ]
        if firstMatch(reconciliationPhrases, in: lowered) != nil {
            signals.append(TurnSignal(kind: .reconciliation, confidence: 0.8, target: target))
        }

        // ── Agreement ─────────────────────────────────────────────────────────────────
        let agreementPhrases = [
            "i agree", "i agree with", "you're onto something", "you are onto something",
            "that's exactly what i", "that is exactly what i", "i'd back that", "i would back that",
            "you make a good point", "i think you're right about", "same conclusion",
            "i came to the same", "that matches what i",
        ]
        if firstMatch(agreementPhrases, in: lowered) != nil {
            signals.append(TurnSignal(kind: .agreement, confidence: 0.75, target: target))
        }

        // ── Contradiction ─────────────────────────────────────────────────────────────
        let contradictionPhrases = [
            "you contradicted yourself", "that contradicts what you", "you said earlier",
            "you just said", "you're contradicting", "you are contradicting",
            "that's the opposite of what you", "that is the opposite of what you",
            "earlier you claimed", "you can't have it both ways", "you cannot have it both ways",
            "first you said", "which is it",
        ]
        if firstMatch(contradictionPhrases, in: lowered) != nil {
            signals.append(TurnSignal(kind: .contradiction, confidence: 0.8, target: target))
        }

        // ── Jab ───────────────────────────────────────────────────────────────────────
        // Aimed at a person, not at a claim. "That argument is weak" is a challenge; "you are
        // an idiot" is a jab; "that's ridiculous" is a jab at the claim and counts as a
        // challenge, not a personal attack — the distinction the brief draws.
        let jabPhrases = [
            "you're an idiot", "you are an idiot", "you're pathetic", "you are pathetic",
            "you're useless", "you are useless", "you're clueless", "you are clueless",
            "you're embarrassing", "you are embarrassing", "shut up", "nobody asked you",
            "you're a joke", "you are a joke", "you're deluded", "you are deluded",
            "you're hopeless", "you have no idea what you're talking about",
            "you have no idea what you are talking about", "trust me, bro",
        ]
        if firstMatch(jabPhrases, in: lowered) != nil {
            signals.append(TurnSignal(kind: .jab, confidence: 0.85, target: target))
        }

        // ── Challenge ─────────────────────────────────────────────────────────────────
        let challengePhrases = [
            "that doesn't follow", "that does not follow", "that's nonsense", "that is nonsense",
            "that's ridiculous", "that is ridiculous", "that's absurd", "that is absurd",
            "where's your evidence", "where is your evidence", "you haven't shown",
            "you have not shown", "that's not an argument", "that is not an argument",
            "you're begging the question", "that proves nothing", "unfounded",
            "on what basis", "you're assuming", "you are assuming", "that's a stretch",
            "that is a stretch", "you've just asserted", "you have just asserted",
            "circular", "hand-waving", "hand waving", "you're dodging", "you are dodging",
        ]
        if firstMatch(challengePhrases, in: lowered) != nil {
            signals.append(TurnSignal(kind: .challenge, confidence: 0.7, target: target))
        }

        // ── Unsupported claim ─────────────────────────────────────────────────────────
        // A confident assertion with nothing behind it. Only counted when the message also
        // carries no evidence marker at all, so a sourced claim is never read as unsupported.
        let evidencePhrases = [
            "according to", "the data shows", "the study", "research shows", "reported that",
            "published", "survey", "statistics", "for example", "for instance", "in 20",
            "measured", "the figure", "per cent", "percent",
        ]
        let hedges = [
            "i don't know", "i do not know", "i'm not sure", "i am not sure", "i could be wrong",
            "i may be wrong", "i don't have a source", "i do not have a source",
            "unverified", "i can't verify", "i cannot verify", "i think", "probably",
            "my guess", "it seems",
        ]
        let hasEvidence = firstMatch(evidencePhrases, in: lowered) != nil
        let hasHedge = firstMatch(hedges, in: lowered) != nil
        if hasEvidence {
            signals.append(TurnSignal(kind: .newEvidence, confidence: 0.6))
        }
        let certaintyPhrases = [
            "obviously", "clearly", "everyone knows", "it's a fact", "it is a fact",
            "without doubt", "undeniable", "no question that", "the truth is",
        ]
        if !hasEvidence, !hasHedge, firstMatch(certaintyPhrases, in: lowered) != nil {
            signals.append(TurnSignal(kind: .unsupportedClaim, confidence: 0.6))
        }

        return signals
    }

    /// A seat named in the message, if one is.
    ///
    /// Matched on a word boundary so "Otto" does not match "ottoman". A seat whose name is a
    /// single letter would be too easy to hit by accident, so names shorter than three
    /// characters are ignored — which is why the shipped names are longer.
    /// The seat id named in the message, looked up by display name.
    ///
    /// Matching is on the name the models write, not on the id they never see; the answer is the id,
    /// because that is what the social state is keyed by (A199).
    public static func namedTarget(in lowered: String, names: [String: String]) -> String? {
        // Longest name first, so "Ann" cannot shadow "Anna" when both are participants.
        for name in names.keys.sorted(by: { $0.count > $1.count }) {
            guard name.count >= 3 else { continue }
            if matches(lowered, name) { return names[name] }
        }
        return nil
    }

    /// The name found in the message, matched on a word boundary.
    private static func matches(_ lowered: String, _ needle: String) -> Bool {
        var searchStart = lowered.startIndex
        while let range = lowered.range(of: needle, range: searchStart..<lowered.endIndex) {
            let before = range.lowerBound == lowered.startIndex
                ? nil : lowered[lowered.index(before: range.lowerBound)]
            let after = range.upperBound == lowered.endIndex
                ? nil : lowered[range.upperBound]
            let boundaryBefore = before.map { !$0.isLetter && !$0.isNumber } ?? true
            let boundaryAfter = after.map { !$0.isLetter && !$0.isNumber } ?? true
            if boundaryBefore && boundaryAfter { return true }
            searchStart = range.upperBound
        }
        return false
    }

    public static func namedTarget(in lowered: String, others: [String]) -> String? {
        // The same matcher the name lookup uses, so the two cannot drift apart: this one searches the
        // strings it is handed rather than a name-to-id map (A199).
        // The three-character floor is this variant's own rule (a one-letter name matches by accident);
        // `namedTarget(in:names:)` applies it when the index is built. An existing test caught its
        // absence the moment the two were collapsed into one matcher.
        for other in others where other.count >= 3 && matches(lowered, other.lowercased()) {
            return other
        }
        return nil
    }

    /// The first phrase present, for a cheaper check than building an array.
    private static func firstMatch(_ phrases: [String], in lowered: String) -> String? {
        for phrase in phrases where lowered.contains(phrase) { return phrase }
        return nil
    }
}

extension ConflictReader {
    /// A short quotation from a message, for naming a grudge.
    ///
    /// A grudge has to be able to say *what* was said, or the prompt can only report an
    /// unexplained hostility — which reads as the character being unreasonable rather than
    /// aggrieved. The first sentence is used, trimmed, because that is where a remark lands.
    public static func summary(of text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let firstSentence = cleaned.split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
            .first.map(String.init) ?? cleaned
        let trimmed = firstSentence.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 12 else { return nil }
        return String(trimmed.prefix(120))
    }
}
