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
        /// A tool round-trip summary (always attached to the agent that ran it).
        case tool
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
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        sequence: Int,
        speakerID: String? = nil,
        speakerName: String,
        kind: Kind,
        content: String,
        toolDetail: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.sequence = sequence
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.kind = kind
        self.content = content
        self.toolDetail = toolDetail
        self.timestamp = timestamp
    }
}

// MARK: - Conversation

/// The shared transcript plus the topic it is about.
public struct Conversation: Sendable {
    public var topic: String
    public var turns: [Turn]

    public init(topic: String, turns: [Turn] = []) {
        self.topic = topic
        self.turns = turns
    }

    /// Turns that an LLM should actually read: history and opening brief, but not
    /// the tool chatter, which is already folded into its agent's own reply.
    public var dialogueTurns: [Turn] {
        turns.filter { $0.kind != .tool }
    }

    public var isEmpty: Bool { dialogueTurns.isEmpty }
}

// MARK: - Participant

/// Static description of one LLM seat at the table.
///
/// Sampling lives on the seat, not in the engine, so two seats can run different
/// checkpoints *and* different samplers. `QwenSampling` is the shared preset used by the
/// two default Qwen seats.
public struct AgentSpec: Identifiable, Sendable, Hashable, Codable {
    /// Stable id (also the seat label used in prompts, e.g. "Agent A").
    public var id: String
    public var displayName: String
    /// Hugging Face repo id of the MLX checkpoint.
    public var modelID: String
    /// Short label shown in the UI badge.
    public var modelShortName: String
    public var temperature: Double
    public var topP: Double
    /// Keep only this many most-likely tokens. `0` disables the cut.
    public var topK: Int
    /// Drop tokens below this probability mass, relative to the best token. `0` disables.
    public var minP: Double
    /// Presence penalty, **in MLX's sign convention**: MLX *subtracts* this from a token's
    /// logit, so a negative value discourages repeating a token that has already appeared.
    /// (OpenAI's `presence_penalty` takes the same negative value in this convention; UIs
    /// such as LM Studio show it as a positive magnitude.)
    public var presencePenalty: Double?
    /// Repetition penalty, a multiplier. `1.0` is neutral; above `1` penalises, below
    /// `1` rewards.
    public var repetitionPenalty: Double?
    /// Maximum tokens to generate. When `thinkingBudget` is `0` this is the whole
    /// output budget, thinking included.
    public var maxTokens: Int
    /// Extra headroom granted for a reasoning block, on top of `maxTokens`.
    ///
    /// `0` means "`maxTokens` is the entire output budget", which is how the Qwen preset
    /// below is configured. Raising it only makes sense for a seat whose budgeting is
    /// tracked separately from its answer length.
    public var thinkingBudget: Int
    /// Whether this seat may call the web-search tools.
    public var webSearchEnabled: Bool
    /// How this seat handles a reasoning model's thinking block.
    public var reasoning: ReasoningMode
    /// Extra per-seat persona note. Deliberately short: the design goal is to watch
    /// two models run the conversation, not to script them.
    public var persona: String

    public init(
        id: String,
        displayName: String,
        modelID: String = AgentSpec.defaultModelID,
        modelShortName: String = "Qwen3.5-4B-4bit",
        temperature: Double = 0.75,
        topP: Double = 0.95,
        topK: Int = 0,
        minP: Double = 0.0,
        presencePenalty: Double? = nil,
        repetitionPenalty: Double? = nil,
        maxTokens: Int = 1024,
        thinkingBudget: Int = 0,
        webSearchEnabled: Bool = true,
        reasoning: ReasoningMode = .stream,
        persona: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.modelID = modelID
        self.modelShortName = modelShortName
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.presencePenalty = presencePenalty
        self.repetitionPenalty = repetitionPenalty
        self.maxTokens = maxTokens
        self.thinkingBudget = thinkingBudget
        self.webSearchEnabled = webSearchEnabled
        self.reasoning = reasoning
        self.persona = persona
    }

    public static let defaultModelID = "mlx-community/Qwen3.5-4B-MLX-4bit"


    /// Sampling settings shared by every Qwen seat.
    ///
    /// Declared once and applied to both seats so the two models are configured
    /// identically — the point of the experiment is to watch how they converse, not to
    /// have them differ in sampler.
    ///
    /// | Setting | Value |
    /// | --- | --- |
    /// | Thinking | on (`enable_thinking: true`) |
    /// | Temperature | 1.0 |
    /// | Top P | 0.95 |
    /// | Top K | 20 |
    /// | Min P | 0.0 |
    /// | Presence penalty | 1.5 (UI convention) → `-1.5` for MLX |
    /// | Repetition penalty | 1.0 (neutral) |
    /// | Max output tokens | 32,768 |
    public enum QwenSampling {
        public static let thinking = true
        public static let temperature = 1.0
        public static let topP = 0.95
        public static let topK = 20
        public static let minP = 0.0
        /// Displayed as 1.5 in the UI. MLX *subtracts* the value it is given, so a
        /// positive `1.5` would reward tokens already in the context — the opposite of a
        /// presence penalty. The sign is flipped here, in one place.
        public static let presencePenaltyMagnitude = 1.5
        public static let presencePenalty = -presencePenaltyMagnitude
        /// MLX multiplies by this, and `1.0` is neutral, so this is deliberately a no-op.
        public static let repetitionPenalty = 1.0
        public static let maxOutputTokens = 32_768
    }

    private static func qwen(
        id: String,
        modelID: String,
        shortName: String
    ) -> AgentSpec {
        AgentSpec(
            id: id,
            displayName: id,
            modelID: modelID,
            modelShortName: shortName,
            temperature: QwenSampling.temperature,
            topP: QwenSampling.topP,
            topK: QwenSampling.topK,
            minP: QwenSampling.minP,
            presencePenalty: QwenSampling.presencePenalty,
            repetitionPenalty: QwenSampling.repetitionPenalty,
            maxTokens: QwenSampling.maxOutputTokens,
            // `maxTokens` above is the whole output budget, thinking included.
            thinkingBudget: 0,
            reasoning: QwenSampling.thinking ? .stream : .off
        )
    }

    /// Seat A — the default opening speaker.
    public static func seatA(modelID: String = AgentSpec.defaultModelID) -> AgentSpec {
        qwen(id: "Agent A", modelID: modelID, shortName: "Qwen3.5-4B-4bit")
    }

    /// Seat B — identical settings and, by default, identical weights to seat A, but a
    /// *separate* model instance. Point `modelID` at another checkpoint to mix LLMs.
    public static func seatB(modelID: String = AgentSpec.defaultModelID) -> AgentSpec {
        qwen(id: "Agent B", modelID: modelID, shortName: "Qwen3.5-4B-4bit")
    }

    /// A separate instance of the same weights still deserves a distinct sampling
    /// seed-stream, otherwise the two seats converge on identical phrasing.
    public var samplingSeed: UInt64 {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(modelID)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

// MARK: - Events

/// Everything interesting that happens during a turn, streamed to the UI.
public enum TurnEvent: Sendable {
    /// A turn is about to begin. `prompt` is the exact message list sent to the engine.
    case turnStarted(agentID: String, prompt: [PromptMessage])
    /// Visible answer text.
    case token(agentID: String, text: String)
    /// `<think>` block text. Displayed collapsed, never fed back into history.
    case reasoning(agentID: String, text: String)
    /// The model asked for a web tool.
    case toolCall(agentID: String, name: String, query: String)
    /// Result of that tool, truncated for display.
    case toolResult(agentID: String, name: String, summary: String, detail: String)
    /// A tool failed; the model is told so and carries on.
    case toolFailure(agentID: String, name: String, message: String)
    /// The turn produced its final text.
    case turnFinished(agentID: String, text: String, stats: TurnStats)
    /// The turn ended badly; the loop decides whether to continue.
    case turnFailed(agentID: String, message: String)
}

/// Throughput information for one turn.
public struct TurnStats: Sendable, Hashable, Codable {
    public var promptTokens: Int
    public var generationTokens: Int
    public var cachedPromptTokens: Int
    public var stopReason: String
    public var tokensPerSecond: Double
    public var seconds: Double

    public init(
        promptTokens: Int = 0,
        generationTokens: Int = 0,
        cachedPromptTokens: Int = 0,
        stopReason: String = "",
        tokensPerSecond: Double = 0,
        seconds: Double = 0
    ) {
        self.promptTokens = promptTokens
        self.generationTokens = generationTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.stopReason = stopReason
        self.tokensPerSecond = tokensPerSecond
        self.seconds = seconds
    }
}

/// A message as it will be rendered by the model's chat template.
///
/// Kept as our own type rather than `Chat.Message` so the core stays independent of
/// MLX Swift and so the UI can show the moderator exactly what the model was sent.
public struct PromptMessage: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - Engine protocol

/// One LLM seat. Implementations own exactly one model instance.
///
/// Deliberately narrow: load once, then generate. Anything orchestration-related
/// (turn order, history, pausing) lives outside, so a seat can be replaced by a
/// different backend without touching the conversation logic.
public protocol LLMEngine: Sendable {
    var spec: AgentSpec { get }
    /// Load weights. Idempotent; safe to call from several tasks.
    func load() async throws
    var isLoaded: Bool { get async }
    /// The model's configured context window, in tokens.
    var contextWindow: Int { get async }
    /// Free the weights.
    func unload() async
    /// Run exactly one assistant turn.
    ///
    /// - Parameters:
    ///   - messages: full prompt, system message first.
    ///   - tools: web tools this seat may call (empty disables tool use).
    ///   - onToolCall: invoked before each dispatch, purely for display.
    ///   - onEvent: receives every visible/reasoning fragment as it is produced.
    /// - Returns: the final visible answer.
    @discardableResult
    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String
}

/// A capability handed to a model as a callable function.
public protocol ToolProvider: Sendable {
    /// Human-readable name, e.g. `web_search`.
    var name: String { get }
    /// Description shown to the model.
    var description: String { get }
    /// Name of the single string argument, e.g. `query`.
    var argumentName: String { get }
    /// Description of that argument.
    var argumentDescription: String { get }
    /// Execute the call and return text to feed back to the model.
    func run(argument: String) async throws -> ToolOutcome
}

/// Result of a tool invocation.
public struct ToolOutcome: Sendable {
    /// Full text handed to the model.
    public var text: String
    /// One-line summary for the transcript.
    public var summary: String

    public init(text: String, summary: String) {
        self.text = text
        self.summary = summary
    }
}

// MARK: - Errors

public enum ChatBotsError: LocalizedError, Sendable {
    case emptyTopic
    case engineNotLoaded
    case toolFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyTopic: "Please enter a topic before starting."
        case .engineNotLoaded: "The model is not loaded yet."
        case .toolFailed(let message): "Tool failed: \(message)"
        case .cancelled: "Cancelled."
        }
    }
}
