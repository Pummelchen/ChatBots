// ChatBotsCore — the report a research session produces
//
// The brief is specific about two things here, and both are what make the difference between
// a useful document and a transcript with headings.
//
// **The sections.** An executive summary, findings, evidence, agreement, disagreement,
// assumptions, risks, unknowns, alternative interpretations, options, and what to investigate
// next. That list is a professional's checklist for "can I act on this", and a report missing
// the disagreement and unknown sections is one that hides its own weaknesses.
//
// **The labelling.** Fact, sourced claim, inference, assumption, opinion and scenario are six
// different things, and a report that writes them all in the same voice is not usable by
// someone making a decision. The labels are part of the format, not a stylistic preference.
//
// The synthesis is written by a model — the moderator seat — so this file does two jobs:
// it tells that model exactly what to produce, and it renders and validates the result. The
// validation matters as much as the prompt: a model asked for a labelled report will
// sometimes return one without labels, and a report that silently loses its labels is worse
// than one that visibly lacks them.

import Foundation

/// One labelled claim in the report.
public struct ResearchStatement: Sendable, Hashable, Codable {
    /// The kinds of thing the report is allowed to assert, in the brief's terms.
    ///
    /// Raw values are the words the model is asked to use, so parsing is exact rather than
    /// approximate.
    public enum Basis: String, Sendable, Codable, CaseIterable {
        case fact = "FACT"
        case sourced = "SOURCED"
        case inference = "INFERENCE"
        case assumption = "ASSUMPTION"
        case opinion = "OPINION"
        case scenario = "SCENARIO"

        /// What the label means, for the legend at the top of the report.
        public var explanation: String {
            switch self {
            case .fact: "verifiable and verified"
            case .sourced: "a claim with a named source behind it"
            case .inference: "drawn from evidence rather than stated by it"
            case .assumption: "taken as given; if wrong, the conclusion moves"
            case .opinion: "a judgement, with reasoning but no proof"
            case .scenario: "a possible future, not a prediction"
            }
        }

        /// Whether a decision can rely on this without checking it.
        public var isReliable: Bool { self == .fact || self == .sourced }
    }

    public var basis: Basis
    /// The claim itself.
    public var text: String
    /// Which analyst produced it, so the report identifies who to ask.
    public var attribution: String?

    public init(basis: Basis, text: String, attribution: String? = nil) {
        self.basis = basis
        self.text = text
        self.attribution = attribution
    }
}

/// A finished investigation.
public struct ResearchReport: Sendable, Hashable, Codable {

    /// The sections the brief asks for. Each is a list of lines, kept as plain strings rather
    /// than as structured statements because not every section is a claim — "what to
    /// investigate next" is a task, not an assertion.
    public struct Section: Sendable, Hashable, Codable {
        public var title: String
        public var lines: [String]
        /// Statements carrying a label, where the section holds claims.
        public var statements: [ResearchStatement]

        public init(title: String, lines: [String] = [], statements: [ResearchStatement] = []) {
            self.title = title
            self.lines = lines
            self.statements = statements
        }

        public var isEmpty: Bool { lines.isEmpty && statements.isEmpty }
    }

    public var question: String
    public var sections: [Section]
    public var producedAt: Date
    /// Why the session ended, so the report can say how hard it was pushed.
    public var stopReason: String
    /// How the session was budgeted, for the same reason.
    public var budgetSummary: String
    public var rounds: Int
    public var searches: Int
    /// Analysts who took part, so the report names whose judgement is behind it.
    public var participants: [String]

    public init(
        question: String,
        sections: [Section],
        producedAt: Date = Date.now,
        stopReason: String,
        budgetSummary: String,
        rounds: Int,
        searches: Int,
        participants: [String]
    ) {
        self.question = question
        self.sections = sections
        self.producedAt = producedAt
        self.stopReason = stopReason
        self.budgetSummary = budgetSummary
        self.rounds = rounds
        self.searches = searches
        self.participants = participants
    }

    /// The section titles, in the order the brief lists them.
    public static let requiredSections = [
        "Executive Summary",
        "Key Findings",
        "Evidence",
        "Areas of Agreement",
        "Areas of Disagreement",
        "Important Assumptions",
        "Risks",
        "Unknowns / Evidence Gaps",
        "Alternative Interpretations",
        "Recommendations / Options",
        "What Should Be Investigated Next",
    ]

    /// Statements with no label, which is the failure mode worth checking for.
    ///
    /// A report whose claims are unlabelled cannot be used to make a decision, because the
    /// reader cannot tell a verified fact from a hope. Rather than reject the report — the
    /// findings are still worth having — the count is reported so the interface can say the
    /// labelling is incomplete.
    public var unlabelledStatements: Int {
        sections.reduce(0) { total, section in
            total + section.lines.count
        }
    }

    public var labelledStatements: Int {
        sections.reduce(0) { $0 + $1.statements.count }
    }

    /// Whether the report has the labels that make it usable.
    public var isLabelled: Bool { labelledStatements > 0 }

    /// Sections the brief requires that are missing entirely.
    public var missingSections: [String] {
        let present = Set(sections.map(\.title))
        return Self.requiredSections.filter { !present.contains($0) }
    }

    /// The report as markdown, which is what a front end shows and what Save writes.
    ///
    /// Markdown rather than plain text because the sections and the labels are structure, and
    /// a reader deciding whether to trust a claim needs to see that structure at a glance.
    public func markdown() -> String {
        var out = "# Research Report\n\n"
        out += "**Question:** \(question)\n\n"
        out += "**Produced:** \(ISO8601DateFormatter().string(from: producedAt))\n\n"
        out += "**How far this went:** \(rounds) contributions, \(searches) searches, \(budgetSummary)\n\n"
        out += "**Ended because:** \(stopReason)\n\n"
        if !participants.isEmpty {
            out += "**Analysts:** \(participants.joined(separator: ", "))\n\n"
        }

        out += "---\n\n"
        out += "**Claim labels.** "
        out += ResearchStatement.Basis.allCases
            .map { "\($0.rawValue) = \($0.explanation)" }
            .joined(separator: "; ")
        out += ". Only FACT and SOURCED can be relied on without checking.\n\n"

        for section in sections where !section.isEmpty {
            out += "## \(section.title)\n\n"
            for statement in section.statements {
                let who = statement.attribution.map { " _— \($0)_" } ?? ""
                out += "- **\(statement.basis.rawValue):** \(statement.text)\(who)\n"
            }
            for line in section.lines {
                out += "- \(line)\n"
            }
            out += "\n"
        }

        if !missingSections.isEmpty {
            // Said out loud rather than quietly omitted: a report that is thin in one area is
            // usable, one that hides it is not.
            out += "## Not covered\n\n"
            out += "This investigation did not produce material for: "
            out += missingSections.joined(separator: ", ") + ".\n"
        }
        return out
    }
}

public enum ResearchReporting {

    /// The instruction handed to the moderator seat to write the report.
    ///
    /// Deliberately prescriptive about format and deliberately silent about content: the
    /// moderator has the whole transcript and is being asked to organise it, not to add to it.
    /// A prompt that encouraged it to reason further would produce a report containing claims
    /// no analyst made, which is the one thing a synthesis must not do.
    public static func synthesisPrompt(
        question: String,
        participants: [String],
        stopReason: String,
        transcript: String
    ) -> String {
        let sections = ResearchReport.requiredSections
            .enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        return """
            You are the Research Moderator. The investigation is finished and your job now is \
            to write the report. You are organising what the analysts found, not adding to it.

            The question was: \(question)
            The analysts were: \(participants.joined(separator: ", "))
            The investigation ended because: \(stopReason)

            Write the report with exactly these sections, in this order, using the headings \
            verbatim:

            \(sections)

            Rules that make this usable:

            - Every claim in Key Findings, Evidence, Assumptions and Risks must begin with one \
              of these labels in capitals, followed by a colon: FACT, SOURCED, INFERENCE, \
              ASSUMPTION, OPINION, SCENARIO.
            - Use FACT only for something verifiable and verified. Use SOURCED only when a \
              specific source was named. If you are not sure which a claim is, it is an \
              INFERENCE or an ASSUMPTION — say so rather than overclaiming.
            - Attribute findings to the analyst who produced them, by name.
            - Areas of Disagreement must be honest. If the analysts genuinely disagreed and it \
              was not resolved, say so plainly; a report that presents a contested conclusion \
              as settled is worse than useless.
            - Unknowns / Evidence Gaps must name what nobody could establish, and what would \
              settle it.
            - Recommendations / Options should be options with their trade-offs, not a single \
              instruction. The reader decides; you inform.
            - Do not invent a source, a number or a finding that is not in the transcript. If \
              a section has nothing behind it, write "Nothing established."

            The transcript follows.

            \(transcript)
            """
    }

    /// Parse a model's markdown report into the structured form.
    ///
    /// Tolerant by design. A model that returns a slightly different heading, or writes a
    /// finding without a label, still produced something worth keeping; the parser records
    /// what it found and the report says what is missing. Refusing a whole report because one
    /// heading was worded differently would throw away the work of the entire session.
    public static func parse(
        _ text: String,
        question: String,
        participants: [String],
        stopReason: String,
        budgetSummary: String,
        rounds: Int,
        searches: Int,
        producedAt: Date = Date.now
    ) -> ResearchReport {
        var sections: [ResearchReport.Section] = []
        var currentTitle = "Executive Summary"
        var currentLines: [String] = []
        var currentStatements: [ResearchStatement] = []

        func flush() {
            guard !currentLines.isEmpty || !currentStatements.isEmpty else { return }
            sections.append(
                ResearchReport.Section(
                    title: currentTitle, lines: currentLines, statements: currentStatements))
            currentLines = []
            currentStatements = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // A heading, however many hashes the model used.
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    flush()
                    currentTitle = canonicalTitle(title)
                    continue
                }
            }
            guard !line.isEmpty else { continue }
            let body = line.hasPrefix("- ") || line.hasPrefix("* ")
                ? String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                : line
            if body.isEmpty { continue }

            if let statement = parseStatement(body) {
                currentStatements.append(statement)
            } else {
                currentLines.append(body)
            }
        }
        flush()

        // A model that returned prose without headings still produced a summary; keep it
        // rather than losing the whole session's work.
        if sections.isEmpty {
            let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                sections = [ResearchReport.Section(title: "Executive Summary", lines: [fallback])]
            }
        }

        return ResearchReport(
            question: question,
            sections: sections,
            producedAt: producedAt,
            stopReason: stopReason,
            budgetSummary: budgetSummary,
            rounds: rounds,
            searches: searches,
            participants: participants)
    }

    /// Match a heading to the required one, tolerating the ways a model varies it.
    static func canonicalTitle(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        // "Unknowns & Evidence Gaps", "unknowns/evidence gaps" and "Unknowns and Evidence
        // Gaps" are all the same section. The separators are replaced with " and " including
        // the spaces: replacing the character alone turned "unknowns/evidence" into
        // "unknownsand evidence", which matched nothing.
        func normalise(_ value: String) -> String {
            value
                .replacingOccurrences(of: "&", with: " and ")
                .replacingOccurrences(of: "/", with: " and ")
                .split(separator: " ")
                .joined(separator: " ")
                .lowercased()
        }
        let normalised = normalise(cleaned)
        for required in ResearchReport.requiredSections where normalise(required) == normalised
            || normalised.hasPrefix(normalise(required))
        {
            return required
        }
        // An unrecognised heading is kept as written, so nothing is lost — it just will not
        // count as one of the required sections.
        return title
    }

    /// Read a label off the front of a claim, if there is one.
    static func parseStatement(_ body: String) -> ResearchStatement? {
        // Strip the markdown emphasis the prompt's own example uses, so "**FACT:**" and
        // "FACT:" are both understood.
        let cleaned = body
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let colon = cleaned.firstIndex(of: ":") else { return nil }
        let label = cleaned[cleaned.startIndex..<colon]
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        guard let basis = ResearchStatement.Basis(rawValue: label) else { return nil }
        let text = cleaned[cleaned.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return ResearchStatement(basis: basis, text: text)
    }
}
