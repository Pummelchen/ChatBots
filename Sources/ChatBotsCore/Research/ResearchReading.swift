// ChatBotsCore — reading an investigation's transcript into the state the director decides from
//
// Split out of `ResearchDirector.swift`, which held the transcript reading, the director's output
// types and the decision rules in one 791-line file. The reading is kept apart from the director so
// the decision can be tested against a hand-written state and the reading against a hand-written
// transcript. The code did not change.

import Foundation

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
        let analysts = analysts(in: seats)
        let analystIDs = Set(analysts.map(\.id))
        let names = seats.map(\.displayName)
        let said = passOne(turns: turns, analystIDs: analystIDs, names: names)
        let covered = coverage(of: said.named, directedCovered: said.directedCovered)
        let unsupported = unsupportedGaps(said.gaps, turns: turns, analystIDs: analystIDs)
        let conflicts = unresolvedConflicts(
            said.marks, turns: turns, analystIDs: analystIDs, names: names)

        // A question where the room agreed and nobody has since objected. Agreement on a claim
        // that was then challenged is not agreement.
        let settled = said.agreed.subtracting(said.disputedLater)
        // Who spoke most recently, so the moderator does not ask someone to answer themselves.
        let lastSpeaker = turns.last { $0.kind == .chat }?.speakerID
        return ResearchDirector(
            seats: seats,
            contributions: said.contributions,
            covered: covered,
            conflicts: conflicts,
            unsupported: unsupported,
            settled: settled,
            lastSpeakerID: lastSpeaker,
            analystIDs: analystIDs)
    }

    // MARK: - The room's analysts

    /// The seats whose contributions count as analyst work.
    ///
    /// Analysts only. A read of the room that counted the moderator's own directions as
    /// contributions would conclude the moderator was the most productive analyst.
    @MainActor
    private static func analysts(in seats: [AgentSpec]) -> [AgentSpec] {
        let declared = seats.filter { spec in
            spec.mode == .research
                && AnalystLibrary.role(id: spec.personaID).id == spec.personaID
                && spec.personaID != AnalystLibrary.moderatorID
        }
        // A research line-up where nobody has been given an analyst role still gets directed;
        // it just gets directed without the benefit of knowing who is equipped for what. The
        // alternative — silently doing nothing — is the failure this whole file exists to fix.
        guard declared.isEmpty else { return declared }
        return seats.filter { $0.mode == .research && $0.personaID != AnalystLibrary.moderatorID }
    }

    // MARK: - Pass one: what was said

    /// Everything pass one collected, so the reading can be split across helpers.
    private struct Said {
        /// Contributions per seat id.
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
    }

    /// Read the turns in log order.
    ///
    /// Pairing a challenge with the claim it answers only works left-to-right, and a settled
    /// question is one that was agreed *and not* reopened.
    @MainActor
    private static func passOne(turns: [Turn], analystIDs: Set<String>, names: [String]) -> Said {
        var said = Said()
        for turn in turns {
            read(turn, into: &said, analystIDs: analystIDs, names: names)
        }
        return said
    }

    /// Read one turn into the record.
    @MainActor
    private static func read(
        _ turn: Turn, into said: inout Said, analystIDs: Set<String>, names: [String]
    ) {
        // A direction the app itself wrote, asking the room at a subject nobody has
        // addressed. Recorded so the answer to it counts as engagement below. Which
        // assignment it was is carried on the turn as `unaddressedSubject`, so editing
        // the instruction's wording cannot change what the reading sees; a
        // turn written before that field existed is still read from its wording, once,
        // by `legacyUnaddressedSubject`.
        if turn.kind == .direction {
            recordDirection(turn, directed: &said.directed)
            return
        }
        guard turn.kind == .chat,
            let seatID = turn.speakerID, analystIDs.contains(seatID)
        else { return }
        said.contributions[seatID, default: 0] += 1

        let questions = ResearchDirector.subQuestions(in: turn.content)
        recordNaming(questions, seatID: seatID, turn: turn, said: &said)

        let signals = ConflictReader.signals(
            in: turn.content,
            from: seatID,
            others: names,
            addressing: nil)

        recordGap(turn, seatID: seatID, signals: signals, into: &said)
        recordMarks(
            questions, seatID: seatID, signals: signals, sequence: turn.sequence, into: &said)
    }

    /// Record the subject a direction pointed the room at.
    @MainActor
    private static func recordDirection(_ turn: Turn, directed: inout Set<ResearchSubQuestion>) {
        if let marker = turn.unaddressedSubject,
            let question = ResearchSubQuestion(rawValue: marker)
        {
            directed.insert(question)
        } else if let legacy = ResearchDirector.legacyUnaddressedSubject(in: turn.content) {
            directed.insert(legacy)
        }
    }

    /// Record the subjects a contribution named, but only where it also said what it relies on.
    ///
    /// A keyword in an unsourced paragraph is a mention, not an answer, and treating a
    /// mention as coverage is what let a couple of paragraphs read as the whole question
    /// addressed. The relationship and conflict reads below still use every subject the
    /// text names, because pairing a challenge with what it answered is about what was
    /// said rather than about what was evidenced.
    @MainActor
    private static func recordNaming(
        _ questions: [ResearchSubQuestion], seatID: String, turn: Turn, said: inout Said
    ) {
        guard ResearchDirector.hasBasis(turn.content) else { return }
        for question in questions {
            said.named[question, default: []].insert(seatID)
            if said.directed.contains(question) { said.directedCovered.insert(question) }
        }
    }

    /// Record a claim offered with nothing behind it.
    ///
    /// Both reads must agree. The reader's signal is the precise one — it needs a
    /// certainty phrase and no evidence — and `hasBasis` is the broader marker list, so
    /// requiring it to be false as well is what keeps a short methodological remark from
    /// being chased as though it were a claim. Flagging on either alone made almost
    /// every contribution a gap, and a director that finds a gap everywhere directs
    /// nowhere: it asks the same question until the budget runs out.
    @MainActor
    private static func recordGap(
        _ turn: Turn, seatID: String, signals: [TurnSignal], into said: inout Said
    ) {
        guard signals.contains(where: { $0.kind == .unsupportedClaim }),
            !ResearchDirector.hasBasis(turn.content)
        else { return }
        // Named by its own opening, so the direction can quote what it is about
        // rather than describing it.
        let claim =
            ConflictReader.summary(of: turn.content)
            ?? turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        said.gaps.append((seatID: seatID, claim: claim, sequence: turn.sequence))
    }

    /// Record disagreement, agreement, and who last claimed each subject.
    @MainActor
    private static func recordMarks(
        _ questions: [ResearchSubQuestion], seatID: String, signals: [TurnSignal], sequence: Int,
        into said: inout Said
    ) {
        let isDisagreement = signals.contains { $0.kind == .contradiction || $0.kind == .challenge }
        for question in questions {
            if isDisagreement, let other = said.lastClaimant[question], other != seatID {
                var parties = said.marks[question]?.parties ?? []
                if !parties.contains(other) { parties.append(other) }
                if !parties.contains(seatID) { parties.append(seatID) }
                said.marks[question] = (parties, sequence)
                said.disputedLater.insert(question)
            }
            if signals.contains(where: { $0.kind == .agreement }) {
                said.agreed.insert(question)
            }
            said.lastClaimant[question] = seatID
        }
    }

    // MARK: - Pass two: what the room did about it

    /// Which subjects the room took up, rather than which one seat mentioned.
    ///
    /// Coverage is the room's engagement, not one seat's mention. A subject that
    /// one contribution named with a basis is a mention, however well sourced: text matching
    /// cannot tell "the room worked through the cost question" from "someone wrote a sentence
    /// containing the word cost", and a single sentence naming all ten subjects used to close
    /// a session as fully answered. A subject therefore counts as covered when more than one
    /// seat has named it with a basis — the room took it up — or when it is the subject the
    /// moderator asked about and a seat answered that assignment. Coverage is not made
    /// unreachable by this: the director keeps pointing at the gap until the room responds.
    @MainActor
    private static func coverage(
        of named: [ResearchSubQuestion: Set<String>], directedCovered: Set<ResearchSubQuestion>
    ) -> [ResearchSubQuestion: Set<String>] {
        var covered: [ResearchSubQuestion: Set<String>] = [:]
        for (question, seatIDs) in named
        where seatIDs.count >= 2 || directedCovered.contains(question) {
            covered[question] = seatIDs
        }
        return covered
    }

    /// The unsupported claims nobody has taken up, which are what the director asks about.
    @MainActor
    private static func unsupportedGaps(
        _ gaps: [(seatID: String, claim: String, sequence: Int)], turns: [Turn],
        analystIDs: Set<String>
    ) -> [(seatID: String, claim: String)] {
        gaps
            .filter {
                !takenUp(
                    .methodology, after: $0.sequence, by: $0.seatID, turns: turns,
                    analystIDs: analystIDs)
            }
            .map { (seatID: $0.seatID, claim: $0.claim) }
    }

    /// The disagreements nobody has since worked on.
    @MainActor
    private static func unresolvedConflicts(
        _ marks: [ResearchSubQuestion: (parties: [String], sequence: Int)], turns: [Turn],
        analystIDs: Set<String>, names: [String]
    ) -> [ResearchSubQuestion: [String]] {
        var conflicts: [ResearchSubQuestion: [String]] = [:]
        for (question, mark) in marks.sorted(by: { $0.value.sequence < $1.value.sequence }) {
            guard
                !advanced(
                    question, after: mark.sequence, turns: turns, analystIDs: analystIDs,
                    names: names)
            else { continue }
            conflicts[question] = mark.parties
        }
        return conflicts
    }

    /// Whether someone else has since worked on this sub-question at all.
    ///
    /// The standard is deliberately loose — a contribution that merely touches methodology
    /// counts — because the alternative is a director that keeps demanding the same check until
    /// the budget runs out, which is the failure mode this pass exists to prevent.
    @MainActor
    private static func takenUp(
        _ question: ResearchSubQuestion, after sequence: Int, by seatID: String?, turns: [Turn],
        analystIDs: Set<String>
    ) -> Bool {
        turns.contains { turn in
            turn.kind == .chat
                && turn.sequence > sequence
                && turn.speakerID.map { analystIDs.contains($0) && $0 != seatID } == true
                && ResearchDirector.subQuestions(in: turn.content).contains(question)
        }
    }

    /// Whether someone has since brought material, conceded, or contested the point again.
    ///
    /// Any of the three means the disagreement is being worked on rather than ignored, so
    /// it does not need the moderator to assign it a second time.
    @MainActor
    private static func advanced(
        _ question: ResearchSubQuestion, after sequence: Int, turns: [Turn],
        analystIDs: Set<String>, names: [String]
    ) -> Bool {
        turns.contains { turn in
            guard turn.kind == .chat, turn.sequence > sequence,
                let speaker = turn.speakerID, analystIDs.contains(speaker),
                ResearchDirector.subQuestions(in: turn.content).contains(question)
            else { return false }
            return ConflictReader.signals(
                in: turn.content, from: speaker, others: names, addressing: nil
            ).contains {
                $0.kind == .newEvidence || $0.kind == .concession || $0.kind == .contradiction
            }
        }
    }
}
