// ChatBotsCore — the research session, the report that ends it and the mode switch
//
// Split out of `ConversationEngine.swift`, which held the orchestrator, its turn loop, its
// transcript plumbing, its context bookkeeping and its research mode in one 1613-line file.
// What a research session exposes to a front end, and what it leaves behind when it stops,
// live here; nothing changed but which file the code lives in.

import Foundation

extension ConversationEngine {

    /// Write the report that ends a research session.
    ///
    /// The **moderator** writes it, because that is what the role is for: it has read every
    /// contribution and its job is to organise, not to add. If no moderator seat is present —
    /// a two-seat run configured with two analysts — the first seat is asked instead, since a
    /// report is the deliverable and producing none would waste the whole session. The
    /// substitution is noted rather than silent.
    ///
    /// **One report per session.** A conversation restored by `load()` brings back the report
    /// its session produced, and `start()` skips `beginResearchSessionIfNeeded` because
    /// `research` is already there. Without this guard the loop's finished check then fired
    /// against the restored session, called the moderator for a fresh minutes-long generation,
    /// and appended a second report over a transcript that had gained no turns — the same
    /// failure `reset()` documents fixing, reintroduced by the load path. `reset()` clears the
    /// report along with the session, so a new run still gets a new report; a session that was
    /// saved mid-run and has none yet still gets one when it finishes.
    func writeReport(reason: ResearchStop) async {
        guard let session = conversation.research else { return }
        guard conversation.report == nil,
            !conversation.turns.contains(where: { $0.kind == .report })
        else { return }

        let moderator =
            seats.first { $0.spec.personaID == AnalystLibrary.moderatorID }
            ?? seats.first
        guard let moderator else { return }
        if moderator.spec.personaID != AnalystLibrary.moderatorID {
            note("No Research Moderator among the seats, so \(moderator.spec.displayName) is writing the report.")
        }

        let transcript = conversation.turns
            .filter { $0.kind == .chat || $0.kind == .tool || $0.kind == .topic }
            .map { turn -> String in
                let who = turn.kind == .tool ? "TOOL" : turn.speakerName
                return "[\(who)] \(turn.content)"
            }
            .joined(separator: "\n\n")

        let prompt = ResearchReporting.synthesisPrompt(
            question: conversation.topic,
            participants: seats.map { $0.spec.displayName },
            stopReason: reason.explanation,
            transcript: transcript)

        note("Writing the report…")
        let text: String
        do {
            text = try await moderator.engine.generate(
                messages: [
                    .init(
                        role: .system,
                        content:
                            "You are the Research Moderator. You organise findings precisely and add none of your own."
                    ),
                    .init(role: .user, content: prompt),
                ],
                tools: [], onToolCall: { _, _ in }, onEvent: { _ in })
        } catch {
            note("The report could not be written: \(error.localizedDescription)")
            return
        }

        let report = ResearchReporting.parse(
            text,
            facts: .init(
                question: conversation.topic,
                participants: seats.map { $0.spec.displayName },
                stopReason: reason.explanation,
                budgetSummary: "\(session.budget.depth.label) (\(session.budget.depth.summary))",
                rounds: session.rounds,
                searches: session.searches))

        conversation.report = report
        conversation.turns.append(
            Turn(
                sequence: nextSequence(),
                speakerName: "Research Moderator",
                kind: .report,
                content: report.markdown()
            )
        )
        publishTranscript()

        if report.unlabelledStatements > 0 {
            note(
                "The report has \(report.unlabelledStatements) unlabelled claim(s); treat those as unverified."
            )
        } else if !report.isLabelled {
            note("The report came back without claim labels, so treat every statement as unverified.")
        }
        if !report.missingSections.isEmpty {
            note("The report did not cover: \(report.missingSections.joined(separator: ", ")).")
        }
        note(
            "Report ready — \(report.labelledStatements) labelled claims, \(report.unlabelledStatements) unlabelled."
        )
    }
    /// The research session, for a front end to show progress.
    public var researchSession: ResearchSession? { conversation.research }

    /// The report a finished session produced.
    public func researchReport() -> ResearchReport? { conversation.report }

    /// A status line for the session, or nil outside research.
    public func researchStatus() -> APISnapshot.ResearchStatus? {
        guard let session = conversation.research else { return nil }
        let reason = session.evaluate()
        return APISnapshot.ResearchStatus(
            depth: session.budget.depth.label,
            budgetSummary: session.budget.depth.summary,
            rounds: session.rounds,
            maxRounds: session.budget.maxRounds,
            searches: session.searches,
            maxSearches: session.budget.maxSearches,
            remainingMinutes: Int(session.remaining() / 60),
            statusLine: session.statusLine(),
            isFinished: reason.isFinished,
            stopReason: reason == .running ? nil : reason.explanation)
    }

    /// Switch the whole room between entertainment and research.
    ///
    /// Reseats every persona, because the two libraries are not interchangeable: a seat
    /// holding "The Villain" has no meaning in a research session, and resolving it to a
    /// default silently would leave the picker showing something the seat is not using.
    /// Refused once the conversation has started, since the log was written against the
    /// personas it began with.
    @discardableResult
    public func setMode(_ mode: DiscussionMode) -> Bool {
        guard startedTurns == 0, generationTask == nil else { return false }
        for index in seats.indices {
            seats[index].spec.mode = mode
            if !mode.owns(personaID: seats[index].spec.personaID) {
                seats[index].spec.personaID = mode.defaultPersonaID(forSeat: index)
            }
            let spec = seats[index].spec
            if let engine = seatEngine(for: spec.id) {
                Task { await engine.setPersona(spec.personaID) }
            }
        }
        // A research run needs a session; an entertainment one must not have a budget
        // counting against it.
        if mode == .research {
            conversation.research = ResearchSession(
                budget: configuration.researchBudget ?? .preset(.standard))
        } else {
            conversation.research = nil
        }
        note("Mode set to \(mode.label) — \(mode.summary)")
        publishTranscript()
        return true
    }

    /// Set the research budget before the investigation starts.
    ///
    /// Refused once it is running: the budget is what the session is being measured against,
    /// and changing it midway would make the progress meaningless.
    @discardableResult
    public func setResearchBudget(_ depth: ResearchBudget.Depth) -> Bool {
        guard startedTurns == 0, generationTask == nil else { return false }
        guard seats.contains(where: { $0.spec.mode == .research }) else { return false }
        let budget = ResearchBudget.preset(depth)
        configuration.researchBudget = budget
        conversation.research = ResearchSession(budget: budget)
        note("Research budget set to \(depth.label) — \(depth.summary).")
        return true
    }
}
