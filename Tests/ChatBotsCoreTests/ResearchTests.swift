// ChatBotsCoreTests — research budgets, end conditions and the report

import ChatBotsCore
import Foundation
import Testing

@Suite("Research budget")
struct ResearchBudgetTests {

    @Test("The presets match the brief")
    func presets() {
        #expect(ResearchBudget.preset(.quick).depth.summary == "5–10 minutes")
        #expect(ResearchBudget.preset(.standard).depth.summary == "20–30 minutes")
        #expect(ResearchBudget.preset(.deep).depth.summary == "45–60 minutes")
        // And they get monotonically more generous, which is what a preset is for.
        let quick = ResearchBudget.preset(.quick)
        let standard = ResearchBudget.preset(.standard)
        let deep = ResearchBudget.preset(.deep)
        #expect(quick.maxRounds < standard.maxRounds)
        #expect(standard.maxRounds < deep.maxRounds)
        #expect(quick.maxSearches < deep.maxSearches)
    }

    @Test("A custom duration scales the other limits to match")
    func customBudget() {
        let budget = ResearchBudget.custom(minutes: 30)
        #expect(budget.maxDuration == 1_800)
        // The limits should not disagree wildly: a 30-minute session with a 2-round budget or
        // a 500-search budget would be incoherent.
        #expect(budget.maxRounds >= 15 && budget.maxRounds <= 25)
        #expect(budget.maxSearches >= 25 && budget.maxSearches <= 35)
        #expect(budget.depth == .standard)

        // A very long session is treated as deep; a very short one is not.
        #expect(ResearchBudget.custom(minutes: 60).depth == .deep)
        #expect(ResearchBudget.custom(minutes: 6).depth == .quick)
    }
}

@Suite("When a research session stops")
struct ResearchSessionTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("A fresh session is running")
    func freshIsRunning() {
        let session = ResearchSession(budget: .preset(.standard), startedAt: start)
        #expect(session.evaluate(at: start) == .running)
        #expect(!session.isFinished(at: start))
    }

    @Test("Reaching the round budget stops it")
    func roundsStop() {
        var session = ResearchSession(budget: .preset(.quick), startedAt: start)
        for _ in 0..<session.budget.maxRounds {
            session.record(addedSomething: true, at: start)
        }
        #expect(session.evaluate(at: start) == .roundsReached)
    }

    @Test("Reaching the time budget stops it, without any rounds")
    func timeStops() {
        let session = ResearchSession(budget: .preset(.quick), startedAt: start)
        // Wall-clock, so a session that sat idle — a slow model, a paused engine — still ends.
        let later = start.addingTimeInterval(session.budget.maxDuration + 1)
        #expect(session.evaluate(at: later) == .durationReached)
        #expect(session.isFinished(at: later))
    }

    @Test("Reaching the search budget stops it")
    func searchesStop() {
        var session = ResearchSession(budget: .preset(.quick), startedAt: start)
        session.record(searchCount: session.budget.maxSearches, addedSomething: true, at: start)
        #expect(session.evaluate(at: start) == .searchesReached)
    }

    @Test("A run of contributions that add nothing is read as convergence")
    func convergenceStops() {
        var session = ResearchSession(budget: .preset(.quick), startedAt: start)
        let quiet = session.convergenceThreshold
        for _ in 0..<quiet {
            session.record(addedSomething: false, at: start)
        }
        // Convergence is checked before the counters, because "the work is done" is a better
        // thing to tell the moderator than "the clock ran out".
        #expect(session.evaluate(at: start) == .converged)
    }

    @Test("One contribution that adds something resets the convergence count")
    func convergenceResets() {
        var session = ResearchSession(budget: .preset(.standard), startedAt: start)
        for _ in 0..<(session.convergenceThreshold - 1) {
            session.record(addedSomething: false, at: start)
        }
        session.record(addedSomething: true, at: start)
        #expect(session.quietRounds == 0)
        #expect(session.evaluate(at: start) == .running, "progress should keep it going")
    }

    @Test("A deeper session tolerates more quiet turns before giving up")
    func convergenceScalesWithDepth() {
        #expect(ResearchBudget.preset(.deep).depth == .deep)
        let quick = ResearchSession(budget: .preset(.quick), startedAt: start)
        let deep = ResearchSession(budget: .preset(.deep), startedAt: start)
        #expect(quick.convergenceThreshold < deep.convergenceThreshold)
    }

    @Test("The moderator can stop it, and a finished session does not restart")
    func moderatorStops() {
        var session = ResearchSession(budget: .preset(.standard), startedAt: start)
        session.stopByModerator()
        #expect(session.evaluate(at: start) == .stoppedByModerator)
        // Recording after the end changes nothing, so a late turn cannot revive it.
        session.record(addedSomething: true, at: start)
        #expect(session.rounds == 0)
        #expect(session.evaluate(at: start) == .stoppedByModerator)
    }

    @Test("A stopped session still counts as finished, so a report is written")
    func stoppedProducesAReport() {
        // A session stopped by hand still has findings worth writing up; refusing a report
        // would throw the work away.
        #expect(ResearchStop.stoppedByModerator.isFinished)
        #expect(!ResearchStop.running.isFinished)
        for stop in [ResearchStop.durationReached, .roundsReached, .searchesReached, .converged] {
            #expect(stop.isFinished)
            #expect(!stop.explanation.isEmpty)
        }
    }

    @Test("The status line reports progress while running and the reason once finished")
    func statusLine() {
        var session = ResearchSession(budget: .preset(.standard), startedAt: start)
        let running = session.statusLine(at: start)
        #expect(running.contains("Round 0/"))
        #expect(running.contains("searches"))

        session.stopByModerator()
        #expect(session.statusLine(at: start).contains("Finished"))
    }

    @Test("A session survives a save and reload, keeping its clock and counters")
    func sessionIsCodable() throws {
        var session = ResearchSession(budget: .preset(.deep), startedAt: start)
        session.record(searchCount: 3, addedSomething: true, at: start)
        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(ResearchSession.self, from: data)
        #expect(restored == session)
        #expect(restored.rounds == 1)
        #expect(restored.searches == 3)
    }
}

@Suite("The research report")
struct ResearchReportTests {

    private let sample = """
        # Executive Summary

        The German EV market is growing but capital intensive.

        ## Key Findings

        - **FACT:** German EV registrations rose in 2024.
        - **SOURCED:** The 2024 market grew 12% according to the regulator.
        - **INFERENCE:** Growth does not establish that entry would be profitable.
        - OPINION: I think the timing is poor.

        ## Areas of Disagreement

        - The Economist expects demand to continue; the Investor expects margin pressure.

        ## Unknowns / Evidence Gaps

        - Nobody established the capital cost of a local plant.
        """

    private func parsed(_ text: String = "") -> ResearchReport {
        ResearchReporting.parse(
            text.isEmpty ? sample : text,
            question: "Should Company X enter the German EV market?",
            participants: ["Research Moderator", "Economist", "Investor"],
            stopReason: "The time budget was reached.",
            budgetSummary: "Standard (20–30 minutes)",
            rounds: 20,
            searches: 14)
    }

    @Test("Labelled claims are read with their labels")
    func labelsAreParsed() {
        let report = parsed()
        let findings = report.sections.first { $0.title == "Key Findings" }
        #expect(findings != nil)
        // Four, including the unemphasised "OPINION:" line: a parser that only caught the
        // bolded ones would silently drop claims from the report.
        #expect(findings?.statements.count == 4, "every labelled line is a claim")
        #expect(findings?.lines.isEmpty == true)

        let bases = findings?.statements.map(\.basis) ?? []
        #expect(bases.contains(.fact))
        #expect(bases.contains(.sourced))
        #expect(bases.contains(.inference))
        #expect(report.isLabelled)
        #expect(report.labelledStatements == 4)
    }

    @Test("Section headings are matched however the model words them")
    func headingsAreTolerant() {
        // "Unknowns & Evidence Gaps" and "Unknowns / Evidence Gaps" are the same section, and
        // refusing a whole report over a heading would throw away the session's work.
        let report = parsed()
        #expect(report.sections.contains { $0.title == "Unknowns / Evidence Gaps" })

        let variant = parsed("# Unknowns & Evidence Gaps\n\n- **FACT:** x")
        #expect(variant.sections.contains { $0.title == "Unknowns / Evidence Gaps" })

        let slashVariant = parsed("# unknowns/evidence gaps\n\n- **FACT:** x")
        #expect(slashVariant.sections.contains { $0.title == "Unknowns / Evidence Gaps" })
    }

    @Test("Markdown emphasis around a label is tolerated")
    func emphasisIsTolerated() {
        // The prompt's own example uses **FACT:**, so the parser has to accept what it asked for.
        let report = parsed("## Key Findings\n\n- **FACT:** the sky is blue")
        #expect(report.sections.first?.statements.first?.basis == .fact)
        #expect(report.sections.first?.statements.first?.text == "the sky is blue")
    }

    @Test("A report with no labels is reported as unlabelled rather than rejected")
    func unlabelledIsFlagged() {
        // Findings without labels are still worth having, but the reader has to be told they
        // cannot be relied on — so the report says so instead of silently presenting them.
        let report = parsed("## Key Findings\n\n- The market is growing.\n- Margins are thin.")
        #expect(!report.isLabelled)
        #expect(report.labelledStatements == 0)
        #expect(report.sections.first?.lines.count == 2)
    }

    @Test("Missing sections are named, not quietly omitted")
    func missingSectionsAreListed() {
        let report = parsed("# Executive Summary\n\nThe market is growing.")
        #expect(!report.missingSections.isEmpty)
        #expect(report.missingSections.contains("Risks"))
        // And the markdown says so, because a report that hides its own gaps is not usable.
        #expect(report.markdown().contains("Not covered"))
    }

    @Test("Prose with no headings is still kept as a summary")
    func proseFallback() {
        let report = parsed("The investigation suggests the market is attractive but risky.")
        #expect(report.sections.count == 1)
        #expect(report.sections.first?.title == "Executive Summary")
        #expect(report.sections.first?.lines.first?.contains("attractive") == true)
    }

    @Test("The markdown carries the question, the budget and the reason it stopped")
    func markdownIsSelfDescribing() {
        let text = parsed().markdown()
        // A report read a week later has to say what was asked and how hard it was pushed.
        #expect(text.contains("Should Company X enter the German EV market?"))
        #expect(text.contains("How far this went"))
        #expect(text.contains("Ended because"))
        #expect(text.contains("Economist"))
        // And the legend, so a reader knows what FACT means without being told.
        #expect(text.contains("FACT = verifiable and verified"))
        #expect(text.contains("Only FACT and SOURCED can be relied on"))
    }

    @Test("A report survives a save and reload")
    func reportIsCodable() throws {
        let report = parsed()
        let data = try JSONEncoder().encode(report)
        let restored = try JSONDecoder().decode(ResearchReport.self, from: data)
        #expect(restored == report)
        #expect(restored.markdown() == report.markdown())
    }

    @Test("Only fact and sourced count as reliable")
    func reliability() {
        #expect(ResearchStatement.Basis.fact.isReliable)
        #expect(ResearchStatement.Basis.sourced.isReliable)
        for basis in [ResearchStatement.Basis.inference, .assumption, .opinion, .scenario] {
            #expect(!basis.isReliable, "\(basis) must not be treated as established")
            #expect(!basis.explanation.isEmpty)
        }
    }
}

@Suite("The synthesis instruction")
struct SynthesisPromptTests {

    @Test("The prompt asks for every required section, by name")
    func requiresEverySection() {
        let prompt = ResearchReporting.synthesisPrompt(
            question: "Q", participants: ["A"], stopReason: "R", transcript: "T")
        for section in ResearchReport.requiredSections {
            #expect(prompt.contains(section), "the prompt should ask for \(section)")
        }
    }

    @Test("The prompt requires labels and forbids inventing findings")
    func requiresLabels() {
        let prompt = ResearchReporting.synthesisPrompt(
            question: "Q", participants: ["A"], stopReason: "R", transcript: "T")
        for basis in ResearchStatement.Basis.allCases {
            #expect(prompt.contains(basis.rawValue), "every label should be named")
        }
        // The one thing a synthesis must not do.
        #expect(prompt.contains("Do not invent"))
        // And disagreement must not be papered over.
        #expect(prompt.contains("Areas of Disagreement must be honest"))
    }

    @Test("The prompt tells the moderator it is organising, not adding")
    func doesNotAddFindings() {
        let prompt = ResearchReporting.synthesisPrompt(
            question: "Q", participants: ["A"], stopReason: "R", transcript: "T")
        #expect(prompt.contains("not adding to it"))
    }

    @Test("The transcript is included")
    func transcriptIncluded() {
        let prompt = ResearchReporting.synthesisPrompt(
            question: "Q", participants: ["A"], stopReason: "R",
            transcript: "[Agent 1] a distinctive claim")
        #expect(prompt.contains("a distinctive finding") == false)
        #expect(prompt.contains("[Agent 1] a distinctive claim"))
    }
}
