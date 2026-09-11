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
        /// A model-written digest that replaced older turns to reclaim context. Authored by
        /// the app on a seat's behalf, so it carries no speaker.
        case summary
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

    /// The current compaction summary, if the log has been condensed.
    public var summaryTurn: Turn? {
        turns.last { $0.kind == .summary }
    }
}

// MARK: - Participant

/// Static description of one LLM seat at the table.
///
/// Sampling lives on the seat, not in the engine, so two seats can run different
/// checkpoints *and* different samplers. `QwenSampling` is the shared preset used by the
/// two default Qwen seats.
public struct AgentSpec: Identifiable, Sendable, Hashable, Codable {

    /// Which engine drives this seat.
    ///
    /// The two are equivalent from the orchestrator's point of view — both are `LLMEngine`
    /// — but not from the app's: `mlx` runs the weights in-process on the GPU, while
    /// `openAIResponses` talks HTTP to a server (LM Studio, or OpenAI itself). Tools are
    /// dispatched in-process and so exist only on `mlx`.
    public enum Backend: String, Sendable, Codable, CaseIterable, Identifiable {
        case mlx
        case openAIResponses

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .mlx: "MLX (in-process)"
            case .openAIResponses: "OpenAI Responses API"
            }
        }

        public var shortLabel: String {
            switch self {
            case .mlx: "MLX"
            case .openAIResponses: "API"
            }
        }
    }

    /// Stable id (also the seat label used in prompts, e.g. "Agent A").
    public var id: String
    public var displayName: String
    /// Hugging Face repo id of the MLX checkpoint.
    public var modelID: String
    /// Short label shown in the UI badge.
    public var modelShortName: String
    /// Which engine runs this seat.
    public var backend: Backend
    /// Endpoint used when `backend` is `.openAIResponses`.
    public var openAI: OpenAIEndpoint
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
    /// Maximum tokens for the *answer*, reasoning excluded. The hard generation cap is
    /// this plus whatever `thinking` budgets for reasoning.
    public var maxTokens: Int
    /// The seat's context window, in tokens, when it cannot be discovered.
    ///
    /// The MLX backend reads this from the checkpoint's own config; a server does not
    /// advertise it, so an API seat uses this value. It is the single number the
    /// auto-compaction threshold is measured against.
    public var contextWindow: Int
    /// Whether this seat may call the web-search tools.
    public var webSearchEnabled: Bool
    /// How much this seat may think before answering. Changeable at runtime from the pane;
    /// `LLMEngine.currentSpec` carries the live value, `spec` the value at construction.
    public var thinking: ThinkingMode
    /// Which style this seat argues in. Stored as an id so the library can be extended
    /// or reworded without invalidating saved configuration; an unknown id resolves to
    /// `PersonaLibrary.neutral`.
    ///
    /// Changeable at runtime from the pane; `LLMEngine.currentSpec` carries the live
    /// value.
    public var personaID: String

    public init(
        id: String,
        displayName: String,
        modelID: String = AgentSpec.defaultModelID,
        modelShortName: String = "Qwen3.5-4B-4bit",
        backend: Backend = .mlx,
        openAI: OpenAIEndpoint = OpenAIEndpoint(),
        temperature: Double = 0.75,
        topP: Double = 0.95,
        topK: Int = 0,
        minP: Double = 0.0,
        presencePenalty: Double? = nil,
        repetitionPenalty: Double? = nil,
        maxTokens: Int = 1024,
        contextWindow: Int = AgentSpec.defaultContextWindow,
        webSearchEnabled: Bool = true,
        thinking: ThinkingMode = .medium,
        personaID: String = PersonaLibrary.neutral.id
    ) {
        self.id = id
        self.displayName = displayName
        self.modelID = modelID
        self.modelShortName = modelShortName
        self.backend = backend
        self.openAI = openAI
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.presencePenalty = presencePenalty
        self.repetitionPenalty = repetitionPenalty
        self.maxTokens = maxTokens
        self.contextWindow = contextWindow
        self.webSearchEnabled = webSearchEnabled
        self.thinking = thinking
        self.personaID = personaID
    }

    public static let defaultModelID = "mlx-community/Qwen3.5-4B-MLX-4bit"

    /// Qwen 3.5's own maximum context (`max_position_embeddings` in its config). Used both
    /// as the MLX seat's budget and as the assumed window for an API seat, which no
    /// OpenAI-compatible server advertises through `/v1/models`.
    public static let defaultContextWindow = 262_144


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
    public enum QwenSampling: Sendable {
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
        /// Thinking defaults to the level the moderator asked for; change it per seat in
        /// the pane header.
        public static let thinking = ThinkingMode.medium
    }

    // MARK: - Seats

    /// How many participants the app is built to run at once.
    ///
    /// Nothing in the orchestration is limited to a particular number — turn order is a
    /// rotation, the transcript is shared, and each seat owns its engine — so the cap is
    /// only what the layout can show legibly side by side. The unified layout has no such
    /// limit. Adding a seat beyond this is a matter of extending the palettes.
    public static let supportedSeatCount = 4

    /// The roster the app builds at launch.
    ///
    /// Two today, and the default here is the single place to change that: the controller
    /// builds one pane, one MLX engine and one API engine per seat, and the turn loop is a
    /// rotation, so nothing else needs touching. `CHATBOTS_SEATS` overrides it, which is
    /// how a 3- or 4-seat run is tried out without editing code.
    public enum SeatRoster {
        public static let shippingCount = 2
        public static let environmentKey = "CHATBOTS_SEATS"

        /// The requested count, clamped to what the layout and palettes support.
        public static func count(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Int {
            guard let raw = environment[environmentKey], let requested = Int(raw) else {
                return shippingCount
            }
            return max(1, min(requested, supportedSeatCount))
        }

        /// The seats to build.
        public static func specs(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> [AgentSpec] {
            makeSeats(count: count(environment: environment))
        }
    }

    /// Label for a seat by position: `1` becomes `Agent 1`.
    public static func seatID(forIndex index: Int) -> String { "Agent \(index + 1)" }

    /// Default styles, one per seat, chosen so that neighbours disagree productively
    /// rather than so that any particular one is "right".
    ///
    /// Seats beyond this list fall back to a deterministic pick, so adding a seat never
    /// produces four identical participants.
    public static let defaultPersonaIDs = [
        "fact-checker",  // 1 — wants a source for every claim
        "skeptic",  // 2 — doubts the obvious explanation
        "engineer",  // 3 — reduces it to constraints and trade-offs
        "empath",  // 4 — asks what it would mean for people
    ]

    /// The opening seat's default style, kept as a named constant because it is the one
    /// most code and documentation refers to.
    public static var defaultPersonaA: String { defaultPersonaIDs[0] }
    /// The second seat's default style.
    public static var defaultPersonaB: String { defaultPersonaIDs[1] }

    public static func defaultPersonaID(forIndex index: Int) -> String {
        if index < defaultPersonaIDs.count { return defaultPersonaIDs[index] }
        // Deterministic, and skips Neutral so a late seat still has a style.
        let styled = PersonaLibrary.all.filter { $0.id != PersonaLibrary.neutral.id }
        guard !styled.isEmpty else { return PersonaLibrary.neutral.id }
        return styled[index % styled.count].id
    }

    /// One seat.
    ///
    /// - Parameters:
    ///   - index: position in the conversation, `0`-based. Drives the default id, style
    ///     and, in the UI, the colour.
    ///   - modelID: the MLX checkpoint for this seat. Pointing two seats at different
    ///     checkpoints is the whole reason seats are independent.
    public static func seat(
        index: Int,
        modelID: String = AgentSpec.defaultModelID,
        personaID: String? = nil,
        backend: Backend = .mlx
    ) -> AgentSpec {
        AgentSpec(
            id: seatID(forIndex: index),
            displayName: seatID(forIndex: index),
            modelID: modelID,
            modelShortName: "Qwen3.5-4B-4bit",
            backend: backend,
            temperature: QwenSampling.temperature,
            topP: QwenSampling.topP,
            topK: QwenSampling.topK,
            minP: QwenSampling.minP,
            presencePenalty: QwenSampling.presencePenalty,
            repetitionPenalty: QwenSampling.repetitionPenalty,
            maxTokens: QwenSampling.maxOutputTokens,
            contextWindow: defaultContextWindow,
            thinking: QwenSampling.thinking,
            personaID: personaID ?? defaultPersonaID(forIndex: index)
        )
    }

    /// A full roster. `makeSeats(2)` is what the app ships with today; `makeSeats(4)` is
    /// ready and is covered by tests.
    public static func makeSeats(
        count: Int = 2,
        modelIDs: [String]? = nil,
        personaIDs: [String]? = nil
    ) -> [AgentSpec] {
        let clamped = max(1, min(count, supportedSeatCount))
        return (0..<clamped).map { index in
            seat(
                index: index,
                modelID: modelIDs?[safe: index] ?? defaultModelID,
                personaID: personaIDs?[safe: index]
            )
        }
    }

    /// Seat 1 — opens the conversation.
    public static func seatA(
        modelID: String = AgentSpec.defaultModelID,
        personaID: String = defaultPersonaIDs[0]
    ) -> AgentSpec {
        seat(index: 0, modelID: modelID, personaID: personaID)
    }

    /// Seat 2.
    public static func seatB(
        modelID: String = AgentSpec.defaultModelID,
        personaID: String = defaultPersonaIDs[1]
    ) -> AgentSpec {
        seat(index: 1, modelID: modelID, personaID: personaID)
    }

    /// Seat 3 — unused by default, ready to add.
    public static func seatC(
        modelID: String = AgentSpec.defaultModelID,
        personaID: String = defaultPersonaIDs[2]
    ) -> AgentSpec {
        seat(index: 2, modelID: modelID, personaID: personaID)
    }

    /// Seat 4 — unused by default, ready to add.
    public static func seatD(
        modelID: String = AgentSpec.defaultModelID,
        personaID: String = defaultPersonaIDs[3]
    ) -> AgentSpec {
        seat(index: 3, modelID: modelID, personaID: personaID)
    }

    /// A separate instance of the same weights still deserves a distinct sampling
    /// seed-stream, otherwise the two seats converge on identical phrasing.
    /// Total tokens the model may emit for one turn: the answer budget plus whatever
    /// this thinking mode allows for reasoning.
    public var generationCap: Int {
        maxTokens + (thinking.reasoningTokenBudget ?? 0)
    }

    /// What the badge under a seat's name should read.
    public var backendLabel: String {
        switch backend {
        case .mlx: modelShortName
        case .openAIResponses: openAI.shortModelName
        }
    }

    /// The resolved style. Never fails: an unknown id yields `neutral`.
    public var persona: Persona { PersonaLibrary.persona(id: personaID) }

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
    /// Seconds spent prefilling the prompt, before the first token appeared.
    public var prefillSeconds: Double
    /// Prompt tokens processed per second during prefill — the number that decides how
    /// long a long conversation takes to get going.
    public var prefillTokensPerSecond: Double {
        prefillSeconds > 0 ? Double(promptTokens) / prefillSeconds : 0
    }

    public var generationTokens: Int
    public var cachedPromptTokens: Int
    public var stopReason: String
    public var tokensPerSecond: Double
    public var seconds: Double

    public init(
        promptTokens: Int = 0,
        prefillSeconds: Double = 0,
        generationTokens: Int = 0,
        cachedPromptTokens: Int = 0,
        stopReason: String = "",
        tokensPerSecond: Double = 0,
        seconds: Double = 0
    ) {
        self.promptTokens = promptTokens
        self.prefillSeconds = prefillSeconds
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

    /// The seat's configuration *as it stands now*, including anything the user changed
    /// from the UI since `spec` was captured — thinking level and persona. The
    /// orchestrator builds prompts from this so a change takes effect on the next turn.
    var currentSpec: AgentSpec { get async }
    /// Load weights. Idempotent; safe to call from several tasks.
    func load() async throws
    var isLoaded: Bool { get async }
    /// The model's configured context window, in tokens.
    var contextWindow: Int { get async }
    /// Free the weights.
    func unload() async
    /// Change how much this seat may think. Takes effect on its next turn.
    ///
    /// `async` because a seat's engine is an actor: the live configuration is actor state,
    /// and these are the only way to change it from the UI.
    func setThinking(_ mode: ThinkingMode) async
    /// Change this seat's style. Takes effect on its next turn.
    func setPersona(_ personaID: String) async
    /// Rename this seat. Takes effect on its next turn, and on what the models are told
    /// each participant is called.
    func setDisplayName(_ name: String) async
    /// Ask this seat to condense a transcript into a compact digest.
    ///
    /// Used to reclaim context without losing what was said. Implementations must not use
    /// tools for this and should return the digest as plain text.
    func compact(prompt: String, maxTokens: Int) async throws -> String
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

extension LLMEngine {
    /// Live reconfiguration is optional for an engine.
    ///
    /// Both shipped backends implement these, but an engine that cannot be reconfigured at
    /// runtime — a test double, or a future read-only proxy — should not have to write
    /// empty methods to satisfy the protocol. The defaults are deliberately silent rather
    /// than fatal: the worst case is that a control does nothing, which is exactly what an
    /// engine that ignores it already means.
    public func setThinking(_ mode: ThinkingMode) async {}
    public func setPersona(_ personaID: String) async {}
    public func setDisplayName(_ name: String) async {}

    /// Engines that cannot summarise simply decline.
    public func compact(prompt: String, maxTokens: Int) async throws -> String { "" }
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


extension Array {
    /// Bounds-checked lookup, for optional per-seat configuration lists.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
