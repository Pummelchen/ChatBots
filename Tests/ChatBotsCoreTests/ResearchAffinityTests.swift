// ChatBotsCoreTests — affinity scores on words, not fragments
//
// `affinity(_:for:)` scored with `haystack.contains($1)` — the same bare-substring shape
// fixed for coverage, in the same file — so "law" matched "flaw" and "source" matched
// "resource" when deciding which seat is asked. It chooses who is asked rather than whether a
// claim is made, so the consequence is a poorer question rather than a false one, which is why
// it was recorded as the lesser defect. The fix is the word-boundary rule coverage already uses.

import ChatBotsCore
import Testing

@Suite("Affinity matches words, not fragments")
@MainActor
struct ResearchAffinityTests {

    private func role(domain: String, method: String = "", preferredData: String = "") -> AnalystRole {
        AnalystRole(
            id: "test-role", name: "Test Role", emoji: "", group: .evidence, summary: "",
            objective: "", domain: domain, method: method, evidenceStandard: "",
            preferredData: preferredData, failureMode: "", decisionCriteria: "",
            skepticism: .moderate, searchQueries: [])
    }

    @Test("A marker inside a longer word scores nothing")
    func fragmentsDoNotScore() {
        // "flaw" contains "law"; "resource" contains "source"; "configure" contains "figure".
        // As bare substrings these scored regulation and evidence for a role that speaks for
        // neither.
        let disguised = role(
            domain: "the flaw and the resource", method: "configure the script")

        #expect(
            ResearchDirector.affinity(of: disguised, for: .regulation) == 0,
            "'law' must not match 'flaw'")
        #expect(
            ResearchDirector.affinity(of: disguised, for: .evidence) == 0,
            "'source' must not match 'resource', 'figure' must not match 'configure'")
    }

    @Test("A real word still scores")
    func realWordsScore() {
        let legal = role(domain: "law, regulation and compliance")
        #expect(ResearchDirector.affinity(of: legal, for: .regulation) > 0)

        let sources = role(
            domain: "", preferredData: "primary sources and measured figures")
        #expect(ResearchDirector.affinity(of: sources, for: .evidence) > 0)
    }

    @Test("A stem still matches the word it begins")
    func stemsStillMatch() {
        // The rule mirrors coverage's: the start must be a word boundary, the end is deliberately
        // open, because the markers are stems ("competitor" is plainly the competition subject).
        let competitive = role(domain: "competitors and market share")
        #expect(ResearchDirector.affinity(of: competitive, for: .competition) > 0)
    }
}
