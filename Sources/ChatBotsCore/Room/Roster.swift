// ChatBotsCore — line-ups and scenarios
//
// Two things the brief asks for that are really one thing: choosing *who* is in the room, and
// choosing *what* they are put in front of. They belong together because the pairing is the
// interesting part — a panel of statisticians is the wrong room for "is a hotdog a sandwich",
// and the right one for "does the trial design support the claim".
//
// The personas themselves already existed, and a front end could already set them one seat at a
// time. What was missing is a *combination*: the analysts the brief actually ships as a line-up,
// and a random draw that is worth using because it is reproducible.
//
// **Why the random draw is seeded rather than `randomElement()`.** A line-up nobody can reproduce
// is a line-up nobody can share. With a seed, "I got the Villain, the Peacemaker and the Deadpan
// — try seed 4181" is a sentence that means something, and a conversation kept on disk can be
// continued with the same room. That is also why the seed is reported wherever a draw happens
// rather than being kept in the generator.

import Foundation

/// A named combination of participants.
public struct Roster: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    /// What the combination is for, in one line, so a picker is not a list of nouns.
    public var summary: String
    public var mode: DiscussionMode
    /// The persona identifiers, in seat order. Shorter than the number of seats means the
    /// remaining seats keep whatever they had.
    public var personaIDs: [String]

    public init(
        id: String, name: String, summary: String, mode: DiscussionMode, personaIDs: [String]
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.mode = mode
        self.personaIDs = personaIDs
    }

    public var count: Int { personaIDs.count }
}

/// The line-ups worth offering.
public enum RosterLibrary {

    /// The identifier a front end asks for when it wants a draw rather than a preset.
    public static let randomID = "random"

    public static func rosters(for mode: DiscussionMode) -> [Roster] {
        switch mode {
        case .entertainment: entertainment
        case .research: research
        }
    }

    public static func roster(id: String, mode: DiscussionMode) -> Roster? {
        rosters(for: mode).first { $0.id == id }
    }

    // MARK: Entertainment

    /// Combinations that reliably produce a conversation rather than four people agreeing.
    ///
    /// Each one is built round a different engine of conflict — a villain and someone who will
    /// not be moved, a room of people who all want the last word, a room where nobody is willing
    /// to take anything seriously — because four rosters that all work the same way would be one
    /// roster.
    private static let entertainment: [Roster] = [
        Roster(
            id: "house-party", name: "The house party",
            summary: "Three strong personalities and somebody trying to keep the peace.",
            mode: .entertainment,
            personaIDs: ["villain", "alpha", "peacemaker", "troll"]),
        Roster(
            id: "locked-room", name: "Nobody gives an inch",
            summary: "Four people who will not concede a point, on a question with no answer.",
            mode: .entertainment,
            personaIDs: ["contrarian", "hothead", "grudge", "perfectionist"]),
        Roster(
            id: "not-serious", name: "Nobody is taking this seriously",
            summary: "Comedy first. The topic is an excuse.",
            mode: .entertainment,
            personaIDs: ["comedian", "troll", "chaos", "deadpan"]),
        Roster(
            id: "inquiry", name: "The inquiry",
            summary: "People who argue from evidence, against people who argue from conviction.",
            mode: .entertainment,
            personaIDs: ["social-fact-checker", "social-skeptic", "conspiracy", "social-scientist"]),
        Roster(
            id: "scheming", name: "Everyone has an angle",
            summary: "Alliances form, shift and are betrayed within four turns.",
            mode: .entertainment,
            personaIDs: ["schemer", "manipulator", "instigator", "gossip"]),
    ]

    // MARK: Research

    /// Panels, not collections of roles: each is a set of methods that can cover a question
    /// between them, which is what the moderator needs to direct.
    private static let research: [Roster] = [
        Roster(
            id: "starting-line-up", name: "The starting line-up",
            summary: "A moderator, an economist, an investor and a skeptic.",
            mode: .research,
            personaIDs: [AnalystLibrary.moderatorID, "economist", "investor", "skeptic"]),
        Roster(
            id: "methods-panel", name: "The methods panel",
            summary: "Everything is challenged on how it was measured. Slow, and hard to argue with.",
            mode: .research,
            personaIDs: [
                AnalystLibrary.moderatorID, "methodologist", "statistician", "data-analyst",
            ]),
        Roster(
            id: "commercial-panel", name: "The commercial panel",
            summary: "What it costs, what it returns, and whether the money is there.",
            mode: .research,
            personaIDs: [AnalystLibrary.moderatorID, "economist", "cfo", "investor"]),
        Roster(
            id: "devils-advocate", name: "The adversarial panel",
            summary: "A moderator with three people whose job is to find the flaw.",
            mode: .research,
            personaIDs: [
                AnalystLibrary.moderatorID, "skeptic", "fact-checker", "methodologist",
            ]),
        Roster(
            id: "market-entry", name: "The market-entry panel",
            summary: "Demand, competitors, and whether it can actually be built.",
            mode: .research,
            personaIDs: [
                AnalystLibrary.moderatorID, "market-researcher", "competitive-intelligence",
                "technical-expert",
            ]),
    ]

    // MARK: Drawing a combination

    /// A combination drawn from the mode's library, reproducibly from a seed.
    ///
    /// No repeats: the same character twice in one room is not a combination, it is a bug in the
    /// picker. A draw larger than the library returns the whole library rather than looping —
    /// silently seating the Villain twice would be worse than seating three people.
    public static func draw(
        mode: DiscussionMode, seats: Int, seed: UInt64
    ) -> (personaIDs: [String], seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        let pool = drawPool(for: mode)
        var remaining = pool
        var chosen: [String] = []
        for _ in 0..<max(0, seats) {
            guard !remaining.isEmpty else { break }
            let index = Int(generator.next() % UInt64(remaining.count))
            chosen.append(remaining.remove(at: index))
        }
        return (chosen, seed)
    }

    /// What a draw may pick from.
    ///
    /// The shared communication styles are deliberately excluded, and the reason is the same in
    /// both modes: "Meticulous" is not a participant, it is a way of talking, and a room drawn
    /// from styles is four voices with nothing between them. A draw is for characters and
    /// analysts — people with something to want.
    private static func drawPool(for mode: DiscussionMode) -> [String] {
        switch mode {
        case .entertainment: SocialLibrary.all.map(\.id)
        case .research: AnalystLibrary.all.filter { $0.id != AnalystLibrary.moderatorID }.map(\.id)
        }
    }

    /// A seed drawn from the clock, for a caller that has not asked for a particular one.
    public static func freshSeed() -> UInt64 {
        UInt64(Date.now.timeIntervalSince1970 * 1_000) &* 6_364_136_223_846_793_005
    }
}

/// A reproducible generator, so a draw can be repeated from its seed.
///
/// SplitMix64: tiny, and — the only property that matters here — the same seed gives the same
/// sequence on every platform and every run, which is what makes a shared seed meaningful.
/// `SystemRandomNumberGenerator` would give a better distribution and no reproducibility at all.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// A question to put in front of a room, with the room it suits.
///
/// The point of a scenario rather than a topic is the pairing. "Should Company X enter the German
/// EV market?" is a different question depending on whether the panel contains an economist — and
/// the brief's "random scenario" is not a random string, it is a ready-made session.
public struct Scenario: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var mode: DiscussionMode
    public var topic: String
    /// Why it is worth running, so the picker is not a list of questions.
    public var note: String
    /// The line-up that suits it, if the library has one.
    public var rosterID: String?
    /// A budget for a research scenario. Nil takes the mode's default.
    public var depth: ResearchBudget.Depth?

    public init(
        id: String, mode: DiscussionMode, topic: String, note: String,
        rosterID: String? = nil, depth: ResearchBudget.Depth? = nil
    ) {
        self.id = id
        self.mode = mode
        self.topic = topic
        self.note = note
        self.rosterID = rosterID
        self.depth = depth
    }
}

public enum ScenarioLibrary {

    public static func scenarios(for mode: DiscussionMode) -> [Scenario] {
        switch mode {
        case .entertainment: entertainment
        case .research: research
        }
    }

    public static func scenario(id: String) -> Scenario? {
        all.first { $0.id == id }
    }

    public static let all: [Scenario] = entertainment + research

    /// A scenario drawn reproducibly, like a roster.
    public static func draw(mode: DiscussionMode, seed: UInt64) -> (scenario: Scenario, seed: UInt64)? {
        let pool = scenarios(for: mode)
        guard !pool.isEmpty else { return nil }
        var generator = SeededGenerator(seed: seed)
        let index = Int(generator.next() % UInt64(pool.count))
        return (pool[index], seed)
    }

    // MARK: Entertainment

    /// Questions with no correct answer, which is the only kind worth giving this mode. A
    /// factual question produces one right answer and three people agreeing with it.
    private static let entertainment: [Scenario] = [
        Scenario(
            id: "hotdog", mode: .entertainment, topic: "Is a hotdog a sandwich?",
            note: "Everyone has a position and nobody has evidence.",
            rosterID: "not-serious"),
        Scenario(
            id: "pineapple", mode: .entertainment, topic: "Does pineapple belong on pizza?",
            note: "The classic. Best run with people who will not let it go.",
            rosterID: "locked-room"),
        Scenario(
            id: "die-hard", mode: .entertainment, topic: "Is Die Hard a Christmas film?",
            note: "A definitional argument, so it can never be settled.",
            rosterID: "house-party"),
        Scenario(
            id: "best-decade", mode: .entertainment, topic: "Which decade had the best music?",
            note: "Unfalsifiable, personal, and reliably heated.",
            rosterID: "house-party"),
        Scenario(
            id: "cereal-soup", mode: .entertainment, topic: "Is cereal a soup?",
            note: "Tests whether anyone in the room will accept a definition.",
            rosterID: "inquiry"),
        Scenario(
            id: "worst-invention", mode: .entertainment,
            topic: "What is the worst invention of the last hundred years?",
            note: "Invites each participant to attack something the others rely on.",
            rosterID: "scheming"),
        Scenario(
            id: "time-travel", mode: .entertainment,
            topic: "If you could stop one historical event, should you?",
            note: "Pulls the argument towards consequences nobody can check.",
            rosterID: "inquiry"),
        Scenario(
            id: "superpower", mode: .entertainment,
            topic: "Which useless superpower would you actually choose?",
            note: "Low stakes, so the personalities do the work.",
            rosterID: "not-serious"),
    ]

    // MARK: Research

    /// Questions a professional would have to act on, and that a panel can actually divide
    /// between them. A question nobody can act on produces a report nobody can use.
    private static let research: [Scenario] = [
        Scenario(
            id: "ev-market", mode: .research,
            topic: "Should Company X enter the German EV market?",
            note: "The reference question: demand, economics, competition and capital.",
            rosterID: "starting-line-up", depth: .standard),
        Scenario(
            id: "four-day-week", mode: .research,
            topic: "Is a four-day week viable for a mid-sized professional services firm?",
            note: "Productivity evidence against a fixed cost base.",
            rosterID: "commercial-panel", depth: .standard),
        Scenario(
            id: "solid-state", mode: .research,
            topic: "Will solid-state batteries reach cost parity with lithium-ion by 2030?",
            note: "A forecast that turns on manufacturing yield, which nobody publishes.",
            rosterID: "methods-panel", depth: .deep),
        Scenario(
            id: "vertical-farming", mode: .research,
            topic: "Is vertical farming viable at European industrial energy prices?",
            note: "Unit economics that depend entirely on one input price.",
            rosterID: "commercial-panel", depth: .standard),
        Scenario(
            id: "ai-triage", mode: .research,
            topic: "Should a regional hospital deploy AI triage in its emergency department?",
            note: "Evidence, regulation and liability, with no clean answer.",
            rosterID: "devils-advocate", depth: .deep),
        Scenario(
            id: "onshoring", mode: .research,
            topic: "Does onshoring semiconductor capacity make strategic sense for a mid-sized economy?",
            note: "Industrial policy against capital intensity.",
            rosterID: "market-entry", depth: .deep),
        Scenario(
            id: "subscription-pivot", mode: .research,
            topic: "Should a hardware company move its flagship product to a subscription?",
            note: "Cash flow, churn and the customer's actual behaviour.",
            rosterID: "commercial-panel", depth: .standard),
        Scenario(
            id: "hiring-signal", mode: .research,
            topic: "Do technical hiring tests predict job performance?",
            note: "A question where the honest answer is that the evidence is weak.",
            rosterID: "methods-panel", depth: .quick),
    ]
}
