// ChatBotsCoreTests — the seats and turns the moderator tests build their cases from.
//
// Shared by `ResearchReadingTests` and `ResearchDirectorDecisionTests`, which used to share a private
// copy each inside one 805-line file.

import ChatBotsCore

func analyst(_ id: String, role: String, name: String? = nil, mode: DiscussionMode = .research) -> AgentSpec {
    var spec = AgentSpec.makeSeats(count: 1)[0]
    spec.id = id
    spec.personaID = role
    spec.displayName = name ?? id
    spec.mode = mode
    return spec
}

func line(_ sequence: Int, from seatID: String, _ text: String) -> Turn {
    Turn(sequence: sequence, speakerID: seatID, speakerName: seatID, kind: .chat, content: text)
}
