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
        /// The subject an unaddressed-subject assignment asked the room at.
        ///
        /// Optional, and deliberately not accompanied by a format bump: a decoder ignores a key
        /// it does not know, so an older build reads a record that carries this exactly as it
        /// did before — its own wording match still finds the assignment, because the
        /// instruction text is unchanged — and this build reads a record written before the
        /// field as a nil marker, which is what the reader's legacy fallback exists for. A bump
        /// would make every conversation unreadable to the older build for no gain.
        public var unaddressedSubject: String?
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

    /// How the index file's bytes are read.
    ///
    /// Injected for one test: proving that the decode happens off the main actor needs the read
    /// to be *in flight* while the question is asked, and a read the test controls is the difference
    /// between measuring that and racing it. Nothing in the app sets it; the default is the real read.
    var readIndex: @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }

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
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // The read-modify-write rebuilds the file from every record, so it must see the
            // records `load()` refuses to hand out. Reading through `load()` here dropped
            // anything from a newer format (and treated a corrupt file as empty) and then
            // wrote the survivors back over the file — destroying exactly the work the
            // version check exists to protect.
            //
            // A file that cannot be decoded at all is left completely alone. Writing the
            // records this build happens to understand over bytes it cannot account for would
            // discard conversations it never read, and refusing is the only answer that keeps
            // them; `isUnreadable` already tells a caller this happened.
            guard let existing = readAll() else { return false }
            var all = existing
            if let index = all.firstIndex(where: { $0.id == record.id }) {
                all[index] = record
            } else {
                all.append(record)
            }
            // Newest first when listed, so the order is useful as well as stable.
            all.sort { $0.updatedAt > $1.updatedAt }
            if all.count > Self.maximumKept {
                // Trim only what this build understands. A record from a newer format is not
                // ours to discard, and the cap exists to keep the list short rather than to
                // delete another build's work.
                let unknown = all.filter {
                    $0.formatVersion > StoredConversation.currentFormatVersion
                }
                let known = all.filter {
                    $0.formatVersion <= StoredConversation.currentFormatVersion
                }
                let room = max(0, Self.maximumKept - unknown.count)
                all = Array(known.prefix(room)) + unknown
                all.sort { $0.updatedAt > $1.updatedAt }
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
        // A kept conversation is a private transcript — the topic and everything said in it —
        // so it is written owner-only, the same rule the TLS key follows. `Data.write` has no
        // mode argument, so the mode is set immediately after.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        // One atomic step. This used to remove the index and then move the replacement into its
        // place, which left a window in which there was no index at all: a crash or a failed move
        // there lost every kept conversation, and the complete `.tmp` was never read back — so the
        // history appeared empty rather than damaged. `replaceItemAt` is a rename on APFS,
        // and the branch below only runs on the first save, when there is nothing to replace.
        if FileManager.default.fileExists(atPath: indexURL.path) {
            _ = try FileManager.default.replaceItemAt(indexURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: indexURL)
        }
    }

    // MARK: - Reading

    /// Every saved conversation, newest first.
    ///
    /// A record from a newer format is kept on disk but not offered: a later build may
    /// understand it, and dropping it here would destroy work. "There are none" and "the file
    /// cannot be read" both read as empty here; `isUnreadable` tells them apart.
    public func load() -> [StoredConversation] {
        (readAll() ?? []).filter {
            $0.formatVersion <= StoredConversation.currentFormatVersion
        }
    }

    /// Just the summaries, which is what a list needs.
    public func list() -> [StoredConversation] { load() }

    /// The same read as `list()`, off the main actor.
    ///
    /// The index is one JSON file holding every kept conversation, so reading it decodes them all —
    /// that is the store's shape (a single atomically-replaced file) and this does not change
    /// it. What it changes is *where* the decode happens. Everything that serves a request is on the
    /// main actor, and so is the engine's turn loop, so a share link or a **Kept** list opened while a
    /// conversation was streaming stalled the stream for the length of the decode — hundreds of
    /// milliseconds for a full history. Document conversion was moved off the main actor the same way, for the same
    /// reason.
    ///
    /// The synchronous `list()` and `conversation(id:)` stay: a caller that already runs off the main
    /// actor, and every test, can keep using them.
    public func listOffMainActor() async -> [StoredConversation] {
        await Task.detached(priority: .userInitiated) { self.list() }.value
    }

    /// The conversation with this id, read off the main actor.
    ///
    /// See `listOffMainActor()` for why the read is the expensive part and why it matters which actor
    /// it runs on.
    public func conversationOffMainActor(id: UUID) async -> StoredConversation? {
        await Task.detached(priority: .userInitiated) {
            self.load().first { $0.id == id }
        }.value
    }

    /// Every record in the file, including those this build cannot read.
    ///
    /// `nil` means the file exists but cannot be decoded at all. That is deliberately not the
    /// same as `[]`: a save that treated it as empty would overwrite bytes it never read.
    private func readAll() -> [StoredConversation]? {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            // A store damaged by the earlier write path can be holding the only complete copy of
            // the history in its temporary file, with no index beside it. Read it rather than
            // reporting an empty history, so the repair is automatic for anyone already affected.
            return readTemporary()
        }
        guard let data = readIndex(indexURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([StoredConversation].self, from: data)
    }

    /// The leftover temporary file from an interrupted save, if it decodes and there is no index.
    ///
    /// `nil` means there is nothing usable there, which is the same as there being no file.
    private func readTemporary() -> [StoredConversation]? {
        let temporary = directory.appending(path: "conversations.json.tmp")
        guard FileManager.default.fileExists(atPath: temporary.path) else { return [] }
        // A file that exists but cannot be read is damage, not an empty history: returning
        // `[]` for it let `save` treat it as empty and overwrite the only copy.
        guard let data = readIndex(temporary) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([StoredConversation].self, from: data)
    }

    /// Whether the saved file exists but cannot be read.
    ///
    /// A caller that cares about losing work can tell this apart from an empty history.
    public var isUnreadable: Bool {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            // The state `readTemporary()` exists for: no index, and a temporary that may be
            // damaged. Without this the answer was `false` for exactly that case.
            let temporary = directory.appending(path: "conversations.json.tmp")
            return FileManager.default.fileExists(atPath: temporary.path) && readTemporary() == nil
        }
        return readAll() == nil
    }

    public func conversation(id: UUID) -> StoredConversation? {
        load().first { $0.id == id }
    }

    public func delete(id: UUID) -> Bool {
        // Like `save`, this rebuilds the whole file, so it must carry the records `load()`
        // holds back rather than deleting them as a side effect of removing one conversation.
        // A file that cannot be decoded is left alone for the same reason as in `save`.
        guard let existing = readAll() else { return false }
        var all = existing
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
        // Both files. `readAll()` falls back to the temporary when the index is absent, so
        // removing only the index resurrected the conversations the caller deleted after an
        // interrupted save. A failed removal is reported rather than swallowed.
        let temporary = directory.appending(path: "conversations.json.tmp")
        for url in [indexURL, temporary] where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                FileHandle.standardError.write(
                    Data(
                        "[ChatBots] could not remove \(url.lastPathComponent): \(error.localizedDescription)\n"
                            .utf8))
            }
        }
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
                toolDetail: turn.toolDetail, unaddressedSubject: turn.unaddressedSubject)
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
                unaddressedSubject: stored.unaddressedSubject,
                timestamp: stored.timestamp)
        }
    }

    public func conversation() -> Conversation {
        Conversation(
            topic: topic, turns: turns_, research: research, report: report,
            votes: votes ?? [])
    }
}
