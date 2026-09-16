// ChatBotsCore — what the interface shows about an engine
//
// Split out of `MLXEngine.swift`, which held the engine, its sampling settings, its text assembler and
// its supporting actors in one 942-line file. The types did not change.

import Foundation

public enum EngineState: Sendable, Equatable {
    case idle
    case loading(progress: Double)
    case ready
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Sampling and budget for one generation turn, resolved in a single place.
///
/// The bug this closes was a `compact` that built an overridden spec and handed it to
/// a `generate` which re-read the seat's own `spec`, so the digest ran with the seat's full
/// answer cap and live thinking level and the override was silently dead. Every setting the
/// model is configured with now comes through here, and `generateExclusively` reads nothing
/// else, so an override cannot be dropped on the floor again.
