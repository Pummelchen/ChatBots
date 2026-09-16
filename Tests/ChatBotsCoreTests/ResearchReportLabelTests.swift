// ChatBotsCoreTests — a mostly-unlabelled report is not called labelled or traceable
//
// `unlabelledStatements` existed and its doc said "the count is reported so the interface can
// say the labelling is incomplete", but nothing read it. `isLabelled` was
// `labelledStatements > 0`, and `isTraceable` ignored unlabelled lines entirely, so one
// attributed claim plus fifty bare assertions passed both. These tests hold the count against
// the two verdicts and against the markdown the interface shows.

import ChatBotsCore
import Testing

@Suite("Unlabelled claims are counted against the report")
struct ResearchReportLabelTests {

    private func report(_ body: String) -> ResearchReport {
        ResearchReporting.parse(
            body,
            question: "A question",
            participants: ["Economist", "Statistician"],
            stopReason: "the budget was reached",
            budgetSummary: "quick",
            rounds: 3,
            searches: 0)
    }

    @Test("One labelled claim beside fifty bare assertions is not labelled")
    func mostlyUnlabelledIsNotLabelled() {
        let bare = (1...50).map { "- assertion \($0)" }.joined(separator: "\n")
        let parsed = report("## Key Findings\n\n- FACT: registrations rose — Economist\n\(bare)")

        #expect(parsed.labelledStatements == 1)
        #expect(parsed.unlabelledStatements == 50, "every bare claim in Key Findings is counted")
        #expect(!parsed.isLabelled, "one label among fifty claims is not a labelled report")
        #expect(!parsed.isTraceable, "fifty claims with no author and no basis cannot be traced")
    }

    @Test("The markdown says how many claims carry no label")
    func markdownSurfacesTheCount() {
        let bare = (1...50).map { "- assertion \($0)" }.joined(separator: "\n")
        let parsed = report("## Key Findings\n\n- FACT: registrations rose — Economist\n\(bare)")
        let markdown = parsed.markdown()

        #expect(markdown.contains("**Traceability.**"))
        #expect(markdown.contains("50 claims carry no label"))
    }

    @Test("Prose in a section that is not a claim is not an unlabelled claim")
    func proseIsNotAClaim() {
        // The executive summary and the recommendations are prose and tasks. Counting their
        // lines made the number meaningless, because they are not claims that could be labelled.
        let parsed = report(
            """
            # Executive Summary

            The market is growing but capital intensive.

            ## Key Findings

            - FACT: registrations rose 18 percent — Economist

            ## Recommendations / Options

            - Enter only if the capital cost falls.
            """)

        #expect(parsed.labelledStatements == 1)
        #expect(parsed.unlabelledStatements == 0)
        #expect(parsed.isLabelled)
        #expect(parsed.isTraceable)
    }

    @Test("A claim section with no labels at all is still not labelled")
    func bareFindingsAreNotLabelled() {
        let parsed = report("## Key Findings\n\n- The market is growing.\n- Margins are thin.")
        #expect(parsed.unlabelledStatements == 2)
        #expect(!parsed.isLabelled)
        #expect(!parsed.isTraceable)
    }

    @Test("A report with no claims at all is not called labelled")
    func anEmptyClaimSetIsNotLabelled() {
        let parsed = report("# Executive Summary\n\nEntry looks unattractive.")
        #expect(parsed.labelledStatements == 0)
        #expect(parsed.unlabelledStatements == 0)
        #expect(!parsed.isLabelled)
        #expect(!parsed.isTraceable)
        // And the markdown says something rather than printing an empty problem list.
        #expect(parsed.markdown().contains("**Traceability.** the report has no labelled claims"))
    }
}
