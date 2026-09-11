// ChatBotsCoreTests — the saved log
//
// The moderator asked for one merged log with each message once, stamped with the time.
// Both properties are asserted here rather than eyeballed, because both are the kind of
// thing that looks right in a short conversation and goes wrong in a long one.

import ChatBotsCore
import Foundation
import Testing

@Suite("Transcript export")
struct TranscriptWriterTests {

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }

    private func conversation() -> (topic: String, turns: [Turn], seats: [AgentSpec]) {
        var first = AgentSpec.seat(index: 0)
        first.displayName = "Mira"
        var second = AgentSpec.seat(index: 1)
        second.displayName = "Otto"
        let turns = [
            Turn(
                sequence: 1, speakerName: "Moderator", kind: .topic,
                content: "Why are eggs not round?", timestamp: date("2026-12-25 13:15:04")),
            Turn(
                sequence: 2, speakerName: "System", kind: .introduction,
                content: "This is an open discussion…", timestamp: date("2026-12-25 13:15:04")),
            Turn(
                sequence: 3, speakerID: "Agent 1", speakerName: "Mira", kind: .chat,
                content: "Because of how shells form.", timestamp: date("2026-12-25 13:15:41")),
            Turn(
                sequence: 4, speakerID: "Agent 2", speakerName: "Otto", kind: .chat,
                content: "Which part of that is actually established?",
                timestamp: date("2026-12-25 13:16:02")),
            Turn(
                sequence: 5, speakerName: "Moderator", kind: .steering,
                content: "Stay on the shell question.", timestamp: date("2026-12-25 13:16:30")),
            Turn(
                sequence: 6, speakerID: "Agent 1", speakerName: "Mira", kind: .chat,
                content: "Shell thickness scales with curvature.",
                timestamp: date("2026-12-25 13:17:10")),
        ]
        return ("Why are eggs not round?", turns, [first, second])
    }

    @Test("Timestamps use the requested format")
    func timestampFormat() {
        #expect(TranscriptWriter.timestamp(date("2026-12-25 13:15:04")) == "2026-12-25 13:15:04")
        // Single-digit fields are zero-padded, so the format is fixed width.
        let early = DateComponents(
            calendar: Calendar(identifier: .gregorian), year: 2026, month: 1, day: 5,
            hour: 9, minute: 7, second: 3).date!
        #expect(TranscriptWriter.timestamp(early) == "2026-01-05 09:07:03")
    }

    @Test("The format does not follow the machine's region")
    func timestampIsLocaleIndependent() {
        // A day-first or 12-hour locale must not change the export, since the numbers are
        // read individually.
        let instant = date("2026-12-25 13:15:04")
        let rendered = TranscriptWriter.timestamp(instant)
        #expect(rendered.contains("2026-12-25"))
        #expect(rendered.contains("13:15:04"))
        #expect(!rendered.lowercased().contains("pm"))
    }

    @Test("Every message appears exactly once, merged in one log")
    func messagesAppearOnce() {
        let data = conversation()
        let text = TranscriptWriter.text(
            topic: data.topic, turns: data.turns, participants: data.seats,
            exportedAt: date("2026-12-25 13:20:00"))

        // The messages the two seats addressed to each other are the conversation, not a
        // second copy of it.
        for body in [
            "Because of how shells form.",
            "Which part of that is actually established?",
            "Shell thickness scales with curvature.",
            "Stay on the shell question.",
        ] {
            let occurrences = text.components(separatedBy: body).count - 1
            #expect(occurrences == 1, "\"\(body)\" appears \(occurrences) times")
        }
    }

    @Test("Messages are in chronological order")
    func orderIsChronological() {
        let data = conversation()
        let text = TranscriptWriter.text(
            topic: data.topic, turns: data.turns, participants: data.seats,
            exportedAt: date("2026-12-25 13:20:00"))

        let stamps = text.split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
                return String(line[line.index(after: line.startIndex)..<close])
            }
        #expect(stamps == [
            "2026-12-25 13:15:04", "2026-12-25 13:15:41", "2026-12-25 13:16:02",
            "2026-12-25 13:16:30", "2026-12-25 13:17:10",
        ])
    }

    @Test("Each message is stamped and attributed")
    func messagesAreStampedAndAttributed() {
        let data = conversation()
        let text = TranscriptWriter.text(
            topic: data.topic, turns: data.turns, participants: data.seats,
            exportedAt: date("2026-12-25 13:20:00"))

        #expect(text.contains("[2026-12-25 13:15:04] MODERATOR — TOPIC"))
        #expect(text.contains("[2026-12-25 13:15:41] MIRA"))
        #expect(text.contains("[2026-12-25 13:16:02] OTTO"))
        #expect(text.contains("[2026-12-25 13:16:30] MODERATOR"))
    }

    @Test("The header names the topic and the participants")
    func headerIsInformative() {
        let data = conversation()
        let text = TranscriptWriter.text(
            topic: data.topic, turns: data.turns, participants: data.seats,
            exportedAt: date("2026-12-25 13:20:00"))

        #expect(text.contains("Topic: Why are eggs not round?"))
        #expect(text.contains("Mira (Qwen3.5-4B-4bit)"))
        #expect(text.contains("Otto (Qwen3.5-4B-4bit)"))
        #expect(text.contains("Exported: 2026-12-25 13:20:00"))
    }

    @Test("The setup brief is left out; it is not something anyone said")
    func briefIsExcluded() {
        let data = conversation()
        let text = TranscriptWriter.text(
            topic: data.topic, turns: data.turns, participants: data.seats,
            exportedAt: date("2026-12-25 13:20:00"))
        #expect(!text.contains("This is an open discussion"))
    }

    @Test("A condensation is recorded as replacing the history")
    func summaryIsIncluded() {
        var data = conversation()
        data.turns.append(
            Turn(
                sequence: 7, speakerName: "Condensed", kind: .summary,
                content: "They agreed the mechanism is structural.",
                timestamp: date("2026-12-25 13:18:00")))
        let text = TranscriptWriter.text(
            topic: data.topic, turns: data.turns, participants: data.seats,
            exportedAt: date("2026-12-25 13:20:00"))
        #expect(text.contains("[2026-12-25 13:18:00] CONDENSED EARLIER DISCUSSION"))
        #expect(text.contains("They agreed the mechanism is structural."))
    }

    @Test("A multi-line message stays one entry")
    func multiLineMessageIsIndented() {
        var data = conversation()
        data.turns.append(
            Turn(
                sequence: 7, speakerID: "Agent 1", speakerName: "Mira", kind: .chat,
                content: "First point.\nSecond point.\nThird point.",
                timestamp: date("2026-12-25 13:18:00")))
        let text = TranscriptWriter.text(
            topic: data.topic, turns: data.turns, participants: data.seats,
            exportedAt: date("2026-12-25 13:20:00"))

        // Continuation lines are indented, so the entry still reads as one message.
        #expect(text.contains("    First point.\n    Second point.\n    Third point."))
    }

    @Test("Tool traffic is kept, since it is part of what happened")
    func toolTrafficIsIncluded() {
        var data = conversation()
        data.turns.append(
            Turn(
                sequence: 7, speakerID: "Agent 2", speakerName: "Otto", kind: .tool,
                content: "web_search: 5 results", timestamp: date("2026-12-25 13:18:00")))
        let text = TranscriptWriter.text(
            topic: data.topic, turns: data.turns, participants: data.seats,
            exportedAt: date("2026-12-25 13:20:00"))
        #expect(text.contains("TOOL"))
        #expect(text.contains("web_search: 5 results"))
    }

    @Test("An empty conversation still produces a readable file")
    func emptyConversation() {
        let text = TranscriptWriter.text(
            topic: "Nothing yet", turns: [], participants: AgentSpec.makeSeats(count: 2),
            exportedAt: date("2026-12-25 13:20:00"))
        #expect(text.contains("Topic: Nothing yet"))
        #expect(text.contains("(no messages)"))
    }

    @Test("The suggested filename is usable and carries the topic and a timestamp")
    func suggestedFilename() {
        let name = TranscriptWriter.suggestedFilename(
            topic: "Why are eggs not round? / really!", at: date("2026-12-25 13:15:04"))

        #expect(name.hasSuffix(".txt"))
        #expect(name.contains("2026-12-25 13-15-04"), "colons cannot appear in a filename")
        #expect(!name.contains("/"), "a slash would be read as a path separator")
        #expect(!name.contains("?"))
        #expect(name.contains("Why-are-eggs-not-round"))
    }

    @Test("A very long topic does not produce an unusable filename")
    func longTopicFilename() {
        let name = TranscriptWriter.suggestedFilename(
            topic: String(repeating: "egg ", count: 200), at: date("2026-12-25 13:15:04"))
        #expect(name.count < 120)
        #expect(name.hasSuffix(".txt"))
    }

    @Test("An empty topic still yields a filename")
    func emptyTopicFilename() {
        let name = TranscriptWriter.suggestedFilename(topic: "   ", at: date("2026-12-25 13:15:04"))
        #expect(name.hasPrefix("ChatBots "))
        #expect(name.hasSuffix(".txt"))
    }

    @Test("The export is valid UTF-8 that round-trips")
    func exportIsValidUTF8() {
        var data = conversation()
        data.turns.append(
            Turn(
                sequence: 7, speakerID: "Agent 1", speakerName: "Mira", kind: .chat,
                content: "Grüße! café, naïve, 日本語, Ελληνικά, العربية, 🥚🐣",
                timestamp: date("2026-12-25 13:18:00")))
        let text = TranscriptWriter.text(
            topic: "Grüße 🥚", turns: data.turns, participants: data.seats,
            exportedAt: date("2026-12-25 13:20:00"))

        let bytes = Data(text.utf8)
        #expect(String(data: bytes, encoding: .utf8) == text)
        #expect(text.contains("日本語"))
        #expect(text.contains("🥚"))
        #expect(!text.contains("\u{FFFD}"))
    }
}
