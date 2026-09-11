// ChatBotsCore — writing the conversation out as plain text
//
// One log, in order, each message once. That is not an accident of the implementation: the
// app keeps a single shared transcript that both seats read and write, so there is nothing
// to de-duplicate when exporting. This writer says so in code — it walks the shared log
// once — and the tests pin it, because it is the property the moderator asked for and the
// one that would break first if the app ever moved to per-seat transcripts.
//
// Formatting lives here rather than in the app so the exact text can be asserted without a
// save panel or a window.

import Foundation

public enum TranscriptWriter {

    /// The timestamp format the moderator asked for: `2026-12-25 13:15:04`.
    ///
    /// Deliberately a fixed format in a fixed locale. The numbers are read individually —
    /// year, month, day — so the same instant must render identically whatever the Mac's
    /// region is set to, and `en_US_POSIX` is the locale that guarantees that.
    public static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// A filename-safe stamp, for the suggested save name. Colons are not usable in a
    /// filename on macOS, so this is a separate format rather than a mangled timestamp.
    public static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: date)
    }

    /// How a speaker is labelled.
    ///
    /// Only the kind and the name, in brackets. The duplicate marker line the log uses
    /// internally is deliberately left out: a marker line for every entry would double the
    /// file's length without adding anything, since the timestamp and name already open
    /// each message.
    public static func label(for turn: Turn) -> String {
        switch turn.kind {
        case .topic: "MODERATOR — TOPIC"
        case .steering: "MODERATOR"
        case .introduction: "SETUP"
        case .summary: "CONDENSED EARLIER DISCUSSION"
        case .tool: "TOOL"
        case .chat: turn.speakerName.uppercased()
        }
    }

    /// The full export, as a String.
    public static func text(
        topic: String,
        turns: [Turn],
        participants: [AgentSpec],
        exportedAt: Date = Date()
    ) -> String {
        var out = ""
        out += "ChatBots — conversation log\n"
        out += "Topic: \(topic.isEmpty ? "(none)" : topic)\n"
        for spec in participants {
            out += "Participant: \(spec.displayName) (\(spec.modelShortName))"
            out += spec.backend == .openAIResponses ? " [\(spec.backend.label)]" : ""
            out += "\n"
        }
        out += "Exported: \(timestamp(exportedAt))\n"

        let logged = turns.filter { $0.kind != .introduction }
        guard !logged.isEmpty else {
            out += "\n(no messages)\n"
            return out
        }

        out += "\n" + String(repeating: "-", count: 72) + "\n"
        for turn in logged {
            out += "\n[\(timestamp(turn.timestamp))] \(label(for: turn))\n"
            out += indent(turn.content)
        }
        out += "\n"
        return out
    }

    /// Indent continuation lines so a multi-line message reads as one entry rather than as
    /// several, which is what a plain paragraph break would suggest.
    private static func indent(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map { "    " + $0 }.joined(separator: "\n") + "\n"
    }

    /// A suggested filename, with the topic where it fits and a timestamp for uniqueness.
    public static func suggestedFilename(topic: String, at date: Date = Date()) -> String {
        var slug = topic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined(separator: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        // Long topics are a filename hazard, so they are shortened rather than refused.
        if slug.count > 60 { slug = String(slug.prefix(60)) }
        let stamp = fileStamp(date)
        return slug.isEmpty ? "ChatBots \(stamp).txt" : "ChatBots \(slug) \(stamp).txt"
    }
}
