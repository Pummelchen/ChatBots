// ChatBotsCore — the seats, their models and their sampling settings
//
// Split out of `ChatModels.swift`, which held the whole shared vocabulary in one 862-line file. The
// types did not change; only the file each one lives in did.

import Foundation

public struct AgentSpec: Identifiable, Sendable, Hashable, Codable {

    /// Which engine drives this seat.
    ///
    /// The two are equivalent from the orchestrator's point of view — both are `LLMEngine`
    /// — but not from the app's: `mlx` runs the weights on this Mac's GPU, in the engine process
    /// the app starts, while `openAIResponses` talks HTTP to a server (LM Studio, or OpenAI
    /// itself). Tools are dispatched by the engine and so exist only on `mlx`.
    public enum Backend: String, Sendable, Codable, CaseIterable, Identifiable {
        case mlx
        case openAIResponses

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .mlx: "MLX (local)"
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
    /// Whether this seat is taking part in an entertainment session or a research one.
    ///
    /// It lives on the seat rather than on the engine because personas are per-seat, and
    /// because a stored configuration has to know which library its persona id belongs to.
    public var mode: DiscussionMode
    /// Overrides what this seat's model is assumed to accept, for an API model whose family
    /// cannot be recognised from its id. Nil means "work it out".
    public var visionOverride: VisionSupport?
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
        visionOverride: VisionSupport? = nil,
        mode: DiscussionMode = .entertainment,
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
        self.visionOverride = visionOverride
        self.mode = mode
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
    /// **These are tighter than Qwen's published recommendation on purpose.** The model card
    /// suggests `temperature 1.0, top_p 0.95, top_k 20, min_p 0` for thinking mode, and that
    /// is what this used to ship. On this app's prompt — several thousand tokens of persona,
    /// rules and transcript, answered by a 4B checkpoint that is also holding a reasoning
    /// budget — it degenerated almost immediately. Measured on a fixed topic over three
    /// turns with `--turns 3 --topic "Are eggs round?"` (the tightened preset was run twice,
    /// on different seeds, because `samplingSeed` is drawn per process rather than fixed):
    ///
    /// | Preset | Repetition cuts | Effect |
    /// | --- | --- | --- |
    /// | `temp 1.0, topP 0.95, minP 0, rep 1.0` | 8 in one run | turns ended producing **0 tokens** |
    /// | the values below | 0 | three turns, each addressed the one before it |
    ///
    /// The two settings that matter most are the repetition penalty, which was a literal
    /// no-op at `1.0` (MLX multiplies), and `minP`, which was disabled at `0`. Temperature is
    /// lowered because the attractor is an entropy problem: the model keeps re-entering the
    /// same short phrase once it has said it. Thinking stays on and the token budget is
    /// unchanged, so this narrows the sampler rather than the reasoning.
    ///
    /// | Setting | Value |
    /// | --- | --- |
    /// | Thinking | on (`enable_thinking: true`) |
    /// | Temperature | 0.7 |
    /// | Top P | 0.8 |
    /// | Top K | 20 |
    /// | Min P | 0.05 |
    /// | Presence penalty | 1.5 (UI convention) → `-1.5` for MLX |
    /// | Repetition penalty | 1.1 |
    /// | Max output tokens | 32,768 |
    public enum QwenSampling: Sendable {
        public static let temperature = 0.7
        public static let topP = 0.8
        public static let topK = 20
        public static let minP = 0.05
        /// Displayed as 1.5 in the UI. MLX *subtracts* the value it is given, so a
        /// positive `1.5` would reward tokens already in the context — the opposite of a
        /// presence penalty. The sign is flipped here, in one place.
        public static let presencePenaltyMagnitude = 1.5
        public static let presencePenalty = -presencePenaltyMagnitude
        /// MLX multiplies by this and `1.0` is neutral, so the old value did nothing at all.
        /// `1.1` over the last 256 tokens is what breaks the short-phrase attractor.
        public static let repetitionPenalty = 1.1
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
        /// The roster with the first two seats named, which is what the app starts with.
        ///
        /// Naming happens here so that every entry point gets it — the app, the command line,
        /// the server — rather than each having to remember. A roster loaded from saved
        /// settings is used as it stands: the name was chosen when those seats were built, and
        /// re-rolling it on every launch would change the participants under a conversation
        /// someone is in the middle of.
        public static func namedSpecs(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> [AgentSpec] {
            var seats = specs(environment: environment)
            var generator = SystemRandomNumberGenerator()
            AgentSpec.assignNames(to: &seats, using: &generator)
            return seats
        }

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
            // From the identifier, not a constant: this said "Qwen3.5-4B-4bit" for every checkpoint a
            // caller asked for.
            modelShortName: ModelNames.shortName(modelID),
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

    /// Give the first two seats a person's name instead of "Agent 1" and "Agent 2".
    ///
    /// One female and one male, drawn at random from any of the six languages. The point is
    /// that a conversation between two people reads differently from one between two seat
    /// numbers — the models refer to each other by name, and so does the transcript.
    ///
    /// Only the first two: a third and fourth seat keep their numbers, because the brief is
    /// about the pair and because inventing a gender balance for four seats would be
    /// arbitrary.
    ///
    /// The choice is saved with the settings, so it survives a restart. A name only changes
    /// when the seats are rebuilt, which is what "on startup" means — not while a conversation
    /// is under way.
    public static func assignNames(
        to seats: inout [AgentSpec],
        using generator: inout some RandomNumberGenerator
    ) {
        guard seats.count >= 1 else { return }
        seats[0].displayName = NameLists.random(.female, using: &generator)
        if seats.count >= 2 {
            seats[1].displayName = NameLists.random(.male, using: &generator)
        }
    }

    /// The seats to build, with the first two named.
    public static func namedSeats(
        count: Int = 2,
        modelIDs: [String]? = nil,
        personaIDs: [String]? = nil,
        using generator: inout some RandomNumberGenerator
    ) -> [AgentSpec] {
        var seats = makeSeats(count: count, modelIDs: modelIDs, personaIDs: personaIDs)
        assignNames(to: &seats, using: &generator)
        return seats
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
    ///
    /// Delegates to `ThinkingMode.generationCap`, which is also what
    /// `MLXEngine.generationCap` (and therefore the running engine) uses. This property
    /// used to do its own `maxTokens + (thinking.reasoningTokenBudget ?? 0)`, so it kept
    /// returning the pre-fix answer — `.unlimited` came out *smaller* than `.high` — long
    /// after the engine had been fixed, and any public caller got the wrong cap. One
    /// implementation is the only way the two cannot drift again.
    public var generationCap: Int {
        thinking.generationCap(answerBudget: maxTokens, contextWindow: contextWindow)
    }

    /// What the badge under a seat's name should read.
    public var backendLabel: String {
        switch backend {
        case .mlx: modelShortName
        // Through the naming table, so the header says "DeepSeek V4.1 Flash" rather than the
        // server's slug. Keeping this in one place means the header, the settings sheet and
        // the web interface cannot disagree about what a model is called.
        case .openAIResponses: ModelNames.friendly(openAI.model)
        }
    }

    /// What to call this seat's model on screen.
    ///
    /// Derived rather than stored, so a model is never displayed as a raw server id like
    /// `deepseek-v4-pro` in one place and a friendly name in another — and so a model the app
    /// has never heard of still gets a readable label instead of a blank. `modelShortName` is
    /// used for the local checkpoint, whose own naming is already friendly.
    public var modelLabel: String {
        switch backend {
        case .mlx:
            return modelShortName
        case .openAIResponses:
            return ModelNames.friendly(openAI.model)
        }
    }

    /// The resolved style. Never fails: an unknown id yields `neutral`.
    ///
    /// Superseded by `personaStyle`, which resolves through the seat's mode; kept so the
    /// original library's own lookup remains available.
    public var persona: Persona { PersonaLibrary.persona(id: personaID) }

    /// The persona for this seat in this seat's mode, resolved from the right library.
    ///
    /// An id stored for one mode does not resolve in the other, so this falls back to the
    /// mode's default for the seat rather than handing the model an empty directive.
    public var personaStyle: PersonaStyle {
        PersonaCatalog.style(id: personaID, mode: mode, seatIndex: seatOrdinal)
    }

    /// The seat's ordinal, used only to pick a sensible default persona. Derived from the id
    /// rather than stored, so it stays stable across launches.
    private var seatOrdinal: Int {
        let trailing = id.split(separator: " ").last.flatMap { Int($0) } ?? 1
        return max(0, trailing - 1)
    }

    public var samplingSeed: UInt64 {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(modelID)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}
