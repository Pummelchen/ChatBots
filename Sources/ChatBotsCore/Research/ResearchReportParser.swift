// ChatBotsCore — reading the moderator's report back out of its markdown
//
// Split out of `ResearchReport.swift`, which held the report, the instruction that produces it and
// the parser that reads it back. This half is the tolerant reader: it accepts the ways a model
// varies a heading, a label or an attribution, and records what it found rather than refusing the
// report. The prompt is in `ResearchReporting.swift`.

import Foundation

extension ResearchReporting {
    /// Parse a model's markdown report into the structured form.
    ///
    /// Tolerant by design. A model that returns a slightly different heading, or writes a
    /// finding without a label, still produced something worth keeping; the parser records
    /// what it found and the report says what is missing. Refusing a whole report because one
    /// heading was worded differently would throw away the work of the entire session.
    /// What the session reports about itself, as opposed to what the model wrote.
    ///
    /// Grouped so `parse` stays inside its parameter budget, and because these six values travel
    /// together: they are the report's factual frame, and the model's text is the only other input.
    public struct SessionFacts: Sendable {
        public var question: String
        public var participants: [String]
        public var stopReason: String
        public var budgetSummary: String
        public var rounds: Int
        public var searches: Int
        public var producedAt: Date

        public init(
            question: String, participants: [String], stopReason: String, budgetSummary: String,
            rounds: Int, searches: Int, producedAt: Date = .now
        ) {
            self.question = question
            self.participants = participants
            self.stopReason = stopReason
            self.budgetSummary = budgetSummary
            self.rounds = rounds
            self.searches = searches
            self.producedAt = producedAt
        }
    }

    public static func parse(_ text: String, facts: SessionFacts) -> ResearchReport {
        let question = facts.question
        let participants = facts.participants
        let stopReason = facts.stopReason
        let budgetSummary = facts.budgetSummary
        let rounds = facts.rounds
        let searches = facts.searches
        let producedAt = facts.producedAt
        var sections: [ResearchReport.Section] = []
        var currentTitle = "Executive Summary"
        var currentLines: [String] = []
        var currentStatements: [ResearchStatement] = []

        // A response can echo the prompt instead of following it. See
        // `strippedBoundaryEcho` for why that region is not report content.
        let text = strippedBoundaryEcho(text)

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
            let body =
                line.hasPrefix("- ") || line.hasPrefix("* ")
                ? String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                : line
            if body.isEmpty { continue }

            if let statement = parseStatement(body, participants: participants) {
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
        let cleaned =
            title
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
        for required in ResearchReport.requiredSections
        where normalise(required) == normalised
            || normalised.hasPrefix(normalise(required))
        {
            return required
        }
        // An unrecognised heading is kept as written, so nothing is lost — it just will not
        // count as one of the required sections.
        return title
    }

    /// Read a label off the front of a claim, if there is one.
    static func parseStatement(_ body: String, participants: [String] = []) -> ResearchStatement? {
        // Strip the markdown emphasis the prompt's own example uses, so "**FACT:**" and
        // "FACT:" are both understood.
        let cleaned =
            body
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
        return ResearchStatement(
            basis: basis, text: text, attribution: attribution(in: text, participants: participants))
    }

    // MARK: Reading an attribution out of a claim

    /// Who a claim is attributed to, from the ways a writer actually attributes one.
    ///
    /// Tolerant, for the same reason the rest of the parser is: a model that attributes in a
    /// shape nobody anticipated still produced a claim worth keeping, and the worst outcome is
    /// calling it unattributed rather than losing it. What the parser will not do is guess
    /// between two named analysts — a claim that mentions the Economist and the Statistician is
    /// left unattributed, because picking one would be inventing provenance rather than reading
    /// it.
    static func attribution(in text: String, participants: [String]) -> String? {
        guard !participants.isEmpty else { return nil }

        // A trailing slot is unambiguous, and wins over a name in the body: a claim can discuss
        // several analysts and still end with "— Economist".
        if let trailing = trailingAttribution(in: text) {
            return participants.first { $0.lowercased() == trailing.lowercased() } ?? trailing
        }

        let lowered = text.lowercased()
        let mentioned = participants.filter { lowered.contains($0.lowercased()) }
        return mentioned.count == 1 ? mentioned[0] : nil
    }

    /// A name in a trailing slot: "… — Economist", "… (Economist)", "… [Economist]".
    private static func trailingAttribution(in text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, ".,;:!?".contains(last) { trimmed.removeLast() }

        if let last = trimmed.last, last == "]" || last == ")" {
            let open: Character = last == "]" ? "[" : "("
            if let start = trimmed.lastIndex(of: open) {
                let inner = String(trimmed[trimmed.index(after: start)..<trimmed.index(before: trimmed.endIndex)])
                let candidate = inner.trimmingCharacters(in: .whitespaces)
                if isNameLike(candidate) { return candidate }
            }
        }

        // An em dash or en dash, which is what a writer reaches for to hang an attribution off
        // a sentence. A plain hyphen is not accepted: "cost - return trade-off" ends in prose,
        // and reading that as a name would manufacture an invented attribution out of nothing.
        for dash in ["—", "–"] {
            guard let range = trimmed.range(of: dash, options: .backwards) else { continue }
            let candidate = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if isNameLike(candidate) { return candidate }
        }
        return nil
    }

    /// Whether a trailing fragment reads as a name rather than as the rest of a sentence.
    ///
    /// Every word capitalised, at most four of them, no sentence punctuation. This is the check
    /// that keeps "— the capital cost was never measured" from being read as an analyst called
    /// "the capital cost was never measured".
    private static func isNameLike(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= 60 else { return false }
        guard !candidate.contains("."), !candidate.contains(","), !candidate.contains(";") else {
            return false
        }
        let words = candidate.split(separator: " ")
        guard (1...4).contains(words.count) else { return false }
        return words.allSatisfy { $0.first?.isUppercase == true }
    }
}
