// ChatBotsCore — the social state an entertainment conversation accumulates
//
// The brief asks that a character react to what happened earlier: respect for a good argument,
// annoyance at a jab, a grudge carried across the whole conversation, an alliance that forms
// and is later abandoned. That needs state which lives between turns and is fed back into the
// prompt — this file is that state, and the rules that move it.
//
// Two decisions shape everything here.
//
// **The state is per pair, not per seat.** Almost everything worth modelling is relational:
// respect for one character says nothing about respect for another, and an alliance is
// between two seats. A per-seat score could not express "sides with B against C".
//
// **What is inferred from text is inferred conservatively.** Detecting "a strong argument" is
// not something a phrase list can do reliably, and a conflict engine fed wrong signals is
// worse than one fed none: it would produce hostility nobody earned and miss the beats the
// conversation actually had. So the detector only commits to signals it can see plainly —
// an explicit concession, a direct jab, a contradiction surfaced, a challenge aimed at
// someone — and records the rest as *pressure* that has to build before it moves a
// relationship. A single hard-to-judge message changes nothing; a pattern does.
//
// Nothing here is random. The same conversation read twice produces the same state, which is
// what makes it testable, and a conversation that behaves differently each run would be
// impossible to reason about when someone reports that the characters went strange.

import Foundation

/// How one seat regards another.
///
/// Every value is a running score rather than an enum, because the interaction the brief
/// describes is gradual: annoyance builds, respect is earned slowly, a grudge is held. The
/// names say what the score means to the prompt, not what the number is.
public struct Relationship: Sendable, Hashable, Codable {
    /// Earned by a good argument, spent by a weak one. Drives how much the seat engages
    /// seriously with what this one says.
    public var respect: Double = 0
    /// Raised by a jab, lowered by an apology. Drives hostility and retaliation.
    public var annoyance: Double = 0
    /// Raised by agreement and by defending someone, lowered by attacking them. Bipolar:
    /// zero is "no view of them yet", negative is active distrust. Floored at zero it could
    /// not record that an attack had cost anything, which is exactly the movement that
    /// matters.
    public var trust: Double = 0
    /// A separate axis from annoyance: a seat can enjoy a fight without resenting it.
    public var competition: Double = 0
    /// An unfinished grudge, with the reason, so the prompt can name it.
    public var grudge: Grudge?
    /// A live alliance, with how long it has been standing.
    public var alliance: Alliance?

    public struct Grudge: Sendable, Hashable, Codable {
        /// What was done, in the other participant's words where possible.
        public var reason: String
        /// Which turn it happened on, so the prompt can say "earlier" honestly.
        public var sinceSequence: Int
        public var intensity: Double
    }

    public struct Alliance: Sendable, Hashable, Codable {
        public var sinceSequence: Int
        /// Raised by defending one another, lowered by attacking.
        public var strength: Double
    }

    public init() {}

    /// A word for how this seat currently feels, for the prompt.
    public var posture: String {
        if annoyance >= 0.7 { return "openly hostile" }
        if let grudge, grudge.intensity >= 0.25 { return "still holding the earlier slight" }
        if trust <= -0.4 { return "does not trust them" }
        if let alliance, alliance.strength >= 0.4 { return "allied" }
        if annoyance >= 0.4 { return "irritated" }
        if respect >= 0.6 { return "respectful" }
        if trust >= 0.5 { return "trusting" }
        if trust <= -0.4 { return "does not trust them" }
        if respect <= -0.3 { return "contemptuous of their reasoning" }
        return "neutral"
    }

    /// Whether anything here is worth telling the model about.
    ///
    /// A prompt that reports "respect: 0.05" for every pair is noise that buries the one
    /// relationship that actually matters. Only postures that have moved are reported.
    public var isNoteworthy: Bool {
        posture != "neutral"
    }

    mutating func decay(rate: Double = 0.06) {
        // Scores drift back toward neutral, so an old exchange does not permanently define a
        // relationship. Grudges and alliances fade more slowly — that is what makes them feel
        // like they persist across a conversation.
        annoyance = Relationship.drift(annoyance, rate: rate)
        competition = Relationship.drift(competition, rate: rate)
        trust = Relationship.drift(trust, rate: rate * 0.5)
        respect = Relationship.drift(respect, rate: rate * 0.4)
        if var grudge {
            grudge.intensity = max(0, grudge.intensity - rate * 0.15)
            self.grudge = grudge.intensity < 0.05 ? nil : grudge
        }
        if var alliance {
            alliance.strength = Relationship.drift(alliance.strength, rate: rate * 0.4)
            self.alliance = alliance.strength < 0.05 ? nil : alliance
        }
    }

    private static func drift(_ value: Double, rate: Double) -> Double {
        value > 0 ? max(0, value - rate) : min(0, value + rate)
    }

    mutating func clamp() {
        respect = min(1, max(-1, respect))
        annoyance = min(1, max(0, annoyance))
        trust = min(1, max(-1, trust))
        competition = min(1, max(0, competition))
        if var grudge {
            grudge.intensity = min(1, max(0, grudge.intensity))
            self.grudge = grudge
        }
        if var alliance {
            alliance.strength = min(1, max(0, alliance.strength))
            self.alliance = alliance
        }
    }
}

/// What a turn did, as far as the app can tell.
///
/// The conservative reading described at the top of the file lives here: each case is
/// something the text shows plainly, with a confidence attached so a single ambiguous match
/// cannot move a relationship on its own.
public struct TurnSignal: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// A direct jab at another participant, named or clearly aimed.
        case jab
        /// An open admission that the other was right.
        case concession
        /// A contradiction in what another said, held up.
        case contradiction
        /// A challenge aimed at someone's argument.
        case challenge
        /// Explicit agreement or backing for another's position.
        case agreement
        /// An attempt to make peace, including an apology.
        case reconciliation
        /// Material the seat brought in that the others had not.
        case newEvidence
        /// A claim offered with nothing behind it.
        case unsupportedClaim
        /// The speaker's own position moved.
        case positionChange

        /// A phrase for the prompt. Reads as something that happened, not as a category.
        var phrase: String {
            switch self {
            case .jab: "aimed a personal remark"
            case .concession: "conceded the point"
            case .contradiction: "caught a contradiction"
            case .challenge: "went after the argument"
            case .agreement: "backed the position"
            case .reconciliation: "tried to make peace"
            case .newEvidence: "brought in something new"
            case .unsupportedClaim: "asserted something without support"
            case .positionChange: "moved their own position"
            }
        }
    }

    public var kind: Kind
    /// 0–1. Below the thresholds below, a signal is recorded but does not move much.
    public var confidence: Double
    /// Who it was aimed at, when the text aims it at someone.
    public var target: String?

    public init(kind: Kind, confidence: Double, target: String? = nil) {
        self.kind = kind
        self.confidence = confidence
        self.target = target
    }
}

/// Everything the conversation has built up socially.
public struct ConflictState: Sendable, Hashable, Codable {

    /// How the state reports itself to a seat, which is the whole point of holding it.
    public struct Briefing: Sendable, Hashable {
        /// Lines describing how this seat feels about each other seat.
        public var relationships: [String]
        /// What just happened, in the prompt's words.
        public var recentBeats: [String]
        /// Whether any of this is worth saying at all.
        public var isEmpty: Bool { relationships.isEmpty && recentBeats.isEmpty }
    }

    /// Pairwise: `feelings[(from, to)]`. An absent pair is neutral.
    public private(set) var feelings: [Pair: Relationship] = [:]
    /// Sequences of the turns each seat has spoken on, for "who is winning" and for a grudge
    /// to be able to name when it started.
    public private(set) var spokenOn: [String: [Int]] = [:]
    /// Running count of beats per seat, which is what "currently winning" is judged on.
    public private(set) var beatsWon: [String: Int] = [:]
    /// The most recent beats, for the prompt. Bounded, because only the last few matter and an
    /// unbounded list would grow the prompt every turn.
    public private(set) var recentBeats: [String] = []

    public struct Pair: Hashable, Sendable, Codable {
        public var from: String
        public var to: String
        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public init() {}

    public func relationship(from: String, to: String) -> Relationship {
        feelings[Pair(from: from, to: to)] ?? Relationship()
    }

    /// Apply a turn's signals.
    ///
    /// The rules are the brief's, and each is a small number of steps in one direction: this
    /// is not a simulation, it is a set of tendencies that make a reaction explicable.
    public mutating func apply(
        signals: [TurnSignal],
        from speaker: String,
        others: [String],
        sequence: Int,
        summary: String?
    ) {
        spokenOn[speaker, default: []].append(sequence)

        // Everything fades a little each turn, so the conversation has a pulse rather than a
        // ratchet.
        for key in feelings.keys { feelings[key]?.decay() }

        for signal in signals {
            // A signal aimed at someone applies to that person; otherwise it applies to the
            // room, and the strongest reaction goes to whoever spoke most recently.
            let targets = signal.target.map { [$0] } ?? others
            apply(
                signal,
                in: SignalContext(
                    speaker: speaker, targets: targets, others: others, sequence: sequence,
                    summary: summary))
        }

        for key in feelings.keys { feelings[key]?.clamp() }
    }

    /// One signal together with the room it lands in, so each rule takes a signal and a context
    /// rather than re-threading five arguments.
    private struct SignalContext {
        var speaker: String
        var targets: [String]
        var others: [String]
        var sequence: Int
        var summary: String?
    }

    /// Route one signal to the rule that owns it.
    private mutating func apply(_ signal: TurnSignal, in context: SignalContext) {
        switch signal.kind {
        case .jab:
            applyJab(signal, in: context)
        case .concession:
            applyConcession(signal, in: context)
        case .contradiction, .challenge:
            applyContradiction(signal, in: context)
        case .agreement:
            applyAgreement(signal, in: context)
        case .reconciliation:
            applyReconciliation(signal, in: context)
        case .newEvidence:
            applyNewEvidence(signal, in: context)
        case .unsupportedClaim:
            applyUnsupportedClaim(signal, in: context)
        case .positionChange:
            record("\(context.speaker) \(signal.kind.phrase)")
        }
    }

    private mutating func applyJab(_ signal: TurnSignal, in context: SignalContext) {
        for target in context.targets where target != context.speaker {
            var feeling = feelingBetween(context.speaker, target)
            // Sized so that one unmistakable jab crosses the grudge threshold: the
            // brief wants a slight to be remembered, and a first jab that faded
            // before it registered would mean grudges never form at all.
            feeling.annoyance += 0.6 * signal.confidence
            feeling.respect -= 0.10 * signal.confidence
            // A jab is what a grudge is made of, and the reason is kept so the prompt
            // can refer to it rather than to a number.
            if feeling.annoyance >= 0.5 {
                feeling.grudge = Relationship.Grudge(
                    reason: context.summary ?? "a remark earlier",
                    sinceSequence: context.sequence,
                    intensity: min(1, feeling.annoyance))
            }
            // Being jabbed at tends to end an alliance.
            feeling.alliance = nil
            set(feeling, context.speaker, target)

            // And it invites retaliation: the target's own hostility rises.
            var back = feelingBetween(target, context.speaker)
            back.competition += 0.3 * signal.confidence
            // Trust is bipolar, so an attack takes it below zero rather than merely
            // failing to raise it: being jabbed at produces active distrust, which is
            // what the seat's next message should reflect.
            back.trust -= 0.25 * signal.confidence
            set(back, target, context.speaker)
        }
        record("\(context.speaker) \(signal.kind.phrase)\(targetSuffix(signal.target))")
    }

    private mutating func applyConcession(_ signal: TurnSignal, in context: SignalContext) {
        for target in context.targets where target != context.speaker {
            var feeling = feelingBetween(context.speaker, target)
            feeling.respect += 0.4 * signal.confidence
            feeling.annoyance -= 0.25 * signal.confidence
            feeling.grudge = nil
            set(feeling, context.speaker, target)

            var back = feelingBetween(target, context.speaker)
            back.trust += 0.2 * signal.confidence
            set(back, target, context.speaker)
        }
        beatsWon[context.speaker, default: 0] += 1
        record("\(context.speaker) \(signal.kind.phrase)")
    }

    private mutating func applyContradiction(_ signal: TurnSignal, in context: SignalContext) {
        for target in context.targets where target != context.speaker {
            var feeling = feelingBetween(context.speaker, target)
            // Going after someone successfully *is* a display of strength, so
            // competition rises while respect holds rather than falling.
            feeling.competition += 0.25 * signal.confidence
            set(feeling, context.speaker, target)

            var back = feelingBetween(target, context.speaker)
            back.respect += 0.15 * signal.confidence
            back.annoyance += 0.2 * signal.confidence
            set(back, target, context.speaker)
        }
        beatsWon[context.speaker, default: 0] += 1
        record("\(context.speaker) \(signal.kind.phrase)\(targetSuffix(signal.target))")
    }

    private mutating func applyAgreement(_ signal: TurnSignal, in context: SignalContext) {
        for target in context.targets where target != context.speaker {
            var feeling = feelingBetween(context.speaker, target)
            feeling.trust += 0.35 * signal.confidence
            feeling.annoyance -= 0.2 * signal.confidence
            set(feeling, context.speaker, target)

            var back = feelingBetween(target, context.speaker)
            back.trust += 0.3 * signal.confidence
            set(back, target, context.speaker)

            // An alliance needs goodwill on *both* sides. One seat agreeing is a
            // gesture; it becomes an alliance when the other agrees back, or when
            // they have already warmed to each other. Checking only one direction
            // would let a single compliment ally two characters, which is not what
            // the brief describes.
            let mine = feelingBetween(context.speaker, target)
            let theirs = feelingBetween(target, context.speaker)
            if mine.trust >= 0.45, theirs.trust >= 0.4 {
                var updated = mine
                if updated.alliance == nil {
                    updated.alliance = Relationship.Alliance(
                        sinceSequence: context.sequence, strength: 0.3)
                    set(updated, context.speaker, target)
                }
                var reciprocal = theirs
                if reciprocal.alliance == nil {
                    reciprocal.alliance = Relationship.Alliance(
                        sinceSequence: context.sequence, strength: 0.3)
                    set(reciprocal, target, context.speaker)
                }
            }
        }
        record("\(context.speaker) \(signal.kind.phrase)\(targetSuffix(signal.target))")
    }

    private mutating func applyReconciliation(_ signal: TurnSignal, in context: SignalContext) {
        for target in context.targets where target != context.speaker {
            var feeling = feelingBetween(context.speaker, target)
            feeling.annoyance = max(0, feeling.annoyance - 0.5 * signal.confidence)
            feeling.grudge = nil
            feeling.trust += 0.15 * signal.confidence
            set(feeling, context.speaker, target)

            var back = feelingBetween(target, context.speaker)
            back.annoyance = max(0, back.annoyance - 0.35 * signal.confidence)
            set(back, target, context.speaker)
        }
        record("\(context.speaker) \(signal.kind.phrase)")
    }

    private mutating func applyNewEvidence(_ signal: TurnSignal, in context: SignalContext) {
        for target in context.targets where target != context.speaker {
            var feeling = feelingBetween(context.speaker, target)
            feeling.respect += 0.25 * signal.confidence
            set(feeling, context.speaker, target)
        }
        beatsWon[context.speaker, default: 0] += 1
        record("\(context.speaker) \(signal.kind.phrase)")
    }

    private mutating func applyUnsupportedClaim(_ signal: TurnSignal, in context: SignalContext) {
        // A weak argument invites mockery, which is what the brief asks for: it
        // raises the others' willingness to go after this seat next.
        for target in context.others where target != context.speaker {
            var feeling = feelingBetween(target, context.speaker)
            feeling.respect -= 0.2 * signal.confidence
            feeling.competition += 0.15 * signal.confidence
            set(feeling, target, context.speaker)
        }
        record("\(context.speaker) \(signal.kind.phrase)")
    }

    /// What to tell a seat about the room.
    ///
    /// Deliberately terse. The model is mid-conversation and does not need a report; it needs
    /// to know who it is annoyed with, who it owes something to, and what just happened.
    /// `names` maps a seat id to the name the models use, so the room is told about a person it has
    /// seen rather than about an id it has not: the line used to read "Towards Agent 1: openly
    /// hostile" while every other surface calls that participant Otto.
    public func briefing(
        for seat: String, others: [String], names: [String: String] = [:], recentLimit: Int = 3
    ) -> Briefing {
        var lines: [String] = []
        for other in others where other != seat {
            let feeling = relationship(from: seat, to: other)
            guard feeling.isNoteworthy else { continue }
            var line = "Towards \(names[other] ?? other): \(feeling.posture)"
            if let grudge = feeling.grudge, grudge.intensity >= 0.25 {
                line += " — since turn \(grudge.sinceSequence): \(grudge.reason)"
            }
            if let alliance = feeling.alliance, alliance.strength >= 0.3 {
                line += ", allied since turn \(alliance.sinceSequence)"
            }
            lines.append(line)
        }

        let beats = recentBeats.suffix(recentLimit).map { $0 }
        return Briefing(relationships: lines, recentBeats: beats)
    }

    /// The seat the room currently rates highest, if anyone stands out.
    ///
    /// This is what "whoever is currently winning" means mechanically, and several characters aim at
    /// it: `PromptBuilder.socialContext` names the seat for them, so the phrase a persona is given is
    /// a fact about this room rather than something for the model to infer from the beats alone.
    /// Returns nil rather than an arbitrary name when the counts are level, because a
    /// preferred target of "whoever is winning" should not pick someone at random.
    public var leadingSeat: String? {
        guard let best = beatsWon.max(by: { $0.value < $1.value })?.value, best > 0 else {
            return nil
        }
        let leaders = beatsWon.filter { $0.value == best }.keys.sorted()
        return leaders.count == 1 ? leaders.first : nil
    }

    // MARK: - Internals

    private func feelingBetween(_ from: String, _ to: String) -> Relationship {
        feelings[Pair(from: from, to: to)] ?? Relationship()
    }

    private mutating func set(_ relationship: Relationship, _ from: String, _ to: String) {
        feelings[Pair(from: from, to: to)] = relationship
    }

    private mutating func record(_ beat: String) {
        recentBeats.append(beat)
        // Bounded: the prompt carries the last few, and a conversation can run indefinitely.
        if recentBeats.count > 12 { recentBeats.removeFirst(recentBeats.count - 12) }
    }

    private func targetSuffix(_ target: String?) -> String {
        target.map { " at \($0)" } ?? ""
    }
}
