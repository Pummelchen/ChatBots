// ChatBotsCoreTests — A34: a save must not destroy records it cannot read
//
// `ConversationStore.save` rebuilds the whole file from a read, so the read has to see the
// records `load()` deliberately holds back. It did not: a newer-format record was filtered
// out of the rebuild and a corrupt file read as empty, and the next ordinary save wrote the
// survivors back over the file — deleting the work the version check exists to protect.

import ChatBotsCore
import Foundation
import Testing

@Suite("A save preserves what it cannot read")
struct AuditEngineStateStoreTests {

    private func temporaryStore() -> (ConversationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "chatbots-audit-store-\(UUID().uuidString)")
        return (ConversationStore(directory: directory), directory)
    }

    private var indexURLPath: String { "conversations.json" }

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
        var second = AgentSpec.seat(index: 1)
        second.displayName = "Ben"
        return [first, second]
    }

    /// Every record in the file, read the way the store reads it — not through `load`, which
    /// is the thing under test.
    private func rawRecords(at directory: URL) throws -> [StoredConversation] {
        let data = try Data(contentsOf: directory.appending(path: "conversations.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([StoredConversation].self, from: data)
    }

    private func futureRecord(id: UUID, topic: String) -> StoredConversation {
        var record = StoredConversation(
            id: id, conversation: sampleConversation(topic: topic),
            seats: sampleSeats(), startedAt: .now)
        record.formatVersion = StoredConversation.currentFormatVersion + 1
        return record
    }

    @Test("A future-version record survives a second save")
    func futureFormatSurvivesLaterSaves() throws {
        // The existing `futureFormatIsHeldBack` test only proves the file still exists after
        // the first save. This is the failure the audit named: the *next* save rebuilds the
        // file from `load()`, which held the future record back, and writes it away.
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let futureID = UUID()
        #expect(store.save(futureRecord(id: futureID, topic: "From the future")))

        let present = StoredConversation(
            id: UUID(), conversation: sampleConversation(topic: "From today"),
            seats: sampleSeats(), startedAt: .now)
        #expect(store.save(present))

        let raw = try rawRecords(at: directory)
        let future = try #require(raw.first { $0.id == futureID })
        #expect(
            future.formatVersion == StoredConversation.currentFormatVersion + 1,
            "the newer-format record was deleted by an ordinary save")
        #expect(future.topic == "From the future")
        #expect(raw.contains { $0.id == present.id }, "the new record was written too")

        // And the newer format is still held back from this build's own list.
        #expect(store.load().map(\.id) == [present.id])
    }

    @Test("A save refuses rather than overwriting a file it cannot decode")
    func saveRefusesToDestroyUnreadableFile() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("this is not json".utf8)
        try corrupt.write(to: directory.appending(path: indexURLPath))

        let record = StoredConversation(
            id: UUID(), conversation: sampleConversation(topic: "Would overwrite"),
            seats: sampleSeats(), startedAt: .now)
        #expect(!store.save(record), "the save had to refuse: the file cannot be accounted for")

        // The bytes are exactly what they were, not replaced by the record this build read.
        let after = try Data(contentsOf: directory.appending(path: indexURLPath))
        #expect(after == corrupt)
        #expect(store.isUnreadable)
    }

    @Test("Deleting one conversation keeps a future-version record")
    func deleteKeepsFutureFormat() throws {
        // `delete` rebuilds the same file as `save`, so it had the same way of destroying a
        // record it never read.
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keepID = UUID()
        let futureID = UUID()
        #expect(store.save(futureRecord(id: futureID, topic: "From the future")))
        #expect(store.save(StoredConversation(
            id: keepID, conversation: sampleConversation(topic: "Delete me"),
            seats: sampleSeats(), startedAt: .now)))

        #expect(store.delete(id: keepID))

        let raw = try rawRecords(at: directory)
        #expect(raw.contains { $0.id == futureID }, "delete took the newer-format record with it")
        #expect(!raw.contains { $0.id == keepID })
    }
}
