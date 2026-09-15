// ChatBotsCoreTests — A137: the store replaces the index atomically and recovers a stranded temporary
//
// The write path used to remove `conversations.json` and then move the replacement into its place.
// Between those two steps there was no index at all, so a crash there lost every kept conversation —
// and the complete temporary file the previous line had just written was never read back, which made
// the loss look like an empty history rather than like damage.

import Foundation
import Testing

@testable import ChatBotsCore

private func storedRecord(topic: String) -> StoredConversation {
    var seat = AgentSpec.makeSeats(count: 1)[0]
    seat.displayName = "Ada"
    var conversation = Conversation(topic: topic, turns: [])
    conversation.topic = topic
    return StoredConversation(
        id: UUID(), conversation: conversation, seats: [seat], startedAt: .now)
}

@Suite("The store writes atomically and recovers a stranded temporary (A137)")
struct AuditS0StoreRecoveryTests {

    private func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)")
    }

    @Test("A save leaves the index in place and no temporary file behind")
    func saveLeavesNoTemporary() throws {
        let directory = freshDirectory()
        let store = ConversationStore(directory: directory)

        #expect(store.save(storedRecord(topic: "first")))
        #expect(store.save(storedRecord(topic: "second")))

        #expect(
            FileManager.default.fileExists(
                atPath: directory.appending(path: "conversations.json").path),
            "the index must exist after a save")
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appending(path: "conversations.json.tmp").path),
            "the temporary file must not be left behind")
        #expect(store.load().count == 2, "both records must survive")
    }

    @Test("A store a crash left with only its temporary file still loads")
    func strandedTemporaryIsRecovered() throws {
        let directory = freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Exactly the state the remove-then-move write path could leave behind: the complete
        // replacement sitting in the temporary file, with no index beside it.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([storedRecord(topic: "recovered")])
            .write(to: directory.appending(path: "conversations.json.tmp"))

        let store = ConversationStore(directory: directory)

        #expect(
            store.load().map(\.topic) == ["recovered"],
            "the stranded history must be read back rather than reported as empty")
    }

    @Test("An empty directory is still an empty history, not a recovery")
    func emptyDirectoryIsEmpty() throws {
        let directory = freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(ConversationStore(directory: directory).load().isEmpty)
    }
}
