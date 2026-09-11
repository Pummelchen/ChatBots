// ChatBotsCore — conversations that survive the app closing
//
// The settings already came back after a restart; the conversation did not, so closing the
// window threw away the thing the window existed for. This keeps them.
//
// **The engine owns this.** Not the app: the conversation lives in the engine now, and if the
// app saved its own copy there would be two records of one conversation that could disagree.
// The engine writes after every turn and can read one back.
//
// **Stored as its own record type, not by making `Turn` Codable.** A `Turn` is a domain value
// — it carries a `UUID`, a `Date`, an enum and an optional tool detail — and making it
// `Codable` would tie the on-disk format to the in-memory shape. Every later change to `Turn`
// would then be a migration. The record below is a deliberate, small, versioned format instead,
// and it can stay put while `Turn` moves.

import Foundation

/// One conversation, as stored.
public struct StoredConversation: Codable, Sendable, Identifiable {
    /// Bumped when the format changes in a way an older build could not read.
    ///
    /// Present from the first version rather than added later, because a format without one
    /// cannot be identified when it needs to be migrated.
    ///
    /// Version 2 added `Turn.Kind.direction`. An older build would read such a turn's kind as
    /// an unknown string and fall back to `.chat`, showing the research moderator's assignment
    /// as though it were a contribution to the argument — a wrong reading of the transcript
    /// rather than a crash, which is exactly the kind of difference the version is here to
    /// catch.
    ///
    /// Version 3 added the report, the research session and the audience's votes. An older
    /// build would reopen a finished investigation without its report — losing the deliverable
    /// and keeping the argument, which is the worst half to be left with.
    public static let currentFormatVersion = 3

    public var formatVersion: Int
    public var id: UUID
    public var topic: String
    public var startedAt: Date
    public var updatedAt: Date
    /// The participants, so a loaded conversation shows the right names and characters.
    public var seats: [StoredSeat]
    public var turns: [StoredTurn]
    /// Why the conversation ended, when it did.
    public var endReason: String?
    /// The deliverable of a research session.
    ///
    /// Optional so a record written before this existed still decodes: a missing key for an
    /// optional property is nil rather than an error, and a decode failure here would make the
    /// whole file unreadable and cost every conversation in it.
    public var report: ResearchReport?
    /// A research session's budget and progress, so a reopened investigation carries on with
    /// the same accounting rather than starting its clock again.
    public var research: ResearchSession?
    /// The audience's verdict on individual contributions.
    public var votes: [AudienceVote]?

    public struct StoredSeat: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var personaID: String?
        public var modelID: String
        public var mode: String
    }

    public struct StoredTurn: Codable, Sendable, Hashable {
        public var id: UUID
        public var sequence: Int
        public var speakerID: String?
        public var speakerName: String
        public var kind: String
        public var content: String
        public var timestamp: Date
        public var toolDetail: String?
    }

    /// A one-line description, for a list of saved conversations.
    public var summary: String {
        let replies = turns.filter { $0.kind == "chat" }.count
        let first = turns.first { $0.kind == "topic" }?.content ?? topic
        let line = first.replacingOccurrences(of: "\n", with: " ")
        let short = line.count > 70 ? String(line.prefix(70)) + "…" : line
        return "\(short) — \(replies) \(replies == 1 ? "reply" : "replies")"
    }
}

/// Saves and loads conversations from a directory.
public struct ConversationStore: Sendable {

    /// Where the conversations live. `.run` by default, which is gitignored, so a
    /// conversation is not accidentally committed — they are private by nature.
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// How many are kept. A conversation is small — a long one is a few hundred kilobytes of
    /// JSON — but an unbounded directory would grow forever, and nobody looks at the hundredth.
    public static let maximumKept = 200

    private var indexURL: URL { directory.appending(path: "conversations.json") }

    // MARK: - Writing

    /// Write a conversation, replacing any earlier save of the same one.
    ///
    /// Keyed by the conversation's id, so a conversation that is saved on every turn produces
    /// one record that grows rather than a new record each time.
    @discardableResult
    public func save(_ conversation: StoredConversation) -> Bool {
        // The version is taken from the record, not stamped over it. Stamping meant every
        // saved record claimed to be the current format, so the check that holds back a
        // newer one could never fire — the test for it passed a future version in and got it
        // straight back. A record's version describes what it contains.
        var record = conversation
        record.updatedAt = .now

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            var all = load()
            if let index = all.firstIndex(where: { $0.id == record.id }) {
                all[index] = record
            } else {
                all.append(record)
            }
            // Newest first when listed, so the order is useful as well as stable.
            all.sort { $0.updatedAt > $1.updatedAt }
            if all.count > Self.maximumKept {
                all = Array(all.prefix(Self.maximumKept))
            }
            try write(all)
            return true
        } catch {
            // Reported by the return value rather than kept as state: the store is a value
            // type used from one place, and a stored error would be one more thing that can be
            // read at the wrong time.
            return false
        }
    }

    private func write(_ all: [StoredConversation]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(all)
        // Written to a neighbour and moved into place, so an interrupted write cannot leave a
        // truncated file where a conversation used to be.
        let temporary = directory.appending(path: "conversations.json.tmp")
        try data.write(to: temporary, options: .atomic)
        _ = try? FileManager.default.removeItem(at: indexURL)
        try FileManager.default.moveItem(at: temporary, to: indexURL)
    }

    // MARK: - Reading

    /// Every saved conversation, newest first.
    public func load() -> [StoredConversation] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let all = try? decoder.decode([StoredConversation].self, from: data) else {
            // A corrupt file returns nothing rather than throwing, and `isUnreadable` says
            // which it was: "there are none" and "the file cannot be read" need different
            // answers, and silently conflating them loses work without saying so.
            return []
        }
        // Anything from a newer format is kept but not offered: a later build may understand
        // it, and dropping it here would destroy work.
        return all.filter { $0.formatVersion <= StoredConversation.currentFormatVersion }
    }

    /// Just the summaries, which is what a list needs.
    public func list() -> [StoredConversation] { load() }

    /// Whether the saved file exists but cannot be read.
    ///
    /// A caller that cares about losing work can tell this apart from an empty history.
    public var isUnreadable: Bool {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return false }
        guard let data = try? Data(contentsOf: indexURL) else { return true }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([StoredConversation].self, from: data)) == nil
    }

    public func conversation(id: UUID) -> StoredConversation? {
        load().first { $0.id == id }
    }

    public func delete(id: UUID) -> Bool {
        var all = load()
        let before = all.count
        all.removeAll { $0.id == id }
        guard all.count != before else { return false }
        do {
            try write(all)
            return true
        } catch {
            return false
        }
    }

    public func deleteAll() {
        try? FileManager.default.removeItem(at: indexURL)
    }
}

// MARK: - Turning a conversation into a record and back

extension StoredConversation {

    /// Capture a conversation as it stands.
    public init(
        id: UUID, conversation: Conversation, seats: [AgentSpec], startedAt: Date,
        endReason: String? = nil
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.id = id
        self.topic = conversation.topic
        self.startedAt = startedAt
        self.updatedAt = .now
        self.endReason = endReason
        self.report = conversation.report
        self.research = conversation.research
        self.votes = conversation.votes.isEmpty ? nil : conversation.votes
        self.seats = seats.map { spec in
            StoredSeat(
                id: spec.id, name: spec.displayName, personaID: spec.personaID,
                modelID: spec.modelID, mode: spec.mode.rawValue)
        }
        self.turns = conversation.turns.map { turn in
            StoredTurn(
                id: turn.id, sequence: turn.sequence, speakerID: turn.speakerID,
                speakerName: turn.speakerName, kind: turn.kind.rawValue,
                content: turn.content, timestamp: turn.timestamp,
                toolDetail: turn.toolDetail)
        }
    }

    /// Rebuild the turns.
    ///
    /// The seats are *not* applied over the current ones — a loaded conversation's
    /// participants are part of what it was, and overwriting the present roster with them would
    /// change who is in the room because of something read from a file.
    public var turns_: [Turn] {
        turns.map { stored in
            Turn(
                id: stored.id,
                sequence: stored.sequence,
                speakerID: stored.speakerID,
                speakerName: stored.speakerName,
                kind: Turn.Kind(rawValue: stored.kind) ?? .chat,
                content: stored.content,
                toolDetail: stored.toolDetail,
                timestamp: stored.timestamp)
        }
    }

    public func conversation() -> Conversation {
        Conversation(
            topic: topic, turns: turns_, research: research, report: report,
            votes: votes ?? [])
    }
}
