// ChatBotsCore — the words the director reads: sub-question keywords and basis markers
//
// Split out of `ResearchDirector.swift`, which held the transcript reading, the director's output
// types and the decision rules in one 791-line file. What lives here is the matching half of the
// rules: which sub-questions a contribution names, whether it gives a basis, and how well an
// analyst's declared method fits a subject. The code did not change.

import Foundation

extension ResearchDirector {

    /// Which sub-questions a contribution is about, from its wording.
    ///
    /// Every subject the text actually names is returned, not only the first: a contribution
    /// about cost and regulation is genuinely about both, and silently dropping one would leave
    /// the director asking for something the room had already raised. What keeps that from
    /// becoming a claim on a paragraph of ordinary prose is decided in two other places. The
    /// match must begin a word — see `mentions` — so "law" no longer matches "flaw" or
    /// "outlaw", "source" no longer matches "resource" and "figure" no longer matches
    /// "configure". And `ResearchReading.read` counts a subject as covered only when the
    /// contribution that names it also gives a basis for what it says, so an unsourced
    /// assertion is a mention rather than coverage.
    ///
    /// The doc comment here used to claim the opposite rule — "the first match in the enum's
    /// order is taken" — which the code never implemented. It is corrected rather than obeyed:
    /// taking only the first match would under-read a contribution, and the over-reading it was
    /// meant to prevent is handled where coverage is recorded.
    public static func subQuestions(in text: String) -> [ResearchSubQuestion] {
        let lowered = text.lowercased()
        return ResearchSubQuestion.allCases.filter { question in
            keywords(for: question).contains { mentions($0, in: lowered) }
        }
    }

    /// Whether a marker occurs in `lowered` at the start of a word.
    ///
    /// The markers are short and several are fragments of ordinary words, so a bare
    /// `contains` read a paragraph about a "flaw", a "resource" or a "configuration" as
    /// covering regulation and evidence. Requiring the marker to begin a word is what closes
    /// that: the character before it must not be a letter or a digit.
    ///
    /// The end is deliberately not anchored. The markers are stems — "assum", "competitor",
    /// "customer", "regulat" is not one but "regulation" is — and "assumptions", "competitors"
    /// and "customers" are plainly the same subject as the stem. Anchoring the end would trade
    /// one kind of false positive for a larger number of false negatives.
    ///
    /// `"%"` is the one marker that is punctuation rather than a word, so it is matched only
    /// where a number is attached to it — the only place it states a magnitude. A bare "%"
    /// with no number in front of it does not.
    private static func mentions(_ marker: String, in lowered: String) -> Bool {
        var searchStart = lowered.startIndex
        while let range = lowered.range(of: marker, range: searchStart..<lowered.endIndex) {
            let before =
                range.lowerBound == lowered.startIndex
                ? nil : lowered[lowered.index(before: range.lowerBound)]
            if marker == "%" {
                if before?.isNumber == true { return true }
            } else if before.map({ !$0.isLetter && !$0.isNumber }) ?? true {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func keywords(for question: ResearchSubQuestion) -> [String] {
        switch question {
        case .evidence:
            [
                "evidence", "data shows", "study", "report says", "according to", "figure",
                "source", "measured",
            ]
        case .magnitude:
            [
                "market size", "how many", "how much", "billion", "million", "percent", "%",
                "growth", "volume", "scale", "estimate",
            ]
        case .economics:
            [
                "cost", "margin", "cash", "return", "roi", "capital", "profit", "revenue",
                "unit economics", "payback", "price",
            ]
        case .competition:
            [
                "competitor", "rival", "market share", "incumbent", "entrant", "who else",
                "competitive",
            ]
        case .feasibility:
            [
                "feasible", "can be built", "technically", "engineering", "lead time", "supply",
                "capacity", "infrastructure", "constraint",
            ]
        case .humanBehaviour:
            [
                "customer", "user", "behaviour", "behavior", "psychology", "adoption",
                "willingness to pay", "incentive", "segment",
            ]
        case .regulation:
            [
                "regulation", "regulatory", "law", "legal", "compliance", "permit", "licence",
                "license", "standard requires",
            ]
        case .outlook:
            [
                "scenario", "forecast", "next year", "by 20", "future", "outlook", "trajectory",
                "over time",
            ]
        case .assumptions:
            ["assum", "we take it", "given that", "if we take", "premise", "presuppos"]
        case .methodology:
            [
                "sample", "method", "correlation", "causal", "confound", "bias", "significant",
                "confidence", "interval", "does not establish", "cannot conclude",
            ]
        }
    }

    /// Whether a contribution gives a basis for its claims.
    ///
    /// Anything that cites, measures, or states an assumption as one. A claim with none of
    /// those is not necessarily wrong — it may simply be an opinion — but it is not evidence,
    /// and the investigation should not build on it as though it were.
    ///
    /// Each marker must be a whole word, and the inflections that count are listed rather than
    /// inherited from a shared prefix. The bare `contains` version was looser than it read:
    /// "statistic" matched "statistically", so a sentence with no source at all qualified as
    /// basis-bearing. That looseness became load-bearing — all coverage now rests on this —
    /// which is why it is tightened rather than left.
    public static func hasBasis(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return basisMarkers.contains { wholeWord($0, in: lowered) }
    }

    /// The sub-question an assignment named, read from the wording a transcript was written
    /// with *before* `Turn.unaddressedSubject` existed.
    ///
    /// This is a migration and not the rule. Directions the director writes now carry the
    /// marker, so a copy edit or a localisation of the instruction cannot change what the
    /// reading sees. The phrase below is the historical wording, kept only so a
    /// conversation saved by an older build still reads the way it did; it is deliberately not
    /// shared with the emitter, because sharing it is exactly the coupling the marker removed.
    public static func legacyUnaddressedSubject(in content: String) -> ResearchSubQuestion? {
        ResearchSubQuestion.allCases.first {
            content.contains("Nothing so far has addressed \($0.label)")
        }
    }

    /// The words that count as a basis. Inflections are explicit: "estimated" and "estimates"
    /// are here, "statistically" deliberately is not, and the bare noun "report" is not either —
    /// "Report says" with nothing behind it is the unsourced case, which is why the original list
    /// carried "reported" rather than "report".
    private static let basisMarkers = [
        "according to", "source", "sources", "sourced", "reported",
        "data", "study", "survey", "surveys", "filing", "filings",
        "measured", "estimate", "estimates", "estimated", "figure", "figures",
        "statistic", "statistics", "statistical", "research",
        "assume", "assumes", "assumed", "assuming", "assumption", "assumptions",
        "on the basis", "because it",
    ]

    /// Whether a marker occurs in `lowered` as a whole word.
    ///
    /// Unlike `mentions`, both ends are anchored. `mentions` serves the subject keywords, whose
    /// stems are meant to match ("customer", "customers"); a basis marker is a word the sentence
    /// actually uses, and a longer word that merely starts with one is a different claim.
    private static func wholeWord(_ marker: String, in lowered: String) -> Bool {
        var searchStart = lowered.startIndex
        while let range = lowered.range(of: marker, range: searchStart..<lowered.endIndex) {
            let before =
                range.lowerBound == lowered.startIndex
                ? nil : lowered[lowered.index(before: range.lowerBound)]
            let after =
                range.upperBound == lowered.endIndex
                ? nil : lowered[range.upperBound]
            let boundaryBefore = before.map { !$0.isLetter && !$0.isNumber } ?? true
            let boundaryAfter = after.map { !$0.isLetter && !$0.isNumber } ?? true
            if boundaryBefore && boundaryAfter { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// Which roles are equipped for which sub-question.
    ///
    /// The analyst's declared domain, matched against the question's vocabulary. This is the
    /// "assign the task to the analyst whose method fits" job, made concrete.
    ///
    /// The match begins a word, the same rule coverage uses, rather than a bare substring: "law"
    /// used to match "flaw" and "source" used to match "resource" when deciding which seat is
    /// asked, which is a poorer question rather than a false claim. Exposed as a
    /// function of a role so the scoring rule can be tested directly, rather than only through
    /// the seat it happens to choose.
    public static func affinity(of role: AnalystRole, for question: ResearchSubQuestion) -> Int {
        let haystack = "\(role.domain) \(role.method) \(role.preferredData)".lowercased()
        return keywords(for: question).reduce(0) { total, needle in
            total + (mentions(needle.lowercased(), in: haystack) ? 1 : 0)
        }
    }
}
