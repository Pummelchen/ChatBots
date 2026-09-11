// ChatBotsCoreTests — the rhythm of a group chat
//
// Every rule here is invisible when it breaks. A name on every message, a picture beside each
// one, no gaps between speakers, a date line on every row — all of it renders perfectly and
// none of it looks like a conversation. So the grouping is asserted rather than eyeballed.

import ChatBotsCore
import Foundation
import Testing

private let noon = Date(timeIntervalSince1970: 1_760_000_000)

private func row(
    _ shape: ThreadGrouping.Shape, _ speaker: String?, _ offset: TimeInterval = 0
) -> ThreadGrouping.Row {
    ThreadGrouping.Row(shape: shape, speaker: speaker, at: noon.addingTimeInterval(offset))
}

private let locale = Locale(identifier: "en_GB")

@Suite("Grouping a thread")
struct ThreadGroupingTests {

    @Test("A run from one speaker is named once and pictured once")
    func aRunIsNameThenBubblesThenPicture() {
        // Three messages from one person: the name goes above the first, the picture beside the
        // last, and the middle one is bare. This is the whole shape of a group chat.
        let flags = ThreadGrouping.flags(
            for: [row(.theirs, "a", 0), row(.theirs, "a", 30), row(.theirs, "a", 60)],
            now: noon, locale: locale)

        #expect(flags.map(\.opensRun) == [true, false, false])
        #expect(flags.map(\.closesRun) == [false, false, true])
        // No air inside the run, and none above its first message either: it is the top of the
        // thread, so there is nothing above it to separate from.
        #expect(flags.map(\.startsGroup) == [false, false, false])
    }

    @Test("A change of speaker gets air and a new name")
    func speakersAreSeparated() {
        let flags = ThreadGrouping.flags(
            for: [row(.theirs, "a"), row(.theirs, "b", 30)],
            now: noon, locale: locale)

        #expect(flags[1].opensRun, "the second speaker needs naming again")
        #expect(flags[1].startsGroup, "and air above them")
        #expect(flags[0].closesRun, "and the first needs their picture")
        #expect(!flags[0].startsGroup, "the first in the thread has nothing to separate from")
    }

    @Test("A return to an earlier speaker is a new run")
    func returningIsANewRun() {
        // A, B, A. The second A is not a continuation of the first — nothing groups across
        // somebody else's message, and the name has to come back or the reader has to scroll.
        let flags = ThreadGrouping.flags(
            for: [row(.theirs, "a"), row(.theirs, "b", 30), row(.theirs, "a", 60)],
            now: noon, locale: locale)
        #expect(flags.map(\.opensRun) == [true, true, true])
        #expect(flags.map(\.closesRun) == [true, true, true])
    }

    @Test("The human's own messages never group together")
    func yourOwnMessagesStandAlone() {
        // Two messages from you in a row are two separate things you said, not one run: there is
        // no name to draw and no picture, so grouping them would only flatten the spacing.
        let flags = ThreadGrouping.flags(
            for: [row(.mine, nil), row(.mine, nil, 30)],
            now: noon, locale: locale)
        // Nothing groups, so both are whole runs — and the second gets air above it, which is
        // the only thing distinguishing two messages from one.
        #expect(flags.allSatisfy { $0.opensRun && $0.closesRun })
        #expect(!flags[0].startsGroup, "the first row of a thread separates from nothing")
        #expect(flags[1].startsGroup)
    }

    @Test("A system line is its own group and never carries a date")
    func systemLinesStandAlone() {
        let flags = ThreadGrouping.flags(
            for: [
                row(.theirs, "a"), row(.system, nil, 30), row(.theirs, "a", 60),
            ],
            now: noon, locale: locale)

        #expect(flags[1].opensRun && flags[1].closesRun)
        #expect(flags[1].divider == nil, "a date in the middle of the app's notes is a line about nothing")
        // And the run is broken by it: the analyst's second message is named again, because the
        // system line between them means it is not visually continuous.
        #expect(flags[2].opensRun)
    }

    @Test("A date line appears at the start and after a long silence")
    func dateLinesAppearWhenTimePasses() {
        let flags = ThreadGrouping.flags(
            for: [
                row(.theirs, "a", 0),
                row(.theirs, "a", 60),                 // a minute later: no line
                row(.theirs, "b", 60 + 21 * 60),       // 21 minutes later: a line
                row(.theirs, "b", 60 + 22 * 60),       // and then not again
            ],
            now: noon, locale: locale)

        #expect(flags[0].divider != nil, "the thread says when it started")
        #expect(flags[1].divider == nil)
        #expect(flags[2].divider != nil)
        #expect(flags[3].divider == nil, "one line per silence, not per message")
    }

    @Test("A date line only goes above the first message of a run")
    func dateLinesGoAboveTheFirstOfARun() {
        // A long silence inside a run: the line belongs above the run's first message, which has
        // already gone by, so nothing is drawn rather than a line in the middle of one person.
        let flags = ThreadGrouping.flags(
            for: [row(.theirs, "a", 0), row(.theirs, "a", 40 * 60)],
            now: noon, locale: locale)
        #expect(flags[0].divider != nil)
        #expect(flags[1].divider == nil)
    }

    @Test("Today's date line is a time, yesterday says so, older says the day")
    func dividerWording() {
        let now = noon
        let today = ThreadGrouping.divider(now.addingTimeInterval(-600), now: now, locale: locale)
        #expect(today.contains(":"), "today is a clock time: \(today)")
        #expect(!today.lowercased().contains("yesterday"))

        let yesterday = ThreadGrouping.divider(
            Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now,
            now: now, locale: locale)
        #expect(yesterday.hasPrefix("Yesterday"))

        let lastWeek = ThreadGrouping.divider(now.addingTimeInterval(-4 * 24 * 3600), now: now, locale: locale)
        #expect(lastWeek.contains(":"), "still has a time")
        #expect(!lastWeek.hasPrefix("Yesterday"))

        let old = ThreadGrouping.divider(now.addingTimeInterval(-40 * 24 * 3600), now: now, locale: locale)
        #expect(old.contains(":"))
        // A month-old line names the date rather than the weekday, which would be ambiguous.
        #expect(!old.lowercased().contains("yesterday"))
    }

    @Test("Every turn kind maps to one of the three shapes")
    func shapesAreTotal() {
        // The mapping is exhaustive in the type system, but a *wrong* mapping is a layout bug
        // rather than a compile error: the human's own words drawn as somebody else's message.
        #expect(ThreadGrouping.shape(of: .topic) == .mine)
        #expect(ThreadGrouping.shape(of: .steering) == .mine)
        #expect(ThreadGrouping.shape(of: .chat) == .theirs)
        for kind in [Turn.Kind.direction, .summary, .report, .introduction, .tool] {
            #expect(ThreadGrouping.shape(of: kind) == .system)
        }
    }

    @Test("Flags line up with the rows they describe")
    func flagsArePositional() {
        // A single missing flag would shift every bubble in the thread by one, so the count is
        // worth asserting rather than assuming.
        var rows: [ThreadGrouping.Row] = []
        for index in 0..<12 {
            let shape: ThreadGrouping.Shape = index % 3 == 0 ? .system : .theirs
            let speaker = index % 2 == 0 ? "a" : "b"
            rows.append(row(shape, speaker, Double(index) * 30))
        }
        #expect(ThreadGrouping.flags(for: rows, now: noon, locale: locale).count == rows.count)
        #expect(ThreadGrouping.flags(for: [], now: noon, locale: locale).isEmpty)
    }
}
