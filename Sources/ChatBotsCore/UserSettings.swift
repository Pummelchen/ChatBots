// ChatBotsCore — what the user has set, and how it is reconciled with the app
//
// A value type so the interesting part — defaults, cross-version tolerance, and keeping a
// stored roster consistent with the roster the app supports — is testable without touching
// preferences. The app target owns reading and writing it.

import Foundation

/// Everything the user can change that should survive a relaunch.
public struct UserSettings: Codable, Sendable, Equatable {

    /// Bumped when the shape changes in a way that needs care. An older payload decodes
    /// field by field, so a new field simply takes its default rather than invalidating the
    /// whole file.
    public static let currentVersion = 1

    public var version: Int
    public var topic: String
    public var moderatorDraft: String
    /// Whether the models' thinking blocks are streamed into the panes.
    public var showReasoning: Bool
    /// How many seats this configuration is for, so a 3- or 4-seat room reopens as one.
    ///
    /// Stored separately from the `seats` array because reconciling a stored roster against
    /// what the build supports depends on knowing what was intended: an array of two with a
    /// count of four means "two configured, two to add".
    public var seatCount: Int
    /// Per-seat configuration: model, backend, endpoint, persona, thinking, sampler.
    public var seats: [AgentSpec]
    /// Source material the moderator added, with its text already extracted. Stored rather
    /// than re-read from disk because extraction is the slow part and the original file may
    /// have moved or changed since.
    public var attachments: [AttachedDocument]

    public init(
        version: Int = UserSettings.currentVersion,
        topic: String,
        moderatorDraft: String = "",
        showReasoning: Bool = true,
        seats: [AgentSpec],
        seatCount: Int? = nil,
        attachments: [AttachedDocument] = []
    ) {
        self.version = version
        self.topic = topic
        self.moderatorDraft = moderatorDraft
        self.showReasoning = showReasoning
        self.seats = seats
        self.seatCount = seatCount ?? seats.count
        self.attachments = attachments
    }

    /// Decode field by field, defaulting anything absent.
    ///
    /// Written out rather than synthesised because a synthesised initialiser makes every
    /// non-optional field *required*: adding one field would then make every previously
    /// saved file unreadable, and the user's whole configuration would be silently
    /// replaced by defaults on upgrade. Tolerating absent keys is the difference between
    /// adding a setting and resetting everyone's.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? UserSettings.currentVersion
        self.topic = try container.decodeIfPresent(String.self, forKey: .topic) ?? ""
        self.moderatorDraft = try container.decodeIfPresent(String.self, forKey: .moderatorDraft) ?? ""
        self.showReasoning = try container.decodeIfPresent(Bool.self, forKey: .showReasoning) ?? true
        self.seats = try container.decodeIfPresent([AgentSpec].self, forKey: .seats) ?? []
        // A payload from before the field existed describes as many seats as it holds.
        self.seatCount = try container.decodeIfPresent(Int.self, forKey: .seatCount)
            ?? self.seats.count
        self.attachments = try container.decodeIfPresent([AttachedDocument].self, forKey: .attachments) ?? []
    }

    /// Defaults for a first run, or after a stored payload could not be used.
    public static func defaults(
        topic: String,
        // Named, because this is the first-launch path: a fresh install should open with two
        // participants who have names rather than with "Agent 1" and "Agent 2".
        seats: [AgentSpec] = AgentSpec.SeatRoster.namedSpecs()
    ) -> UserSettings {
        UserSettings(topic: topic, seats: seats)
    }

    /// A stored payload, corrected against what this build supports.
    ///
    /// Nothing here fails the load. A setting that cannot be understood falls back to its
    /// default, because losing a persona is a much smaller problem than refusing to start
    /// or, worse, starting with a seat count the layout cannot draw.
    public func reconciled(supportedSeatCount: Int) -> UserSettings {
        guard supportedSeatCount > 0 else { return self }
        var copy = self
        if copy.seats.count > supportedSeatCount {
            // More seats stored than this build supports: keep the first ones, which are
            // the ones the user configured first.
            copy.seats = Array(copy.seats.prefix(supportedSeatCount))
        } else if copy.seats.isEmpty {
            // A roster with nothing in it gets the default one, named: this is the
            // first-launch path.
            copy.seats = AgentSpec.SeatRoster.namedSpecs()
        } else if copy.seats.count < supportedSeatCount {
            // Fewer than supported: add a default spec for each missing *position*, so a
            // third and fourth seat keep their own ids and styles rather than inheriting
            // someone else's.
            for index in copy.seats.count..<supportedSeatCount {
                copy.seats.append(AgentSpec.seat(index: index))
            }
        }
        copy.version = UserSettings.currentVersion
        return copy
    }

    /// Encode for storage.
    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decode from storage, tolerating a payload written by an older or newer build.
    ///
    /// Returns nil when there is nothing stored. Throws only when something *is* stored and
    /// cannot be read at all, so the caller can tell the user rather than silently starting
    /// fresh.
    public static func decoded(from data: Data) throws -> UserSettings {
        try JSONDecoder().decode(UserSettings.self, from: data)
    }
}
