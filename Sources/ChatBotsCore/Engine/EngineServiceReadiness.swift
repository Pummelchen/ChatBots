// ChatBotsCore — what the engine behind the listener can actually serve
//
// Split out of `EngineService.swift`, which had reached its line budget. It is one
// responsibility: the answer `/api/health` is built from, kept beside the state the same
// service publishes rather than among the dispatch.

import Foundation

extension EngineService {

    /// What this engine can serve right now.
    ///
    /// The finding was that `/api/health` answered an unconditional 200 with a hardcoded `"ok"`, so a
    /// client could not tell a listening engine from one that can serve, while the readiness signal
    /// that existed — `seatCount` — was read by nobody. This is the one definition the
    /// endpoint's status code and its body are both built from.
    ///
    /// A seat count on its own cannot answer the question: `ConversationEngine` traps on an empty
    /// roster, so the count is never zero and the number proved nothing. What can answer it is whether
    /// the seats' models loaded. Weights load when a conversation starts rather than at launch, so a
    /// seat that failed carries the reason from then on, and an engine whose every seat failed cannot
    /// serve a turn however healthy the port looks.
    ///
    /// What this deliberately does not claim: that the room is running or paused (`status` in the
    /// snapshot says that), or that a seat which has never been asked to load is ready — before the
    /// first start there is nothing to report, and silence is not failure.
    public struct Readiness: Sendable, Equatable {
        public var isReady: Bool
        /// How many seats the engine has.
        public var seats: Int
        /// The seats whose model could not be loaded, and why, by seat id.
        public var failedSeats: [String: String]
        /// Why the engine cannot serve a conversation, in a sentence a person can act on. Nil when it
        /// can — including when only some seats failed, which is degradation rather than an outage
        /// and is what `failedSeats` is for.
        public var reason: String?
    }

    /// What this engine can serve right now. See `Readiness`.
    public var readiness: Readiness {
        let seats = seatCount
        guard seats > 0 else {
            // Unreachable through `ConversationEngine`, which requires a seat. Kept so the answer is
            // total rather than relying on a trap somewhere else, and because a service is given its
            // engine rather than building it.
            return Readiness(
                isReady: false, seats: 0, failedSeats: [:],
                reason: "the engine has no seats, so there is nobody to speak")
        }
        let failed = engine.modelLoadFailures
        return Readiness(
            isReady: failed.count < seats,
            seats: seats,
            failedSeats: failed,
            reason: failed.count >= seats ? "no seat could load its model" : nil)
    }
}
