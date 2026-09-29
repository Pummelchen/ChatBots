// ChatBotsAppTests — a topic typed here is not overwritten by the state the engine still holds
//
// The engine owns the topic of a conversation it already holds, so a change the engine made has to
// reach the field. What it must not do is win against a topic being typed: the engine keeps its old
// topic until `start` sends the new one, so comparing the field with the engine on every snapshot
// wiped the field once a second and no topic could be entered at all. These pin the rule that tells
// the two apart.

import Testing

@testable import ChatBots

@MainActor
@Suite("Editing the topic")
struct TopicEditingTests {

    @Test("A topic being typed survives the state the engine still holds")
    func typingSurvivesSnapshots() {
        // The same topic reported again, as the once-a-second poll does while a topic is typed.
        #expect(
            ChatController.adoptsEngineTopic(
                reported: "Why are eggs not round?", previous: "Why are eggs not round?",
                engineHasMessages: false) == false)
    }

    @Test("A topic the engine moved is adopted, even with no conversation yet")
    func anEngineChangeIsAdopted() {
        #expect(
            ChatController.adoptsEngineTopic(
                reported: "A new subject", previous: "Why are eggs not round?",
                engineHasMessages: false))
    }

    @Test("An engine that already holds a conversation shows its topic")
    func aHeldConversationWins() {
        #expect(
            ChatController.adoptsEngineTopic(
                reported: "Loaded from the transcript", previous: nil, engineHasMessages: true))
    }

    @Test("A freshly started engine does not overwrite the stored topic")
    func aFreshEngineDoesNotClobber() {
        #expect(
            ChatController.adoptsEngineTopic(
                reported: "Why are eggs not round?", previous: nil, engineHasMessages: false)
                == false)
    }

    @Test("An empty topic never replaces what the field holds")
    func anEmptyTopicIsIgnored() {
        #expect(
            ChatController.adoptsEngineTopic(reported: "", previous: nil, engineHasMessages: true)
                == false)
    }
}
