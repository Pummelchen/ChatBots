// ChatBotsCoreTests — conversations that survive a restart

import ChatBotsCore
import Foundation
import Testing

@Suite("Saved conversations")
struct ConversationStoreTests {

    private func temporaryStore() -> (ConversationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "chatbots-convos-\(UUID().uuidString)")
        return (ConversationStore(directory: directory), directory)
    }

    private func sampleConversation(topic: String, replies: Int = 2) -> Conversation {
        var turns: [Turn] = [
            Turn(sequence: 1, speakerName: "Moderator", kind: .topic, content: topic)
        ]
        for index in 0..<replies {
            turns.append(
                Turn(
                    sequence: index + 2, speakerID: "Agent \(index + 1)",
                    speakerName: index.isMultiple(of: 2) ? "Ann" : "Ben",
                    kind: .chat, content: "Reply \(index + 1)"))
        }
        return Conversation(topic: topic, turns: turns)
    }

    private func sampleSeats() -> [AgentSpec] {
        var first = AgentSpec.seat(index: 0)
        first.displayName = "Ann"
        first.personaID = "troll"
        var second = AgentSpec.seat(index: 1)
        second.displayName = "Ben"
        return [first, second]
    }

    @Test("A conversation is written and read back whole")
    func roundTrip() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let conversation = sampleConversation(topic: "Is a hot dog a sandwich?")
        let record = StoredConversation(
            id: UUID(), conversation: conversation, seats: sampleSeats(), startedAt: .now)
        #expect(store.save(record))

        let loaded = store.load()
        #expect(loaded.count == 1)
        let back = try #require(loaded.first)
        #expect(back.topic == "Is a hot dog a sandwich?")
        #expect(back.turns.count == conversation.turns.count)
        #expect(back.seats.map(\.name) == ["Ann", "Ben"])
        #expect(back.seats.first?.personaID == "troll")

        // And the turns rebuild into something the engine can resume from.
        let rebuilt = back.conversation()
        #expect(rebuilt.turns.count == conversation.turns.count)
        #expect(rebuilt.turns.map(\.content) == conversation.turns.map(\.content))
        #expect(rebuilt.turns.map(\.speakerName) == conversation.turns.map(\.speakerName))
        #expect(rebuilt.turns.map(\.kind) == conversation.turns.map(\.kind))
    }

    @Test("Saving the same conversation twice updates it rather than duplicating")
    func repeatedSaveUpdates() throws {
        // The engine saves after every turn, so a conversation that grew would otherwise
        // produce one record per turn and fill the list with its own history.
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        for replies in 1...4 {
            let record = StoredConversation(
                id: id, conversation: sampleConversation(topic: "Growing", replies: replies),
                seats: sampleSeats(), startedAt: .now)
            #expect(store.save(record))
        }

        let loaded = store.load()
        #expect(loaded.count == 1, "one conversation should be one record")
        // And it holds the most recent state, not the first.
        #expect(loaded.first?.turns.filter { $0.kind == "chat" }.count == 4)
    }

    @Test("Several conversations are listed newest first")
    func newestFirst() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Written oldest to newest, with a deliberate gap so the order is unambiguous.
        for (index, topic) in ["First", "Second", "Third"].enumerated() {
            var record = StoredConversation(
                id: UUID(), conversation: sampleConversation(topic: topic),
                seats: sampleSeats(), startedAt: .now)
            record.updatedAt = Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60)
            #expect(store.save(record))
        }

        let topics = store.load().map(\.topic)
        #expect(topics == ["Third", "Second", "First"], "newest first; got \(topics)")
    }

    @Test("A conversation can be found by id and deleted")
    func findAndDelete() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let wanted = UUID()
        #expect(
            store.save(
                StoredConversation(
                    id: wanted, conversation: sampleConversation(topic: "Keep me"),
                    seats: sampleSeats(), startedAt: .now)))
        #expect(
            store.save(
                StoredConversation(
                    id: UUID(), conversation: sampleConversation(topic: "Other"),
                    seats: sampleSeats(), startedAt: .now)))

        #expect(store.conversation(id: wanted)?.topic == "Keep me")
        #expect(store.delete(id: wanted))
        #expect(store.conversation(id: wanted) == nil)
        #expect(store.load().count == 1)
        // Deleting something that is not there is not an error worth claiming.
        #expect(!store.delete(id: wanted))
    }

    @Test("An empty store reads as empty, not as broken")
    func emptyIsNotCorrupt() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.load().isEmpty)
        #expect(!store.isUnreadable, "nothing saved yet is not the same as unreadable")
        #expect(!store.isUnreadable)
    }

    @Test("A corrupt file is reported as unreadable rather than as an empty history")
    func corruptFileIsDistinguishable() throws {
        // "There are none" and "the file cannot be read" need different answers: one is normal
        // and the other means work has been lost.
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(
            store.save(
                StoredConversation(
                    id: UUID(), conversation: sampleConversation(topic: "Will be damaged"),
                    seats: sampleSeats(), startedAt: .now)))

        try Data("this is not json".utf8).write(to: directory.appending(path: "conversations.json"))
        #expect(store.load().isEmpty)
        #expect(store.isUnreadable)
    }

    @Test("A record from a newer format is not handed back as if it were understood")
    func futureFormatIsHeldBack() throws {
        // A later build may understand it; dropping it here would destroy work, and returning
        // it would be handing back something this build cannot read.
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var record = StoredConversation(
            id: UUID(), conversation: sampleConversation(topic: "From the future"),
            seats: sampleSeats(), startedAt: .now)
        record.formatVersion = StoredConversation.currentFormatVersion + 1
        #expect(store.save(record))

        #expect(store.load().isEmpty, "a newer format should not be offered to this build")
        // And the file is still there, not deleted.
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appending(path: "conversations.json").path))
    }

    @Test("A summary describes the conversation in one line")
    func summary() {
        let record = StoredConversation(
            id: UUID(), conversation: sampleConversation(topic: "Is a hot dog a sandwich?"),
            seats: sampleSeats(), startedAt: .now)
        #expect(record.summary.contains("hot dog"))
        #expect(record.summary.contains("2 replies"))
    }

    @Test("Long conversations are kept, not truncated")
    func longConversationSurvives() throws {
        // The failure this guards is a save that silently keeps only the first screenful.
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = StoredConversation(
            id: UUID(),
            conversation: sampleConversation(topic: "Long", replies: 300),
            seats: sampleSeats(), startedAt: .now)
        #expect(store.save(record))

        let back = try #require(store.load().first)
        #expect(back.turns.filter { $0.kind == "chat" }.count == 300)
    }
}
