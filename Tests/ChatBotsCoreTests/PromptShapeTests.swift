// ChatBotsCoreTests — the shape of a prompt, which the model's own template polices
//
// A conversation that produced no turns at all was traced to the chat template rather than to
// the model. Qwen 3.5's template raises `System message must be at the beginning.` for any
// system message that is not first, and `PromptBuilder` was sending up to three of them: the
// seat's brief, the moderator's source material, and the social state. Every generation in a
// conversation with an attachment failed, and an entertainment conversation began failing as
// soon as the room had a history.
//
// The raise happens inside Jinja, so what reached the log was `Jinja.TemplateException error
// 1` — the exception carries a message but no `errorDescription`, so the reason was discarded
// on the way out. Nothing about that failure pointed at the prompt.
//
// These tests hold the invariants the template actually enforces, in the shapes that broke it,
// without needing a model or a GPU. The rules are read from `chat_template.jinja` in the model
// directory, and the one that mattered is the first.

import ChatBotsCore
import Foundation
import Testing

@Suite("Prompt shape")
struct PromptShapeTests {

    /// Every role the template knows. Anything else raises `Unexpected message role.`
    private static let templateRoles: Set<PromptMessage.Role> = [.system, .user, .assistant]

    /// The rules the Qwen template enforces on the `messages` array.
    ///
    /// Checked in one place so every case below is held to the same contract, and so a new
    /// case cannot accidentally assert less.
    private func expectTemplateCompatible(_ messages: [PromptMessage], _ context: Comment) {
        #expect(!messages.isEmpty, "the template raises on an empty prompt")

        // `System message must be at the beginning.` — the template tests `loop.first` for
        // every system message, so a second one is a hard failure, wherever it sits.
        let systemIndices = messages.indices.filter { messages[$0].role == .system }
        #expect(
            systemIndices.count == 1 && systemIndices.first == 0,
            "exactly one system message, and it must be first — \(context)")

        // `Unexpected message role.`
        for message in messages {
            #expect(
                Self.templateRoles.contains(message.role),
                "role \(message.role.rawValue) is not one the template renders")
        }

        // `No user query found in messages.` — the template scans backwards for a user turn
        // that is not a bare tool response.
        #expect(messages.contains { $0.role == .user }, "the template needs a user turn — \(context)")

        // `Unexpected content type.` — a message must carry a string. `PromptMessage.content`
        // is one by construction, so this is the assertion that keeps it that way.
        #expect(
            messages.allSatisfy { !$0.content.isEmpty },
            "an empty message renders as nothing and hides a mistake — \(context)")
    }

    private func conversation(
        attachments: [AttachedDocument] = [],
        conflict: ConflictState = ConflictState()
    ) -> Conversation {
        var conversation = Conversation(
            topic: "Are eggs round?",
            turns: [
                Turn(sequence: 1, speakerName: "Moderator", kind: .topic, content: "Are eggs round?"),
                Turn(sequence: 2, speakerName: "The Setup", kind: .introduction, content: "Rules: none."),
            ],
            attachments: attachments)
        conversation.conflict = conflict
        return conversation
    }

    private func text(_ name: String, _ body: String = "Ovoid shells resist point loads.") -> AttachedDocument {
        AttachedDocument(name: name, kind: .plainText, text: body)
    }

    /// A conflict state with a live grudge, so the social briefing is non-empty.
    private func conflictWithHistory() -> ConflictState {
        var conflict = ConflictState()
        conflict.apply(
            signals: [TurnSignal(kind: .jab, confidence: 1.0, target: "Agent 2")],
            from: "Agent 1", others: ["Agent 1", "Agent 2"], sequence: 2,
            summary: "that is a ridiculous claim")
        return conflict
    }

    private func spec(mode: DiscussionMode, index: Int = 0) -> AgentSpec {
        var spec = AgentSpec.seat(index: index)
        spec.mode = mode
        spec.personaID = mode.defaultPersonaID(forSeat: index)
        return spec
    }

    @Test("A plain entertainment prompt is template-compatible")
    func plainEntertainment() {
        let messages = PromptBuilder.prompt(
            for: spec(mode: .entertainment), others: [spec(mode: .entertainment, index: 1)],
            conversation: conversation())
        expectTemplateCompatible(messages, "plain entertainment")
    }

    @Test("An entertainment prompt with source material is template-compatible")
    func entertainmentWithAttachment() {
        // The case that failed on the first turn: brief plus source material used to be two
        // system messages.
        let messages = PromptBuilder.prompt(
            for: spec(mode: .entertainment), others: [spec(mode: .entertainment, index: 1)],
            conversation: conversation(attachments: [text("study.md")]))
        expectTemplateCompatible(messages, "entertainment with an attachment")
        #expect(messages[0].content.contains("Ovoid shells resist point loads."))
    }

    @Test("An entertainment prompt with a social history is template-compatible")
    func entertainmentWithSocialState() {
        // The case that failed from the second turn on, once the room had a grudge to report.
        let messages = PromptBuilder.prompt(
            for: spec(mode: .entertainment), others: [spec(mode: .entertainment, index: 1)],
            conversation: conversation(conflict: conflictWithHistory()))
        expectTemplateCompatible(messages, "entertainment with social state")
        #expect(messages[0].content.contains("Where things stand"))
    }

    @Test("Both extra sections at once still produce one system message")
    func entertainmentWithEverything() {
        // Three system messages before the fix; the template allows one.
        let messages = PromptBuilder.prompt(
            for: spec(mode: .entertainment), others: [spec(mode: .entertainment, index: 1)],
            conversation: conversation(attachments: [text("study.md")], conflict: conflictWithHistory()))
        expectTemplateCompatible(messages, "every optional section at once")
        #expect(messages.filter { $0.role == .system }.count == 1)
        // Order is part of the contract: who the seat is, then the material, then the room.
        let system = messages[0].content
        let material = system.range(of: "Ovoid shells")
        let social = system.range(of: "Where things stand")
        #expect(material != nil && social != nil, "both sections should be present")
        if let material, let social {
            #expect(material.lowerBound < social.lowerBound, "material comes before the room")
        }
    }

    @Test("A research prompt with source material is template-compatible")
    func researchWithAttachment() {
        let messages = PromptBuilder.prompt(
            for: spec(mode: .research), others: [spec(mode: .research, index: 1)],
            conversation: conversation(attachments: [text("brief.md")]))
        expectTemplateCompatible(messages, "research with an attachment")
    }

    @Test("A research prompt carries no social state")
    func researchHasNoSocialState() {
        // The modes must not share a philosophy: a research seat is told about method, not
        // about who it is annoyed with.
        let messages = PromptBuilder.prompt(
            for: spec(mode: .research), others: [spec(mode: .research, index: 1)],
            conversation: conversation(conflict: conflictWithHistory()))
        expectTemplateCompatible(messages, "research with a conflict state")
        #expect(!messages[0].content.contains("Where things stand"))
    }

    @Test("Steering appended while generating keeps the shape")
    func steeringKeepsTheShape() {
        let steering = [
            Turn(sequence: 3, speakerName: "Moderator", kind: .steering, content: "Answer the actual question.")
        ]
        let messages = PromptBuilder.prompt(
            for: spec(mode: .entertainment), others: [spec(mode: .entertainment, index: 1)],
            conversation: conversation(), steering: steering)
        expectTemplateCompatible(messages, "with steering appended")
        #expect(messages.last?.content.contains("Answer the actual question.") == true)
    }

    @Test("The last message is the ask, from the user")
    func theAskIsLast() {
        // The template appends the generation prompt after the final message, so the final
        // message has to be the user turn rather than a system one.
        let messages = PromptBuilder.prompt(
            for: spec(mode: .entertainment), others: [spec(mode: .entertainment, index: 1)],
            conversation: conversation(attachments: [text("study.md")], conflict: conflictWithHistory()))
        #expect(messages.last?.role == .user)
        #expect(messages.last?.content.contains("It is your turn") == true)
    }
}
