// ChatBotsCore — the entertainment persona library
//
// Social characters, not analytical roles. The point of this file is that a character is a
// set of *traits* rather than a paragraph of prose: the directive handed to the model is
// generated from the numbers, so the same archetype can be varied without maintaining a
// separate prompt for every combination. `Alpha + intellectual + sarcastic` and
// `Alpha + flirtatious + charismatic` are two different characters made from one archetype.
//
// That also makes the behaviour testable. Whether "The Villain" provokes anyone is a
// judgement call, but whether its aggression is higher than "The Peacemaker"'s is not.
//
// These are archetypes, not impersonations: no character names a real person or imitates
// one, and character framing shapes tone rather than attempting to override a model's own
// judgement about what it will say.

import Foundation

/// How strongly a trait applies. Kept coarse on purpose — a 1–5 dial is easy to reason
/// about and to test, where a continuous value invites false precision.
public enum Intensity: Int, Sendable, Codable, CaseIterable, Comparable {
    case veryLow = 1
    case low = 2
    case moderate = 3
    case high = 4
    case veryHigh = 5

    public static func < (lhs: Intensity, rhs: Intensity) -> Bool { lhs.rawValue < rhs.rawValue }

    /// A word for the directive, so the generated prose reads naturally.
    var word: String {
        switch self {
        case .veryLow: "not at all"
        case .low: "mildly"
        case .moderate: "moderately"
        case .high: "strongly"
        case .veryHigh: "extremely"
        }
    }

    /// The same scale as a noun, for "what drives them" phrasing.
    var noun: String {
        switch self {
        case .veryLow: "almost none"
        case .low: "a little"
        case .moderate: "a fair amount of"
        case .high: "a great deal of"
        case .veryHigh: "an overwhelming amount of"
        }
    }
}

/// Who a character tends to aim at.
public enum PreferredTarget: String, Sendable, Codable, CaseIterable {
    case strongest = "whoever is currently winning"
    case weakest = "whoever is struggling"
    case loudest = "whoever is talking the most"
    case anyone = "whoever last spoke"
    case theLeader = "whoever seems in charge"
    case theContrarian = "whoever disagrees most"

    var phrase: String { rawValue }
}

/// What reliably sets a character off.
public enum ConflictTrigger: String, Sendable, Codable, CaseIterable {
    case beingIgnored
    case beingContradicted
    case beingMocked
    case beingOutdone
    case beingPatronised
    case smugness
    case vagueness
    case weakEvidence
    case hypocrisy
    case changingTheSubject

    var phrase: String {
        switch self {
        case .beingIgnored: "being ignored"
        case .beingContradicted: "being contradicted flatly"
        case .beingMocked: "being mocked"
        case .beingOutdone: "someone else getting credit"
        case .beingPatronised: "being talked down to"
        case .smugness: "smugness"
        case .vagueness: "vague hand-waving in place of a real answer"
        case .weakEvidence: "a claim with nothing behind it"
        case .hypocrisy: "being held to their own standard"
        case .changingTheSubject: "someone dodging a question"
        }
    }
}

/// A performer in the entertainment mode.
///
/// The properties are the ones a director would actually tune: how much room this character
/// takes, how easily they escalate, how funny they are about it, and how likely they are to
/// back down.
public struct SocialCharacter: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let emoji: String
    /// The group this archetype belongs to, for the picker.
    public let group: Group
    public let summary: String

    // Temperament
    public var dominance: Intensity
    public var ego: Intensity
    public var aggression: Intensity
    public var sarcasm: Intensity
    public var humor: Intensity
    public var empathy: Intensity
    public var competitiveness: Intensity
    public var skepticism: Intensity
    public var openness: Intensity
    /// Appetite for a fight they might lose.
    public var riskTolerance: Intensity
    /// How much they care what the room thinks.
    public var conformity: Intensity
    public var socialAwareness: Intensity
    /// How sharp the jabs get. Kept below the top of the scale for everyone unless the
    /// character is genuinely built for it.
    public var insultIntensity: Intensity
    /// How often they go after someone rather than just answering.
    public var challengeRate: Intensity
    /// What it takes to make them admit they were wrong.
    public var concessionThreshold: Intensity
    /// Whether they carry a grudge across the whole conversation.
    public var memoryOfSlights: Intensity

    // Conduct
    public var speechStyle: String
    public var debateStyle: String
    public var preferredTarget: PreferredTarget
    public var conflictTriggers: [ConflictTrigger]
    /// How readily they take a side with someone.
    public var allianceTendency: Intensity
    /// How readily they make up afterwards.
    public var reconciliationTendency: Intensity

    public enum Group: String, Sendable, Codable, CaseIterable, Identifiable {
        case conflict = "Conflict & drama"
        case relationships = "Relationships"
        case intellectual = "Intellectual"
        case humor = "Humour"
        case ambition = "Competition & ambition"

        public var id: String { rawValue }
    }

    public init(
        id: String,
        name: String,
        emoji: String,
        group: Group,
        summary: String,
        dominance: Intensity,
        ego: Intensity,
        aggression: Intensity,
        sarcasm: Intensity,
        humor: Intensity,
        empathy: Intensity,
        competitiveness: Intensity,
        skepticism: Intensity,
        openness: Intensity,
        riskTolerance: Intensity,
        conformity: Intensity,
        socialAwareness: Intensity,
        insultIntensity: Intensity,
        challengeRate: Intensity,
        concessionThreshold: Intensity,
        memoryOfSlights: Intensity,
        speechStyle: String,
        debateStyle: String,
        preferredTarget: PreferredTarget,
        conflictTriggers: [ConflictTrigger],
        allianceTendency: Intensity,
        reconciliationTendency: Intensity
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.group = group
        self.summary = summary
        self.dominance = dominance
        self.ego = ego
        self.aggression = aggression
        self.sarcasm = sarcasm
        self.humor = humor
        self.empathy = empathy
        self.competitiveness = competitiveness
        self.skepticism = skepticism
        self.openness = openness
        self.riskTolerance = riskTolerance
        self.conformity = conformity
        self.socialAwareness = socialAwareness
        self.insultIntensity = insultIntensity
        self.challengeRate = challengeRate
        self.concessionThreshold = concessionThreshold
        self.memoryOfSlights = memoryOfSlights
        self.speechStyle = speechStyle
        self.debateStyle = debateStyle
        self.preferredTarget = preferredTarget
        self.conflictTriggers = conflictTriggers
        self.allianceTendency = allianceTendency
        self.reconciliationTendency = reconciliationTendency
    }

    /// A copy with traits overridden, which is how the combinatorial characters work.
    ///
    /// `Alpha + intellectual + sarcastic` is the Alpha archetype with three values changed,
    /// not a hand-written prompt.
    public func adjusted(
        dominance: Intensity? = nil,
        ego: Intensity? = nil,
        aggression: Intensity? = nil,
        sarcasm: Intensity? = nil,
        humor: Intensity? = nil,
        empathy: Intensity? = nil,
        competitiveness: Intensity? = nil,
        skepticism: Intensity? = nil,
        openness: Intensity? = nil,
        insultIntensity: Intensity? = nil,
        challengeRate: Intensity? = nil,
        concessionThreshold: Intensity? = nil,
        speechStyle: String? = nil,
        debateStyle: String? = nil
    ) -> SocialCharacter {
        var copy = self
        copy.override(dominance, \.dominance)
        copy.override(ego, \.ego)
        copy.override(aggression, \.aggression)
        copy.override(sarcasm, \.sarcasm)
        copy.override(humor, \.humor)
        copy.override(empathy, \.empathy)
        copy.override(competitiveness, \.competitiveness)
        copy.override(skepticism, \.skepticism)
        copy.override(openness, \.openness)
        copy.override(insultIntensity, \.insultIntensity)
        copy.override(challengeRate, \.challengeRate)
        copy.override(concessionThreshold, \.concessionThreshold)
        copy.override(speechStyle, \.speechStyle)
        copy.override(debateStyle, \.debateStyle)
        return copy
    }

    /// Replace one trait with the override, when one was given. Each override in `adjusted`
    /// is one call rather than one branch, so the combinatorial copy stays readable.
    private mutating func override<T>(_ value: T?, _ keyPath: WritableKeyPath<SocialCharacter, T>) {
        if let value { self[keyPath: keyPath] = value }
    }

    /// The directive handed to the model, built from the traits.
    ///
    /// Generated rather than stored so that changing a trait changes the behaviour, and so
    /// two characters with the same archetype but different traits cannot drift apart from
    /// their own descriptions.
    public var directive: String {
        var lines: [String] = []
        lines.append("\(name). \(summary)")
        lines.append("Speak like this: \(speechStyle)")
        lines.append("Argue like this: \(debateStyle)")

        // Temperament, phrased as behaviour rather than as numbers.
        var manner: [String] = []
        if dominance >= .high {
            manner.append("you take up room in a conversation and expect to be answered")
        } else if dominance <= .low {
            manner.append("you hold back and let others lead")
        }
        if ego >= .high { manner.append("your sense of your own importance is not subtle") }
        if aggression >= .high {
            manner.append("you go on the attack quickly")
        } else if aggression <= .low {
            manner.append("you rarely attack anyone directly")
        }
        if sarcasm >= .high {
            manner.append("your default register is sarcasm")
        } else if sarcasm <= .low {
            manner.append("you mean what you say and say it plainly")
        }
        if humor >= .high { manner.append("you are funny even when you are being serious") }
        if empathy >= .high {
            manner.append("you notice when someone is being treated unfairly")
        } else if empathy <= .low {
            manner.append("other people's feelings are not your problem")
        }
        if competitiveness >= .high { manner.append("you are keeping score, always") }
        if skepticism >= .high { manner.append("you assume a claim is wrong until it is shown otherwise") }
        if openness >= .high {
            manner.append("you will change your mind in public if someone earns it")
        } else if openness <= .low {
            manner.append("you do not move once you have taken a position")
        }
        if riskTolerance >= .high { manner.append("you will take a losing position for the fun of it") }
        if socialAwareness >= .high { manner.append("you read the room and play to it") }
        if !manner.isEmpty {
            lines.append("How you carry yourself: " + manner.joined(separator: "; ") + ".")
        }

        // Conduct, phrased as instructions the model can act on.
        let challenge: String
        if challengeRate >= .high {
            challenge = "go after weak points in nearly every message"
        } else if challengeRate >= .moderate {
            challenge = "press a point when it deserves it"
        } else {
            challenge = "mostly answer rather than attack"
        }
        lines.append(
            "You challenge others \(challengeRate.word) — "
                + "\(challenge)."
        )
        let setOffBy =
            conflictTriggers.isEmpty
            ? ""
            : "You are set off by " + conflictTriggers.map(\.phrase).joined(separator: ", ") + "."
        lines.append(
            "Your preferred target is \(preferredTarget.phrase). \(setOffBy)"
        )
        if insultIntensity >= .high {
            lines.append(
                "Your jabs are sharp. Be witty and cutting rather than crude — clever insults land, crude ones do not."
            )
        } else if insultIntensity >= .moderate {
            lines.append("You tease and needle, but you are not cruel about it.")
        } else {
            lines.append("You disagree without belittling anyone.")
        }
        if memoryOfSlights >= .high {
            lines.append(
                "You remember every slight and bring old ones back up when it suits you — including from much earlier "
                    + "in this conversation."
            )
        }
        if allianceTendency >= .high {
            lines.append("You look for someone to side with, and you say so out loud when you find them.")
        }
        if reconciliationTendency >= .high {
            lines.append("When you have gone too far, you pull back and say so.")
        } else if reconciliationTendency <= .low {
            lines.append("You do not apologise and you do not back down gracefully.")
        }
        let concession: String
        if concessionThreshold >= .veryHigh {
            concession = "only overwhelming proof will move you"
        } else if concessionThreshold >= .moderate {
            concession = "a genuinely good argument will move you"
        } else {
            concession = "you give ground fairly easily when someone is right"
        }
        lines.append(
            "Conceding costs you \(concessionThreshold.noun) — "
                + "\(concession)."
        )
        return lines.joined(separator: "\n")
    }
}
