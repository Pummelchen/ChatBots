// ChatBotsCore — how a transcript is grouped for a chat view
//
// A group chat draws identity with *spacing*: consecutive messages from one person sit tight
// together, the name appears once above the first of them, the picture sits beside the last,
// and a change of speaker gets air. None of that is a property of a single message — every one
// of those decisions is about a message's *neighbours* — which is why it lives here as one pure
// function over the whole thread rather than as a question each row asks the list.
//
// It lives in the core rather than in the view because it is arithmetic, not drawing, and
// because getting it wrong is invisible: a name that appears on every message, or an avatar
// beside each one, still renders perfectly — it just stops looking like a conversation. That is
// exactly the kind of thing a test catches and a screenshot does not.

import Foundation

public enum ThreadGrouping {

    /// How one row is drawn. A group chat has exactly three shapes.
    public enum Shape: Equatable, Sendable {
        /// The human's own message: their side, their colour, no name and no picture.
        case mine
        /// Another participant: the other side, with a name and a picture.
        case theirs
        /// The application speaking — a condensed history, a report, the moderator assigning
        /// work. Not a message from anybody in the room.
        case system
    }

    /// What the grouping needs to know about one row. Deliberately not a `Turn`: the same rules
    /// apply to a seat that is still generating and has no turn yet.
    public struct Row: Equatable, Sendable {
        public var shape: Shape
        public var speaker: String?
        public var at: Date?

        public init(shape: Shape, speaker: String?, at: Date?) {
            self.shape = shape
            self.speaker = speaker
            self.at = at
        }
    }

    /// What the renderer should do with one row.
    public struct Flags: Equatable, Sendable {
        /// Draw the name above this one, because it opens a run by its speaker.
        public var opensRun: Bool
        /// Draw the picture beside this one, because it closes a run.
        public var closesRun: Bool
        /// Put space above it, because whoever was speaking has changed.
        public var startsGroup: Bool
        /// A date line above it, when enough time has passed to be worth saying.
        public var divider: String?

        public init(opensRun: Bool, closesRun: Bool, startsGroup: Bool, divider: String?) {
            self.opensRun = opensRun
            self.closesRun = closesRun
            self.startsGroup = startsGroup
            self.divider = divider
        }
    }

    /// How long a silence has to be before the thread says when it was.
    ///
    /// Twenty minutes: shorter than that and the gaps are the rhythm of a conversation rather
    /// than something a reader needs told, and a date line every other message is noise.
    public static let dividerInterval: TimeInterval = 20 * 60

    /// Work out the flags for a whole thread.
    ///
    /// `closesRun` has to look forward as well as back, which is the reason this is one pass over
    /// the list and not a question asked per row: a row cannot know that the next one is from
    /// somebody else until it can see it.
    public static func flags(for rows: [Row], now: Date = .now, locale: Locale = .current) -> [Flags] {
        var out: [Flags] = []
        out.reserveCapacity(rows.count)

        for index in rows.indices {
            let row = rows[index]
            let previous = index > 0 ? rows[index - 1] : nil
            let next = index + 1 < rows.count ? rows[index + 1] : nil

            var opensRun = true
            var closesRun = true
            var startsGroup = previous != nil

            if row.shape == .theirs {
                let sameAsPrevious = previous?.shape == .theirs && previous?.speaker == row.speaker
                let sameAsNext = next?.shape == .theirs && next?.speaker == row.speaker
                opensRun = !sameAsPrevious
                closesRun = !sameAsNext
                // Air above means the speaker changed. The first row of a thread has nothing to
                // separate from, so it gets none — the thread's own top padding is its air.
                startsGroup = previous != nil && !sameAsPrevious
            }
            // Nothing groups with one of your own or with a system line: each is a group of its
            // own, because each is a different thing happening.

            var divider: String?
            // Only above the first of a run, and never above a system line: a date in the middle
            // of the app's own notes is a line about nothing.
            if row.shape != .system, opensRun, let when = row.at {
                if let previousAt = previous?.at {
                    if when.timeIntervalSince(previousAt) > dividerInterval {
                        divider = self.divider(when, now: now, locale: locale)
                    }
                } else {
                    divider = self.divider(when, now: now, locale: locale)
                }
            }

            out.append(
                Flags(
                    opensRun: opensRun, closesRun: closesRun, startsGroup: startsGroup,
                    divider: divider))
        }
        return out
    }

    /// Which shape a logged turn is drawn as.
    public static func shape(of kind: Turn.Kind) -> Shape {
        switch kind {
        case .topic, .steering: .mine
        case .chat: .theirs
        case .direction, .summary, .report, .introduction, .tool: .system
        }
    }

    // MARK: Date lines

    /// A date line, the way a messaging app writes one: the time alone for today, "Yesterday"
    /// for yesterday, the weekday inside the last week, and a date beyond that.
    ///
    /// The common case is a conversation that all happened in the last hour, and that case has to
    /// cost one short line rather than a full timestamp on every message.
    public static func divider(_ date: Date, now: Date = .now, locale: Locale = .current) -> String {
        let calendar = Calendar.current
        let time = formatter(locale: locale, template: "j:mm")
        if calendar.isDate(date, inSameDayAs: now) { return time.string(from: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday \(time.string(from: date))"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: now), date > weekAgo {
            return formatter(locale: locale, template: "EEEE j:mm").string(from: date)
        }
        return formatter(locale: locale, template: "d MMM j:mm").string(from: date)
    }

    /// Formatters are expensive to build and this runs for every row of a thread that is redrawn
    /// on every streamed token, so they are cached per template and locale.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    private static func formatter(locale: Locale, template: String) -> DateFormatter {
        let key = "\(locale.identifier)|\(template)"
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[key] { return existing }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        cache[key] = formatter
        return formatter
    }
}
