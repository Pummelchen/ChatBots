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
// The synthesis is written by a model — the moderator seat — so the report is paired with two other
// files: `ResearchReporting.swift` states what to produce and fences the untrusted transcript, and
// `ResearchReportParser.swift` reads back what the model returned. The validation matters as much
// as the prompt: a model asked for a labelled report will sometimes return one without labels, and
// a report that silently loses its labels is worse than one that visibly lacks them.

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
    ///
    /// Filled by the parser from the ways a writer actually attributes a claim — a trailing
    /// "— Economist", a "(Statistician)", or a single analyst named in the sentence. It is the
    /// name **as written**, which may be somebody who was not in the room; whether it names a
    /// real analyst is a question about the report rather than about the statement, because it
    /// needs the participant list, so it is answered by `ResearchReport.inventedAttributions`.
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

    /// The sections the brief requires labels on.
    ///
    /// `reportRules` names them: "Every claim in Key Findings, Evidence, Assumptions and Risks
    /// must begin with one of these labels". A line in any other section is prose, a task or a
    /// narrative, and not labelling it is not the failure being counted. The parser keeps an
    /// unrecognised heading as written, so both the required title and the short form a model
    /// actually writes are included.
    public static let claimSections: Set<String> = [
        "Key Findings", "Evidence", "Assumptions", "Important Assumptions", "Risks",
    ]

    /// Claims with no label, which is the failure mode worth checking for.
    ///
    /// A report whose claims are unlabelled cannot be used to make a decision, because the
    /// reader cannot tell a verified fact from a hope. Rather than reject the report — the
    /// findings are still worth having — the count is reported so the interface can say the
    /// labelling is incomplete, and `isLabelled` is false while any claim is unlabelled.
    ///
    /// Only lines in the sections the brief requires labels on are counted. A sentence of
    /// executive summary is not a claim, and counting it made the number meaningless: a report
    /// could carry fifty bare assertions in Key Findings and still read as labelled because the
    /// prose outnumbered them.
    public var unlabelledStatements: Int {
        sections.reduce(0) { total, section in
            total + (Self.claimSections.contains(section.title) ? section.lines.count : 0)
        }
    }

    public var labelledStatements: Int {
        sections.reduce(0) { $0 + $1.statements.count }
    }

    /// Whether the report has the labels that make it usable.
    ///
    /// Every claim in a claim-bearing section is labelled, and there is at least one. A report
    /// with one labelled claim and fifty bare assertions beside it is not labelled, which the
    /// old `labelledStatements > 0` said it was.
    public var isLabelled: Bool { labelledStatements > 0 && unlabelledStatements == 0 }

    /// Sections the brief requires that are missing entirely.
    public var missingSections: [String] {
        let present = Set(sections.map(\.title))
        return Self.requiredSections.filter { !present.contains($0) }
    }

    // MARK: Traceability

    /// Claims that name nobody, so the reader cannot tell who to ask about them.
    ///
    /// The moderator's evidence standard is that every finding must be traceable to a named
    /// analyst. A synthesis is the one document where an unattributed claim is dangerous: it
    /// reads exactly like a finding, and there is no analyst behind it to check with.
    public var unattributedStatements: Int {
        sections.reduce(0) { total, section in
            total + section.statements.filter { $0.attribution == nil }.count
        }
    }

    /// Attributions naming somebody who was not among the analysts, in the order they appear.
    ///
    /// A model asked to attribute its findings will sometimes supply a plausible author. Naming
    /// them is the point: an invented attribution is worse than none, because it looks like
    /// provenance.
    public var inventedAttributions: [String] {
        let known = Set(participants.map { $0.lowercased() })
        var seen: [String] = []
        for section in sections {
            for statement in section.statements {
                guard let who = statement.attribution, !known.contains(who.lowercased()),
                    !seen.contains(where: { $0.lowercased() == who.lowercased() })
                else { continue }
                seen.append(who)
            }
        }
        return seen
    }

    /// Whether every claim can be traced to an analyst who was actually there.
    ///
    /// Unlabelled claims count against this too. An unlabelled line is exactly the thing a
    /// reader cannot trace: there is no author and no basis attached, so a report that declared
    /// itself traceable while ignoring them was making the claim on the labelled minority.
    public var isTraceable: Bool {
        isLabelled && unattributedStatements == 0 && inventedAttributions.isEmpty
    }

    /// How a claim's author is shown beside it, if it has one worth showing.
    ///
    /// An unreadable author is printed rather than hidden: silently dropping it would leave the
    /// reader unable to see that the model tried to attribute the claim and got it wrong.
    func attributionSuffix(for statement: ResearchStatement) -> String {
        guard let who = statement.attribution else { return " _— unattributed_" }
        let known = participants.contains { $0.lowercased() == who.lowercased() }
        return known ? " _— \(who)_" : " _— \(who) (not an analyst)_"
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
        if !isTraceable {
            // Stated before the findings rather than after them: a reader who has already
            // trusted a claim is not helped by learning at the bottom that it has no author.
            out += "**Traceability.** "
            var problems: [String] = []
            if unlabelledStatements > 0 {
                problems.append(
                    "\(unlabelledStatements) claims carry no label, so a reader cannot tell a "
                        + "fact from an assumption")
            }
            if unattributedStatements > 0 {
                problems.append(
                    "\(unattributedStatements) of \(labelledStatements) claims name no analyst, "
                        + "so there is nobody to check them with")
            }
            if !inventedAttributions.isEmpty {
                problems.append(
                    "these claims name somebody who was not among the analysts: "
                        + inventedAttributions.joined(separator: ", "))
            }
            if problems.isEmpty {
                problems.append("the report has no labelled claims to trace")
            }
            out += problems.joined(separator: "; ") + ".\n\n"
        }

        out += "**Claim labels.** "
        out += ResearchStatement.Basis.allCases
            .map { "\($0.rawValue) = \($0.explanation)" }
            .joined(separator: "; ")
        out += ". Only FACT and SOURCED can be relied on without checking.\n\n"

        for section in sections where !section.isEmpty {
            out += "## \(section.title)\n\n"
            for statement in section.statements {
                let who = attributionSuffix(for: statement)
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
