// ChatBotsCore — the protocol a seat's engine satisfies, and its defaults
//
// Split out of `ChatModels.swift`, which held the whole shared vocabulary in one 862-line file. The
// types did not change; only the file each one lives in did.

import Foundation

extension LLMEngine {
    /// Live reconfiguration is optional for an engine.
    ///
    /// Both shipped backends implement these, but an engine that cannot be reconfigured at
    /// runtime — a test double, or a future read-only proxy — should not have to write
    /// empty methods to satisfy the protocol.
    ///
    /// The defaults are silent, and that is a sharper edge than it looks. A synchronous method also
    /// satisfies an `async` requirement, so an engine that declares these without `async` gets both
    /// its own method *and* this default in scope at a concrete call site — and `await` picks this
    /// one. The write then vanishes with nothing failing to compile. That is exactly what happened
    /// to `MLXEngine` and `OpenAIResponsesEngine`, which is why both now declare these
    /// `async` and match the requirement by shape as well as by name. An engine that leans on these
    /// defaults keeps doing so deliberately; `EngineSetterShadowingTests` pins both behaviours.
    public func setThinking(_ mode: ThinkingMode) async {}
    public func setPersona(_ personaID: String) async {}
    public func setDisplayName(_ name: String) async {}
    public func setAttachments(_ documents: [AttachedDocument]) async {}

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
