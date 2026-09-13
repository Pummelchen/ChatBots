// ChatBotsCore — the Moderator directing the investigation
//
// The Moderator had a job description but no job: it wrote the synthesis at the end and had no
// influence on how the investigation got there. Turn order was a rotation, so a question that
// needed the Statistician heard from whoever was next, and a disagreement nobody could settle
// was never named as one.
//
// This is the missing part — the decisions a research lead actually makes, in code:
//
//   · **What is still unanswered.** The question is divided into sub-questions, and each
//     contribution is read for which of them it addresses. What is left is what the
//     investigation still owes.
//   · **Who should be asked.** Not the next seat in the rotation: the analyst whose method
//     fits an open sub-question and who has not already been heard from on it.
//   · **Where the analysts conflict.** Two analysts making incompatible claims about the same
//     sub-question is a disagreement worth naming, and worth pointing the next turn at.
//   · **What is unsupported.** A contribution that makes a claim with no basis attached — no
//     source, no measurement, no stated assumption — is flagged, and the next turn is asked
//     to substantiate it rather than build on it.
//   · **What is redundant.** An analyst repeating a position already made, on a sub-question
//     that is settled, is not given the floor to do it again.
//
// **What it deliberately does not do.** It does not decide whether an argument is *persuasive*.
// That judgement is not available from text structure, and a director that guessed wrong would
// close off the very line of enquiry worth pursuing. It reads what is plainly there —
// addressed or not, sourced or not, agreed or contradicted — and directs on that. The same
// restraint as the entertainment conflict reader, for the same reason.

import Foundation

/// What the investigation needs next, and why.
public struct ResearchDirection: Sendable, Equatable {
    /// The analyst to hear from, by seat id. Nil means the rotation stands.
    public var seatID: String?
    /// What the moderator is asking for, in its own words, to be given to that analyst.
    public var instruction: String
    /// What the director did, for the log — a decision nobody can see is a decision nobody can
    /// disagree with.
    public var reason: String
    /// Which sub-question this turn is aimed at.
    public var subQuestion: String?

    public var isDirected: Bool { seatID != nil }
}

/// The sub-questions a research topic divides into.
///
/// Held as patterns rather than a model call: this decides who speaks next, several times a
/// minute, and a model call per turn to ask "what should we ask next" would cost more than the
/// turn it is scheduling. The patterns are the questions a professional investigation asks of
/// any subject, and the wording is deliberately broad so that a contribution about, say,
/// "capital intensity" is recognised as being about cost.
public enum ResearchSubQuestion: String, Sendable, CaseIterable, Codable {
    /// Is it true? What does the evidence actually show?
    case evidence
    /// How big, how many, how much — and how confident can we be?
    case magnitude
    /// What does it cost, what does it return?
    case economics
    /// Who else is doing this, and what will they do about it?
    case competition
    /// Can it be built, and what would it take?
    case feasibility
    /// Who is affected, and what will they actually do?
    case humanBehaviour
    /// What is permitted or required?
    case regulation
    /// What happens next, and what would change the answer?
    case outlook
    /// What have we assumed that has not been checked?
    case assumptions
    /// How reliable is the reasoning, whatever the answer?
    case methodology

    public var label: String {
        switch self {
        case .evidence: "what the evidence supports"
        case .magnitude: "how large or how many"
        case .economics: "the economics — cost against return"
        case .competition: "who else is there and what they will do"
        case .feasibility: "whether it can be done"
        case .humanBehaviour: "what people will actually do"
        case .regulation: "what is permitted or required"
        case .outlook: "what happens next"
        case .assumptions: "which assumptions are load-bearing"
        case .methodology: "whether the evidence supports the conclusion"
        }
    }
}

/// What has happened so far in an investigation, read from the transcript.
///
/// Kept apart from the director itself so the decision can be tested against a hand-written
/// state and the reading can be tested against a hand-written transcript, instead of every
/// test having to construct both and hope the failure was in the part it cared about.
public enum ResearchReading {

    /// Read a transcript into the state the director decides from.
    ///
    /// Nothing here is inferred beyond what the text shows: which sub-questions a contribution
    /// touched, whether it gave a basis, whether it was aimed at someone else's claim on the
    /// same sub-question. Signals come from `ConflictReader`, the same reader the entertainment
    /// mode uses, rather than from a second set of phrase lists that would drift out of step
    /// with the first.
    ///
    /// Coverage is recorded only from contributions that gave a basis, and only once the room
    /// has engaged: a subject one seat named with a basis is a mention, not an answer, and is
    /// covered only when a second seat names it or a seat answers the moderator's assignment on
    /// it. A keyword in an unsourced assertion stays open, because a mention is not an answer and
    /// the director should not stop pointing at a gap just because the gap was named.
    ///
    /// Two passes, because a gap has to be read *after* the room responds to it. A claim with
    /// no basis, or a disagreement, stays in the record for the rest of the session; without
    /// the second pass the director would take the first one it ever found and ask about it
    /// again every turn until the budget ran out, which is the opposite of directing.
    @MainActor
    public static func read(seats: [AgentSpec], turns: [Turn]) -> ResearchDirector {
        // Analysts only. A read of the room that counted the moderator's own directions as
        // contributions would conclude the moderator was the most productive analyst.
        let declared = seats.filter { spec in
            spec.mode == .research
                && AnalystLibrary.role(id: spec.personaID).id == spec.personaID
                && spec.personaID != AnalystLibrary.moderatorID
        }
        // A research line-up where nobody has been given an analyst role still gets directed;
        // it just gets directed without the benefit of knowing who is equipped for what. The
        // alternative — silently doing nothing — is the failure this whole file exists to fix.
        let analysts = declared.isEmpty
            ? seats.filter { $0.mode == .research && $0.personaID != AnalystLibrary.moderatorID }
            : declared
        let analystIDs = Set(analysts.map(\.id))
        let names = seats.map(\.displayName)

        var contributions: [String: Int] = [:]
        /// Basis-bearing mentions, before the room-engagement rule below is applied.
        var named: [ResearchSubQuestion: Set<String>] = [:]
        /// Subjects the moderator has pointed the room at with a "nothing so far has addressed"
        /// assignment, so the response to that assignment counts even from one seat.
        var directed: Set<ResearchSubQuestion> = []
        /// Subjects a directed assignment was answered on.
        var directedCovered: Set<ResearchSubQuestion> = []
        /// A disagreement, and the contribution that raised it.
        var marks: [ResearchSubQuestion: (parties: [String], sequence: Int)] = [:]
        /// A claim with nothing behind it, and where it was made.
        var gaps: [(seatID: String, claim: String, sequence: Int)] = []
        /// Which seat last made a claim on each sub-question, so a challenge can be paired with
        /// what it challenged.
        var lastClaimant: [ResearchSubQuestion: String] = [:]
        var agreed: Set<ResearchSubQuestion> = []
        var disputedLater: Set<ResearchSubQuestion> = []

        // ── Pass one: what was said. ──────────────────────────────────────────────────
        // Read in log order: pairing a challenge with the claim it answers only works
        // left-to-right, and a settled question is one that was agreed *and not* reopened.
        for turn in turns {
            // A direction the app itself wrote, asking the room at a subject nobody has
            // addressed. Recorded so the answer to it counts as engagement below. The
            // instruction for an unanswered subject begins with a fixed phrase, which is what
            // identifies it without adding a field to `Turn`.
            if turn.kind == .direction {
                for question in ResearchSubQuestion.allCases
                where turn.content.contains("Nothing so far has addressed \(question.label)") {
                    directed.insert(question)
                }
                continue
            }
            guard turn.kind == .chat,
                let seatID = turn.speakerID, analystIDs.contains(seatID)
            else { continue }
            contributions[seatID, default: 0] += 1

            let questions = ResearchDirector.subQuestions(in: turn.content)
            // A subject is *named* only by a contribution that also says what it is relying on.
            //
            // A keyword in an unsourced paragraph is a mention, not an answer, and treating a
            // mention as coverage is what let a couple of paragraphs read as the whole question
            // addressed. The relationship and conflict reads below still use every subject the
            // text names, because pairing a challenge with what it answered is about what was
            // said rather than about what was evidenced.
            if ResearchDirector.hasBasis(turn.content) {
                for question in questions {
                    named[question, default: []].insert(seatID)
                    if directed.contains(question) { directedCovered.insert(question) }
                }
            }

            let signals = ConflictReader.signals(
                in: turn.content,
                from: seatID,
                others: names,
                addressing: nil)

            // Both reads must agree. The reader's signal is the precise one — it needs a
            // certainty phrase and no evidence — and `hasBasis` is the broader marker list, so
            // requiring it to be false as well is what keeps a short methodological remark from
            // being chased as though it were a claim. Flagging on either alone made almost
            // every contribution a gap, and a director that finds a gap everywhere directs
            // nowhere: it asks the same question until the budget runs out.
            if signals.contains(where: { $0.kind == .unsupportedClaim }),
                !ResearchDirector.hasBasis(turn.content)
            {
                // Named by its own opening, so the direction can quote what it is about
                // rather than describing it.
                let claim = ConflictReader.summary(of: turn.content)
                    ?? turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
                gaps.append((seatID: seatID, claim: claim, sequence: turn.sequence))
            }

            let isDisagreement = signals.contains { $0.kind == .contradiction || $0.kind == .challenge }
            for question in questions {
                if isDisagreement, let other = lastClaimant[question], other != seatID {
                    var parties = marks[question]?.parties ?? []
                    if !parties.contains(other) { parties.append(other) }
                    if !parties.contains(seatID) { parties.append(seatID) }
                    marks[question] = (parties, turn.sequence)
                    disputedLater.insert(question)
                }
                if signals.contains(where: { $0.kind == .agreement }) {
                    agreed.insert(question)
                }
                lastClaimant[question] = seatID
            }
        }

        // Coverage is the room's engagement, not one seat's mention (audit A95). A subject that
        // one contribution named with a basis is a mention, however well sourced: text matching
        // cannot tell "the room worked through the cost question" from "someone wrote a sentence
        // containing the word cost", and a single sentence naming all ten subjects used to close
        // a session as fully answered. A subject therefore counts as covered when more than one
        // seat has named it with a basis — the room took it up — or when it is the subject the
        // moderator asked about and a seat answered that assignment. Coverage is not made
        // unreachable by this: the director keeps pointing at the gap until the room responds.
        var covered: [ResearchSubQuestion: Set<String>] = [:]
        for (question, seatIDs) in named
        where seatIDs.count >= 2 || directedCovered.contains(question) {
            covered[question] = seatIDs
        }


        // ── Pass two: what the room did about it. ────────────────────────────────────
        // "Addressed" is not "resolved". The director cannot see whether a claim was actually
        // checked, and does not pretend to; it stops asking once the room has taken the
        // question up. Reading the response is what separates directing from repeating.

        /// Whether someone else has since worked on this sub-question at all. The standard is
        /// deliberately loose — a contribution that merely touches methodology counts — because
        /// the alternative is a director that keeps demanding the same check until the budget
        /// runs out, which is the failure mode this pass exists to prevent.
        func takenUp(_ question: ResearchSubQuestion, after sequence: Int, by seatID: String?) -> Bool {
            turns.contains { turn in
                turn.kind == .chat
                    && turn.sequence > sequence
                    && turn.speakerID.map { analystIDs.contains($0) && $0 != seatID } == true
                    && ResearchDirector.subQuestions(in: turn.content).contains(question)
            }
        }

        /// Whether someone has since brought material, conceded, or contested the point again.
        /// Any of the three means the disagreement is being worked on rather than ignored, so
        /// it does not need the moderator to assign it a second time.
        func advanced(_ question: ResearchSubQuestion, after sequence: Int) -> Bool {
            turns.contains { turn in
                guard turn.kind == .chat, turn.sequence > sequence,
                    let speaker = turn.speakerID, analystIDs.contains(speaker),
                    ResearchDirector.subQuestions(in: turn.content).contains(question)
                else { return false }
                return ConflictReader.signals(
                    in: turn.content, from: speaker, others: names, addressing: nil
                ).contains { $0.kind == .newEvidence || $0.kind == .concession || $0.kind == .contradiction }
            }
        }

        let unsupported = gaps
            .filter { !takenUp(.methodology, after: $0.sequence, by: $0.seatID) }
            .map { (seatID: $0.seatID, claim: $0.claim) }

        var conflicts: [ResearchSubQuestion: [String]] = [:]
        for (question, mark) in marks.sorted(by: { $0.value.sequence < $1.value.sequence }) {
            guard !advanced(question, after: mark.sequence) else { continue }
            conflicts[question] = mark.parties
        }

        // A question where the room agreed and nobody has since objected. Agreement on a claim
        // that was then challenged is not agreement.
        let settled = agreed.subtracting(disputedLater)
        // Who spoke most recently, so the moderator does not ask someone to answer themselves.
        let lastSpeaker = turns.last { $0.kind == .chat }?.speakerID
        return ResearchDirector(
            seats: seats,
            contributions: contributions,
            covered: covered,
            conflicts: conflicts,
            unsupported: unsupported,
            settled: settled,
            lastSpeakerID: lastSpeaker,
            analystIDs: analystIDs)
    }
}

/// Decides what the investigation needs next.
///
/// Not an LLM: a set of rules over what has been said. That is a deliberate limit. The
/// judgement this makes is structural — covered or not, sourced or not, contradicted or not —
/// and rules are honest about structural facts. Whether a finding is *good* is left to the
/// analysts, who are told to argue about it.
@MainActor
public struct ResearchDirector: Sendable {

    /// The analysts available, by seat.
    public var seats: [AgentSpec]
    /// How many contributions each seat has made.
    public var contributions: [String: Int]
    /// Which sub-questions the room has taken up, and which seats named each with a basis.
    ///
    /// The key is present only once the room has engaged — more than one seat named the subject
    /// with a basis, or a seat answered the moderator's assignment on it — so a single sourced
    /// sentence naming every subject does not close the investigation (audit A95).
    public var covered: [ResearchSubQuestion: Set<String>]
    /// Sub-questions where two analysts have made incompatible claims.
    public var conflicts: [ResearchSubQuestion: [String]]
    /// Claims with no basis attached — no source, no measurement, no stated assumption.
    public var unsupported: [(seatID: String, claim: String)]
    /// Sub-questions the moderator considers settled, because several analysts agree.
    public var settled: Set<ResearchSubQuestion>
    /// Who spoke last, so the moderator does not ask an analyst to answer themselves. Nil on a
    /// fresh investigation, which is also when nobody has spoken.
    public var lastSpeakerID: String?
    /// The seats that do the investigating, as decided when the transcript was read.
    ///
    /// Held rather than re-derived, so the reading and the decision cannot disagree about who
    /// counts as an analyst — the same role-and-string guess made in two places is how one copy
    /// drifts. Empty means "work it out from the declared roles", which is what a hand-built
    /// director in a test relies on.
    public var analystIDs: Set<String>

    public init(
        seats: [AgentSpec] = [], contributions: [String: Int] = [:],
        covered: [ResearchSubQuestion: Set<String>] = [:],
        conflicts: [ResearchSubQuestion: [String]] = [:],
        unsupported: [(seatID: String, claim: String)] = [], settled: Set<ResearchSubQuestion> = [],
        lastSpeakerID: String? = nil, analystIDs: Set<String> = []
    ) {
        self.seats = seats
        self.contributions = contributions
        self.covered = covered
        self.conflicts = conflicts
        self.unsupported = unsupported
        self.settled = settled
        self.lastSpeakerID = lastSpeakerID
        self.analystIDs = analystIDs
    }

    /// The first sub-question the room has not taken up.
    public var unanswered: ResearchSubQuestion? {
        ResearchSubQuestion.allCases.first { (covered[$0] ?? []).isEmpty }
    }

    /// Whether the moderator has anything left that it would point the room at.
    ///
    /// Deliberately *not* the same question as `direction().seatID == nil`. That is nil in two
    /// different situations — the investigation is complete, or the only analyst who fits the
    /// open question has just spoken — and they need opposite answers. "Not now" must not end a
    /// research session; "nothing left" is the best reason there is to end one.
    ///
    /// The bar is deliberately high: every one of the ten subjects the room has taken up, no
    /// unsupported claim outstanding, no live disagreement, and nobody sitting idle. Coverage
    /// here is the engaged kind recorded by `ResearchReading.read`: a subject one seat named with
    /// a basis is still open until a second seat names it or a seat answers the moderator's
    /// assignment on it, and an unsourced mention leaves it open too. A run that clears all four
    /// has nothing the moderator can usefully point at, and spending its remaining budget would
    /// only restate findings nobody disputes.
    public var hasOpenWork: Bool {
        if !unsupported.isEmpty { return true }
        if conflicts.contains(where: { !settled.contains($0.key) }) { return true }
        if unanswered != nil { return true }
        if quietestSeatIgnoring(settledQuestions: settled) != nil { return true }
        return false
    }

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
            let before = range.lowerBound == lowered.startIndex
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
            ["evidence", "data shows", "study", "report says", "according to", "figure",
             "source", "measured"]
        case .magnitude:
            ["market size", "how many", "how much", "billion", "million", "percent", "%",
             "growth", "volume", "scale", "estimate"]
        case .economics:
            ["cost", "margin", "cash", "return", "roi", "capital", "profit", "revenue",
             "unit economics", "payback", "price"]
        case .competition:
            ["competitor", "rival", "market share", "incumbent", "entrant", "who else",
             "competitive"]
        case .feasibility:
            ["feasible", "can be built", "technically", "engineering", "lead time", "supply",
             "capacity", "infrastructure", "constraint"]
        case .humanBehaviour:
            ["customer", "user", "behaviour", "behavior", "psychology", "adoption",
             "willingness to pay", "incentive", "segment"]
        case .regulation:
            ["regulation", "regulatory", "law", "legal", "compliance", "permit", "licence",
             "license", "standard requires"]
        case .outlook:
            ["scenario", "forecast", "next year", "by 20", "future", "outlook", "trajectory",
             "over time"]
        case .assumptions:
            ["assum", "we take it", "given that", "if we take", "premise", "presuppos"]
        case .methodology:
            ["sample", "method", "correlation", "causal", "confound", "bias", "significant",
             "confidence", "interval", "does not establish", "cannot conclude"]
        }
    }

    /// Whether a contribution gives a basis for its claims.
    ///
    /// Anything that cites, measures, or states an assumption as one. A claim with none of
    /// those is not necessarily wrong — it may simply be an opinion — but it is not evidence,
    /// and the investigation should not build on it as though it were.
    public static func hasBasis(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = [
            "according to", "source", "reported", "data", "study", "survey", "filing",
            "measured", "estimate", "figure", "statistic", "research", "i assume",
            "assumption", "assuming", "we assume", "on the basis", "because it",
        ]
        return markers.contains { lowered.contains($0) }
    }

    /// What to do next.
    ///
    /// The order of the checks is the order of what most needs doing. An unsupported claim
    /// comes first because everything built on it inherits the problem; then a live conflict,
    /// because an investigation that walks past a disagreement produces a report that lists
    /// views; then an unanswered sub-question; and otherwise the rotation stands, which is the
    /// honest answer when there is nothing in particular to direct.
    public func direction() -> ResearchDirection {
        // 1. A claim carried without a basis, from someone who has already spoken on it.
        // Skipped rather than reassigned when the only analyst equipped to check it is the one
        // who just spoke: asking someone to answer themselves is not a direction, and the gap
        // is still there next round.
        if let gap = unsupported.first, let seat = seatFor(.methodology) {
            let name = displayName(gap.seatID)
            return ResearchDirection(
                seatID: seat,
                instruction:
                    """
                    \(name) made a claim without a basis: "\(gap.claim.prefix(140))". \
                    Establish whether it holds, and say what it would take to check it. If it \
                    cannot be checked, say that plainly rather than letting it stand.
                    """,
                reason: "a claim from \(name) has no evidence attached",
                subQuestion: ResearchSubQuestion.methodology.rawValue)
        }

        // 2. Two analysts disagreeing about the same thing.
        //
        // The sub-questions are walked in their declaration order rather than by iterating the
        // dictionary, whose order depends on the per-process hash seed. This function promises
        // that "the same investigation state should direct the same way", so a saved transcript
        // must direct the same sub-question and analyst on every launch (audit A74).
        if let question = ResearchSubQuestion.allCases.first(where: {
                conflicts[$0] != nil && !settled.contains($0)
            }),
            let parties = conflicts[question],
            let seat = seatFor(question)
        {
            let names = parties.map(displayName).joined(separator: " and ")
            return ResearchDirection(
                seatID: seat,
                instruction:
                    """
                    \(names) have made incompatible claims about \(question.label). \
                    Establish which is better supported and on what basis, or state clearly \
                    what would settle it and what is missing.
                    """,
                reason: "\(names) conflict on \(question.label)",
                subQuestion: question.rawValue)
        }

        // 3. Something nobody has looked at.
        if let question = unanswered, let seat = seatFor(question) {
            return ResearchDirection(
                seatID: seat,
                instruction:
                    """
                    Nothing so far has addressed \(question.label). Address it, and say what \
                    you are relying on.
                    """,
                reason: "\(question.label) has not been covered",
                subQuestion: question.rawValue)
        }

        // 4. Someone who has barely been heard from, on a question the room has stopped
        // arguing about, is worth the floor more than a rotation that happens to be next.
        if let quietest = quietestSeatIgnoring(settledQuestions: settled) {
            return ResearchDirection(
                seatID: quietest,
                instruction:
                    """
                    You have contributed least so far. Say what your method adds that the \
                    others' cannot, and what you would want checked before the conclusion is \
                    relied on.
                    """,
                reason: "\(displayName(quietest)) has contributed least",
                subQuestion: nil)
        }

        // 5. Nothing in particular to direct. Either the investigation has nothing left, or the
        // open question went to whoever could take it last turn and there is nobody else who
        // fits it. The rotation is the honest answer to both; the two are told apart here only
        // so the log says which one it was.
        return ResearchDirection(
            seatID: nil,
            instruction: "",
            reason: hasOpenWork
                ? "the open question has just gone to whoever fits it; the rotation stands"
                : "nothing outstanding; the rotation stands",
            subQuestion: nil)
    }

    /// The analyst role a seat is on, when it is on one.
    private func role(for spec: AgentSpec) -> AnalystRole? {
        guard spec.mode == .research else { return nil }
        let id = spec.personaID
        guard !id.isEmpty else { return nil }
        let found = AnalystLibrary.role(id: id)
        // `role(id:)` falls back to a default for an unknown id, so an id that is not an
        // analytics role must be rejected explicitly rather than taken as one.
        return found.id == id ? found : nil
    }

    private func isAnalyst(_ spec: AgentSpec) -> Bool { role(for: spec) != nil }

    private func displayName(_ seatID: String) -> String {
        seats.first { $0.id == seatID }?.displayName ?? seatID
    }

    /// The seat whose method fits a sub-question, preferring one that has not covered it.
    ///
    /// Nil when the only analyst who fits it is the one who just spoke. Nil means "not now"
    /// rather than "nobody": every caller falls through to the next check, or to the rotation,
    /// so a skipped assignment costs a turn of delay and never a turn of silence.
    private func seatFor(_ question: ResearchSubQuestion) -> String? {
        let fitting = rankedSeats(for: question)
        if let pick = fitting.first(where: { $0.id != lastSpeakerID }) { return pick.id }
        return nil
    }

    private func rankedSeats(for question: ResearchSubQuestion) -> [AgentSpec] {
        let analysts = analystIDs.isEmpty
            ? seats.filter { isAnalyst($0) && $0.personaID != AnalystLibrary.moderatorID }
            : seats.filter { analystIDs.contains($0.id) }
        // Everyone is a candidate, not only those who have already spoken. An earlier version
        // preferred seats with a contribution to their name, which quietly reduced the pool to
        // one seat on the second turn and made the moderator stop directing after the first —
        // the exact failure this file exists to fix. Fit is what decides, and `affinity` is
        // what measures it; having spoken before is not a qualification.
        let notYetOnIt = analysts.filter { !(covered[question] ?? []).contains($0.id) }
        let pool = notYetOnIt.isEmpty ? analysts : notYetOnIt
        // Deterministic rather than random: the same investigation state should direct the
        // same way, so a run can be read afterwards and understood.
        return pool.sorted { lhs, rhs in
            let left = affinity(lhs, for: question)
            let right = affinity(rhs, for: question)
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
    }

    /// Which roles are equipped for which sub-question.
    ///
    /// The analyst's declared domain, matched against the question's vocabulary. This is the
    /// "assign the task to the analyst whose method fits" job, made concrete.
    private func affinity(_ spec: AgentSpec, for question: ResearchSubQuestion) -> Int {
        guard let role = role(for: spec) else { return 0 }
        let haystack = "\(role.domain) \(role.method) \(role.preferredData)".lowercased()
        let needles = Self.keywords(for: question).map { $0.lowercased() }
        var score = needles.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
        // The moderator is never assigned analytical work; it directs and synthesises.
        if role.id == AnalystLibrary.moderatorID { score -= 100 }
        return score
    }

    private func quietestSeatIgnoring(settledQuestions: Set<ResearchSubQuestion>) -> String? {
        let analysts = analystIDs.isEmpty
            ? seats.filter { isAnalyst($0) && $0.personaID != AnalystLibrary.moderatorID }
            : seats.filter { analystIDs.contains($0.id) }
        guard analysts.count > 1 else { return nil }
        // Whoever just spoke is not behind, they are merely recent; asking them to catch up
        // with themselves would be nonsense.
        let ranked = analysts.sorted { lhs, rhs in
            let left = contributions[lhs.id] ?? 0
            let right = contributions[rhs.id] ?? 0
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
        guard let pick = ranked.first(where: { $0.id != lastSpeakerID }) else { return nil }
        // Only worth redirecting if that seat is genuinely behind, not level with the rest.
        let most = analysts.map { contributions[$0.id] ?? 0 }.max() ?? 0
        guard most - (contributions[pick.id] ?? 0) >= 1 else { return nil }
        return pick.id
    }
}
