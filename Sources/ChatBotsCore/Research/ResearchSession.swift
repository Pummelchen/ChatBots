// ChatBotsCore — when a research session stops, and what it produces
//
// The two modes differ in more than tone: an entertainment conversation is endless by design,
// while a research session **has to stop**. A report that never arrives is not a research
// session, it is an unbounded argument, and the brief is explicit that this mode exists to
// produce something a professional can act on.
//
// So this file holds two things: the conditions under which the investigation is finished,
// and the shape of the report it finishes with.
//
// The stopping rule is deliberately *not* "the conversation ran out". It is:
//
//   · a hard budget — duration, rounds, or searches — whichever is reached first, and
//   · an early finish when the analysts agree, nothing new is being added, or the remaining
//     disagreement is the kind that more discussion cannot settle.
//
// The second half matters more. A session that spends its whole budget restating settled
// findings has wasted the moderator's time, and a session that stops early because everyone
// agreed is doing exactly what was asked.

import Foundation

/// A budget for one research session.
public struct ResearchBudget: Sendable, Hashable, Codable {
    /// Wall-clock ceiling for the whole session.
    public var maxDuration: TimeInterval
    /// Ceiling on contributions from the analysts.
    public var maxRounds: Int
    /// Ceiling on web searches, so a session cannot run up a bill or a tab explosion.
    public var maxSearches: Int
    /// How hard the analysts are asked to look before concluding.
    public var depth: Depth

    public enum Depth: String, Sendable, Codable, CaseIterable, Identifiable {
        case quick
        case standard
        case deep

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .quick: "Quick"
            case .standard: "Standard"
            case .deep: "Deep"
            }
        }

        /// How long the session is meant to run, in the moderator's terms.
        public var summary: String {
            switch self {
            case .quick: "5–10 minutes"
            case .standard: "20–30 minutes"
            case .deep: "45–60 minutes"
            }
        }
    }

    public init(
        maxDuration: TimeInterval, maxRounds: Int, maxSearches: Int, depth: Depth
    ) {
        self.maxDuration = maxDuration
        self.maxRounds = maxRounds
        self.maxSearches = maxSearches
        self.depth = depth
    }

    /// The presets the brief asks for.
    public static func preset(_ depth: Depth) -> ResearchBudget {
        switch depth {
        // The round counts assume roughly a minute a turn on a local model, which is the
        // honest way to translate "5–10 minutes" into a budget when generation speed varies.
        case .quick: ResearchBudget(maxDuration: 600, maxRounds: 8, maxSearches: 6, depth: .quick)
        case .standard: ResearchBudget(maxDuration: 1_800, maxRounds: 20, maxSearches: 20, depth: .standard)
        case .deep: ResearchBudget(maxDuration: 3_600, maxRounds: 40, maxSearches: 50, depth: .deep)
        }
    }

    /// A custom duration, with the rest of the budget scaled to match.
    public static func custom(minutes: Int) -> ResearchBudget {
        let seconds = TimeInterval(max(1, minutes) * 60)
        // Roughly one contribution every 90 seconds, and a search every 60, which keeps the
        // three limits from disagreeing wildly when the moderator sets their own time.
        return ResearchBudget(
            maxDuration: seconds,
            maxRounds: max(2, Int(seconds / 90)),
            maxSearches: max(2, Int(seconds / 60)),
            depth: seconds >= 2_700 ? .deep : seconds >= 1_200 ? .standard : .quick)
    }
}

/// Why a session stopped.
public enum ResearchStop: String, Sendable, Hashable, Codable {
    case running
    case durationReached
    case roundsReached
    case searchesReached
    /// The analysts agree and nothing new is arriving.
    case converged
    /// The remaining disagreement is one more discussion cannot settle — a missing
    /// measurement, not a failure to communicate.
    case evidenceExhausted
    /// Every part of the question has been raised in a contribution that gave a basis for what
    /// it said, and nothing is left in dispute.
    ///
    /// Not derived from the counters, because it is not a fact about how much has been spent
    /// but about what has been covered: the moderator reads the transcript and finds nothing it
    /// would point the room at. Reaching this before the budget is the point of having a
    /// moderator at all — spending the remaining rounds restating findings nobody disputes is
    /// the failure the moderator exists to prevent.
    ///
    /// The wording is deliberately narrower than "answered". The reading is a phrase matcher:
    /// it can establish that a subject was raised with something behind it, not that the
    /// subject was settled, and the report should not claim more than that.
    case answered
    /// The moderator stopped it.
    case stoppedByModerator

    /// Whether a report should be produced. A session that was stopped by hand still has
    /// findings worth writing up; one that is still running does not.
    public var isFinished: Bool { self != .running }

    public var explanation: String {
        switch self {
        case .running: "The investigation is still running."
        case .durationReached: "The time budget was reached."
        case .roundsReached: "The planned number of contributions was reached."
        case .searchesReached: "The search budget was reached."
        case .converged:
            "The analysts have converged: recent contributions brought no new evidence and moved no position the app "
                + "could detect, so further discussion is not adding anything."
        case .evidenceExhausted:
            "What remains in dispute cannot be settled by more discussion — it needs evidence nobody has gathered."
        case .answered:
            "Every part of the question has been raised in a contribution that gave a basis for what it said, and "
                + "nothing remains in dispute."
        case .stoppedByModerator: "The moderator stopped the investigation."
        }
    }
}

/// Tracks a session against its budget, and decides when it is over.
///
/// A value type with an explicit `record` call rather than a timer, so the rule can be tested
/// without waiting twenty minutes and so a restored session resumes with the same accounting.
public struct ResearchSession: Sendable, Hashable, Codable {

    public var budget: ResearchBudget
    /// When the session started, so a restored one keeps its original clock.
    public var startedAt: Date
    /// Contributions from the analysts so far.
    public private(set) var rounds: Int = 0
    /// Searches performed so far.
    public private(set) var searches: Int = 0
    /// Consecutive contributions that added no new signal — the convergence detector.
    public private(set) var quietRounds: Int = 0
    /// Set when the session has been ended deliberately.
    public private(set) var stop: ResearchStop = .running

    public init(budget: ResearchBudget, startedAt: Date = Date.now) {
        self.budget = budget
        self.startedAt = startedAt
    }

    public static func newSession(_ depth: ResearchBudget.Depth, at date: Date = Date.now) -> ResearchSession {
        ResearchSession(budget: .preset(depth), startedAt: date)
    }

    public func elapsed(at now: Date) -> TimeInterval { now.timeIntervalSince(startedAt) }

    public func remaining(at now: Date = Date.now) -> TimeInterval {
        max(0, budget.maxDuration - elapsed(at: now))
    }

    /// Record one contribution.
    ///
    /// `addedSomething` is whether the turn brought a new beat — new evidence, a challenge
    /// answered, a position changed. A run of contributions that add nothing is the signal
    /// that the discussion has stopped being productive, which is a better cue to stop than a
    /// clock: it means the analysts have run out of things to say rather than out of time.
    public mutating func record(searchCount: Int = 0, addedSomething: Bool = false, at now: Date = Date.now) {
        guard stop == .running else { return }
        rounds += 1
        searches += searchCount
        quietRounds = addedSomething ? 0 : quietRounds + 1
        stop = evaluate(at: now)
    }

    /// End the session by hand.
    public mutating func stopByModerator() { finish(.stoppedByModerator) }

    /// End the session for a reason the counters cannot see.
    ///
    /// A latch rather than a returned value, so the reason survives to the report: "the
    /// moderator found nothing left to ask" has to reach the reader, and a stop that is only
    /// computed at the moment of checking would be lost by the next turn.
    public mutating func finish(_ reason: ResearchStop) {
        guard stop == .running, reason != .running else { return }
        stop = reason
    }

    /// Whether the session is over, checking the clock as well as the counters.
    ///
    /// The duration is re-checked rather than latched because a session can sit idle between
    /// turns — a slow model, a paused engine — and the time budget is wall-clock, not
    /// thinking time.
    public func isFinished(at now: Date = Date.now) -> Bool {
        stop.isFinished || evaluate(at: now).isFinished
    }

    /// The stopping rule.
    ///
    /// Ordered by how conclusive each reason is: an exhausted evidence base is a better story
    /// to tell the moderator than "the clock ran out", so it is checked first.
    public func evaluate(at now: Date = Date.now) -> ResearchStop {
        if stop != .running { return stop }
        // Convergence first: stopping because the work is done reads better than stopping
        // because a timer expired, and it is what the moderator actually wants to know.
        if quietRounds >= convergenceThreshold { return .converged }
        if elapsed(at: now) >= budget.maxDuration { return .durationReached }
        if rounds >= budget.maxRounds { return .roundsReached }
        if searches >= budget.maxSearches { return .searchesReached }
        return .running
    }

    /// How many contributions with nothing new before the session is called converged.
    ///
    /// Scaled to the budget: a quick session should give up sooner than a deep one, and three
    /// quiet turns in a five-minute session is a stronger signal than three in an hour.
    public var convergenceThreshold: Int {
        switch budget.depth {
        case .quick: 2
        case .standard: 3
        case .deep: 4
        }
    }

    /// A line for the log or the interface.
    public func statusLine(at now: Date = Date.now) -> String {
        let reason = evaluate(at: now)
        guard reason == .running else { return "Finished — \(reason.explanation)" }
        let minutes = Int(remaining(at: now) / 60)
        return "Round \(rounds)/\(budget.maxRounds) · \(minutes) min left · \(searches)/\(budget.maxSearches) searches"
    }
}
