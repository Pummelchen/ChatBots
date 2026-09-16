// ChatBotsCore — a message as the model's chat template sees it
//
// Split out of `ChatModels.swift`, which held the whole shared vocabulary in one 862-line file. The
// types did not change; only the file each one lives in did.

import Foundation

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
    /// Give this seat the moderator's source material.
    ///
    /// Only images matter to an engine — text documents reach the model through the prompt —
    /// and an engine that cannot see simply ignores them, which is the same thing as a seat
    /// whose model has no vision.
    func setAttachments(_ documents: [AttachedDocument]) async
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
