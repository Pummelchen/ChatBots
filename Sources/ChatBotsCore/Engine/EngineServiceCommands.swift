// ChatBotsCore — the compound commands that configure the room
//
// Split out of `EngineService.swift`, which held the state, the dispatch, the room-configuring
// commands, the attachment pipeline and the snapshot in one file. A line-up or a scenario is one
// command because its parts only make sense together; what lives here is turning a name or a draw
// into the set of engine changes that command means, and saying out loud what was applied.

import Foundation

extension EngineService {

    /// Put a named line-up, or a draw, into the seats.
    ///
    /// Refused once the conversation has started, for the same reason the topic is: who is in
    /// the room is a decision about the conversation, and a seat that changed character
    /// mid-argument would make the earlier turns read as though someone else had said them.
    ///
    /// A draw reports its seed. Without that the line-up is a one-off — nobody can reproduce it,
    /// nobody can suggest it to somebody else, and a kept conversation cannot be continued with
    /// the same room.
    ///
    /// Internal rather than private: `handle(_:)` dispatches to it from `EngineService.swift`.
    func applyRoster(id: String, seed: UInt64) -> EngineReply {
        guard !engine.isRunning else {
            return .refused("who is in the room cannot be changed once the conversation has started")
        }

        let mode = engine.specs.first?.mode ?? .entertainment
        let personaIDs: [String]
        let described: String
        if id == RosterLibrary.randomID {
            let draw = RosterLibrary.draw(mode: mode, seats: engine.specs.count, seed: seed)
            personaIDs = draw.personaIDs
            described = "a random line-up (seed \(draw.seed))"
        } else if let roster = RosterLibrary.roster(id: id, mode: mode) {
            personaIDs = roster.personaIDs
            described = roster.name
        } else {
            return .refused("no line-up called \(id) in this mode")
        }

        guard !personaIDs.isEmpty else {
            return .refused("that line-up has nobody in it")
        }

        var names: [String] = []
        for (index, personaID) in personaIDs.enumerated() {
            guard index < engine.specs.count else { break }
            var spec = engine.specs[index]
            spec.personaID = personaID
            engine.updateSeat(spec)
            names.append(PersonaCatalog.style(id: personaID, mode: mode, seatIndex: index).name)
        }
        // Said out loud, because a draw nobody can see is a draw nobody can repeat. And when
        // the room is smaller than the line-up, said out loud that people were left out: a log
        // reading "The starting line-up — Research Moderator, Economist" looks like a two-person
        // line-up rather than a four-person one in a two-seat room.
        var line = "Line-up: \(described) — \(names.joined(separator: ", "))."
        if personaIDs.count > names.count {
            line += " The room holds \(engine.specs.count), so "
            line += "\(personaIDs.count - names.count) of the \(personaIDs.count) were left out."
        }
        engine.note(line)
        return .state(snapshot())
    }

    /// Everything a scenario changes, in one command.
    ///
    /// One command rather than four, because the parts only make sense together: setting the
    /// question without the panel, or the panel without the budget, would leave a session
    /// someone has to finish by hand — and a half-applied scenario is worse than none, since the
    /// user cannot tell which half took.
    ///
    /// Internal rather than private: `handle(_:)` dispatches to it from `EngineService.swift`.
    func applyScenario(id: String) -> EngineReply {
        guard !engine.isRunning else {
            return .refused("a scenario cannot be applied once the conversation has started")
        }
        guard let scenario = ScenarioLibrary.scenario(id: id) else {
            return .refused("no scenario called \(id)")
        }

        guard engine.setMode(scenario.mode) else {
            return .refused("the mode cannot be changed once the conversation has started")
        }
        guard engine.setTopic(scenario.topic) else {
            return .refused("the topic cannot be changed once the conversation has started")
        }
        if let depth = scenario.depth {
            // A refusal here is not fatal to the scenario: the question and the panel are the
            // substance, and the budget defaults to the mode's preset.
            _ = engine.setResearchBudget(depth)
        }

        var applied = "Scenario: \(scenario.topic)"
        if let rosterID = scenario.rosterID {
            let roster = applyRoster(id: rosterID, seed: RosterLibrary.freshSeed())
            if let reason = roster.refusal {
                engine.note("The scenario's panel could not be applied: \(reason)")
            } else {
                applied += " — with \(RosterLibrary.roster(id: rosterID, mode: scenario.mode)?.name ?? rosterID)"
            }
        }
        engine.note(applied + ". \(scenario.note)")
        return .state(snapshot())
    }
}
