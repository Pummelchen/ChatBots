// ChatBotsCore — prompt assembly
//
// Design note: the moderator asked for exactly one rule set — a topic and a short
// introduction — and nothing else. So this file deliberately contains no debate
// choreography, no "ask a question then wait" scaffolding and no persona theatre.
// It only does three jobs:
//
//   1. render the fixed introduction ("you are N different LLMs discussing X"),
//   2. label who said what, so each model can tell itself from its counterpart,
//   3. state the one mechanical fact a model cannot infer: that its reply is posted
//      to the others verbatim, so it should answer the discussion rather than an
//      imaginary user.

import Foundation

public enum PromptBuilder {

    // MARK: - Introduction

    /// The shared opening brief. Shown in both panes and sent to both models.
    public static func introduction(specs: [AgentSpec], topic: String) -> String {
        let roster = specs
            .map { "- \($0.id): \($0.displayName) — \($0.modelShortName)" }
            .joined(separator: "\n")

        return """
        This is an open discussion between \(specs.count) different LLMs about the topic below.

        Topic:
        \(topic)

        Participants:
        \(roster)

        Rules: there are none beyond the topic. No one is a user and no one is an \
        assistant; every message is posted to the shared log and every participant reads \
        all of it. Reply to the discussion itself — agree, disagree, build on or challenge \
        whatever was said last — and say what you actually think. Keep each contribution \
        focused rather than exhaustive.

        A human moderator may interject at any time. Messages marked [Moderator] come from \
        the human and override everything else. \(searchRule(count: specs.count))
        """
    }

    private static func searchRule(count: Int) -> String {
        """
        You have web search tools: prefer them over guessing when a claim is checkable. \
        Never invent a source or a URL.
        """
    }

    // MARK: - Per-seat system message

    /// The system message for one seat. Identical for every turn so the prompt prefix
    /// stays stable (and cacheable); the seat's own identity is the only difference.
    public static func systemMessage(for spec: AgentSpec, others: [AgentSpec], topic: String) -> String {
        let counterpart = others
            .filter { $0.id != spec.id }
            .map { "\($0.id) (\($0.modelShortName))" }
            .joined(separator: ", ")

        var text = """
        You are \(spec.id) — \(spec.displayName), running \(spec.modelShortName) locally on the \
        moderator's Mac.

        You are one participant in an open, continuing discussion about:
        \(topic)

        \(counterpart.isEmpty ? "You are the only participant." : "The other participant(s): \(counterpart).")

        Everything below with a speaker tag in square brackets is either the moderator or \
        another model. Your own earlier messages are tagged with your own name; do not \
        repeat them, and do not treat them as someone else's argument.

        The moderator is a human reading along, not necessarily a participant. You are being \
        watched, not served: there is no request to satisfy and no need to summarise, \
        conclude or offer next steps unless the discussion genuinely calls for it.

        Write your message as direct speech to the group. Do not prefix it with your own \
        name tag — the app adds that.
        """

        if !spec.persona.isEmpty {
            text += "\n\n" + spec.persona
        }
        return text
    }

    // MARK: - Turn construction

    /// The speaker tag that goes in front of every logged message.
    public static func tag(for turn: Turn) -> String {
        switch turn.kind {
        case .topic:
            return "[Moderator — topic]"
        case .steering:
            return "[Moderator]"
        case .introduction:
            return "[System]"
        case .tool:
            return "[Tool result for \(turn.speakerName)]"
        case .chat:
            return "[\(turn.speakerName)]"
        }
    }

    /// Tagged body of one logged turn.
    public static func body(for turn: Turn) -> String {
        "\(tag(for: turn))\n\(turn.content)"
    }

    /// The full prompt for one seat's next turn.
    ///
    /// Every turn is rebuilt from the shared log rather than appended to a private
    /// transcript. That costs a prompt prefill per turn but guarantees both seats read
    /// the *same* history, including moderator interjections, and makes re-running a
    /// seat after a stop trivially correct.
    public static func prompt(
        for spec: AgentSpec,
        others: [AgentSpec],
        conversation: Conversation,
        steering: [Turn] = []
    ) -> [PromptMessage] {
        var messages: [PromptMessage] = [
            .init(
                role: .system,
                content: systemMessage(for: spec, others: others, topic: conversation.topic)
            )
        ]

        // One user message carrying the entire shared log. Folding history into a single
        // user turn keeps the role sequence valid for strict chat templates (user /
        // assistant alternation) while still showing every speaker tag.
        var log = conversation.dialogueTurns
            .filter { $0.kind == .topic || $0.kind == .introduction || $0.kind == .chat || $0.kind == .steering }
            .map { body(for: $0) }
            .joined(separator: "\n\n")

        if !steering.isEmpty {
            // Steering typed while the previous turn was generating: it belongs *after*
            // that turn, so it is appended here rather than lost or duplicated.
            let extra = steering.map { body(for: $0) }.joined(separator: "\n\n")
            log += (log.isEmpty ? "" : "\n\n") + extra
        }

        let ask = """
        \(log)

        [It is your turn — \(spec.id)]
        Post your next message to the group.
        """

        messages.append(.init(role: .user, content: ask))
        return messages
    }

    /// Rough token estimate (≈4 chars/token) used to warn before the context fills up.
    public static func estimatedTokens(of messages: [PromptMessage]) -> Int {
        messages.reduce(0) { $0 + max(1, $1.content.count / 4) }
    }
}
