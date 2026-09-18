// ChatBotsCore — engine-agnostic chat domain
//
// Nothing in this file knows about MLX. The whole point is that a participant is
// "some LLM behind the `LLMEngine` protocol", so a future build can put a remote
// API, a llama.cpp server or a different MLX checkpoint in any seat.

import Foundation

// MARK: - Turn

/// A single entry in the shared, human-visible conversation.
///
/// The moderator and both agents all write into this one transcript, ordered by
/// `sequence`. Agents never receive a private copy of history, so the moderator
/// cannot accidentally bias only one participant.
public struct Turn: Identifiable, Sendable, Hashable {
    /// Where a turn came from.
    public enum Kind: String, Sendable, Hashable {
        /// The initial question written by the human.
        case topic
        /// The opening system-style brief written by the app.
        case introduction
        /// An LLM contribution.
        case chat
        /// A mid-conversation instruction typed by the human moderator.
        case steering
        /// Work assigned by the research moderator — the app's director, not the human.
        ///
        /// Its own kind because it must not read as the human speaking: the moderator typing
        /// "check the capital cost" and the director assigning that check are different acts
        /// by different authors, and a front end that showed them identically would be
        /// misreporting who asked.
        case direction
        /// A tool round-trip summary (always attached to the agent that ran it).
        case tool
        /// A model-written digest that replaced older turns to reclaim context. Authored by
        /// the app on a seat's behalf, so it carries no speaker.
        case summary
        /// The final report of a research session, written by the moderator seat. Its own
        /// kind because it is the deliverable rather than a contribution — a front end should
        /// present it differently, and it is not another message in the argument.
        case report
    }

    public let id: UUID
    /// Monotonic ordering key. `Turn` has no wall-clock dependency so replays and
    /// tests are deterministic.
    public var sequence: Int
    /// Agent id, or `nil` for human/app turns.
    public var speakerID: String?
    public var speakerName: String
    public var kind: Kind
    public var content: String
    /// Populated for `.tool` turns.
    public var toolDetail: String?
    /// The research sub-question a `.direction` turn asks the room to address *because
    /// nothing has addressed it yet*, as a `ResearchSubQuestion` raw value.
    ///
    /// Set only for that assignment, and only by the director. It matters to one rule: a
    /// subject the moderator has pointed the room at counts as covered when a single seat
    /// answers the assignment, where an ordinary mention needs two seats. The reader used to
    /// recognise the assignment by matching the instruction's exact wording, so a copy edit or
    /// a localisation silently disabled the rule; the marker makes the coupling structural.
    public var unaddressedSubject: String?
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        sequence: Int,
        speakerID: String? = nil,
        speakerName: String,
        kind: Kind,
        content: String,
        toolDetail: String? = nil,
        unaddressedSubject: String? = nil,
        timestamp: Date = Date.now
    ) {
        self.id = id
        self.sequence = sequence
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.kind = kind
        self.content = content
        self.toolDetail = toolDetail
        self.unaddressedSubject = unaddressedSubject
        self.timestamp = timestamp
    }
}

// MARK: - Conversation

/// The shared transcript plus the topic it is about.
public struct Conversation: Sendable {
    public var topic: String
    public var turns: [Turn]
    /// Source material the moderator added before the conversation started, already
    /// converted to text. Read by every seat on every turn, because it is context for the
    /// discussion rather than a message in it.
    public var attachments: [AttachedDocument]
    /// The social state an entertainment conversation has built up: who respects whom, who is
    /// annoyed with whom, what grudges and alliances are live. Persists across turns and is
    /// fed back into each seat's prompt, which is what makes a conversation develop rather
    /// than restart every message.
    public var conflict = ConflictState()
    /// The research session's budget and progress, for a research run. Nil in entertainment,
    /// where there is no budget and no end condition on purpose.
    public var research: ResearchSession?
    /// The report a finished research session produced, kept so the interface can show it and
    /// the export can include it.
    public var report: ResearchReport?
    /// The audience's verdict on individual contributions.
    ///
    /// Beside the conversation rather than in it, and deliberately: a vote is never sent to a
    /// model and never enters a prompt. Putting the audience's opinion of one seat into a
    /// shared log would let it shape another seat's next turn, which is the one thing the
    /// shared log exists to prevent.
    public var votes: [AudienceVote] = []

    public init(
        topic: String,
        turns: [Turn] = [],
        attachments: [AttachedDocument] = [],
        conflict: ConflictState = ConflictState(),
        research: ResearchSession? = nil,
        report: ResearchReport? = nil,
        votes: [AudienceVote] = []
    ) {
        self.topic = topic
        self.turns = turns
        self.attachments = attachments
        self.conflict = conflict
        self.research = research
        self.report = report
        self.votes = votes
    }

    /// The audience's votes, as a scorecard.
    public var audience: AudienceScorecard {
        get { AudienceScorecard(votes: votes) }
        set { votes = newValue.votes }
    }

    /// Turns that an LLM should actually read: history and opening brief, but not
    /// the tool chatter, which is already folded into its agent's own reply.
    public var dialogueTurns: [Turn] {
        turns.filter { $0.kind != .tool }
    }

    public var isEmpty: Bool { dialogueTurns.isEmpty }

    /// The current compaction summary, if the log has been condensed.
    public var summaryTurn: Turn? {
        turns.last { $0.kind == .summary }
    }
}

// MARK: - Reasoning headroom

extension ThinkingMode {
    /// Total tokens a model may emit for one turn: the answer budget plus this mode's
    /// reasoning headroom.
    ///
    /// The one implementation of the arithmetic, so a caller cannot get a different answer
    /// from the one the engine uses. A bounded mode adds its own ceiling. `.unlimited` has no
    /// ceiling but MLX still needs a finite cap, so it is given the model's whole context
    /// window as headroom — floored at `.high`, so choosing a higher thinking level can never
    /// *lower* the budget. The old arithmetic, `maxTokens + (reasoningTokenBudget ?? 0)`,
    /// made `.unlimited` the smallest cap of any mode.
    ///
    /// Kept here rather than on `MLXEngine` because it is arithmetic, not inference: the
    /// engine-agnostic model can answer it, and `MLXEngine.generationCap` delegates so the
    /// engine's own cap and `AgentSpec.generationCap` cannot disagree.
    public func generationCap(answerBudget: Int, contextWindow: Int?) -> Int {
        // `answerBudget` and every headroom are `Int`, and a checkpoint's own declared context
        // window is untrusted input. `MLXEngine.contextWindow(of:)` bounds that value, and this
        // clamps the addition as well, so no pair of numbers can trap the process here.
        func capped(_ headroom: Int) -> Int {
            let (sum, overflow) = answerBudget.addingReportingOverflow(headroom)
            return overflow ? Int.max : sum
        }
        if let ceiling = reasoningTokenBudget {
            return capped(ceiling)
        }
        let highHeadroom = ThinkingMode.high.reasoningTokenBudget ?? 0
        guard let contextWindow, contextWindow > 0 else { return capped(highHeadroom) }
        return capped(max(highHeadroom, contextWindow))
    }
}

// MARK: - Participant

/// Static description of one LLM seat at the table.
///
/// Sampling lives on the seat, not in the engine, so two seats can run different
/// checkpoints *and* different samplers. `QwenSampling` is the shared preset used by the
/// two default Qwen seats.
