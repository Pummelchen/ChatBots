// ChatBotsCoreTests — where the Tavily key comes from, and that nothing ships one
//
// This exists because a live Tavily dev key was committed to `TavilyClient.swift` in a public
// repository and stayed there for the first days of the project. A key in the source is a key
// in every clone, so the fix was to delete it and resolve from the environment or the
// gitignored `.secrets.env` — the mechanism `BuiltInKeys` already used for DeepSeek.
//
// The resolution is tested through the pure `resolveKey(environment:secretsFile:)` rather than
// through the real environment: a test that read the developer's own `.secrets.env` would pass
// on the machine that wrote it and fail on a fresh clone, which is the opposite of useful for
// a check that is about a fresh clone having no key.

import ChatBotsCore
import Foundation
import Testing

@Suite("Tavily key resolution")
struct TavilyKeyTests {

    @Test("The environment variable wins over the file")
    func environmentWins() {
        let key = TavilyClient.resolveKey(
            environment: "tvly-from-environment",
            secretsFile: [TavilyClient.environmentKey: "tvly-from-file"])
        #expect(key == "tvly-from-environment")
    }

    @Test("The file is used when the environment has nothing")
    func fileIsTheFallback() {
        let key = TavilyClient.resolveKey(
            environment: nil, secretsFile: [TavilyClient.environmentKey: "tvly-from-file"])
        #expect(key == "tvly-from-file")
    }

    @Test("A fresh clone with neither source has no key")
    func nothingConfigured() {
        #expect(TavilyClient.resolveKey(environment: nil, secretsFile: [:]) == nil)
    }

    @Test("Blank values count as no key, not as an empty one")
    func blankValuesAreAbsent() {
        // An exported-but-empty variable is the common way to end up sending `Bearer ` to the
        // API, which answers 401 and reads as "the key is wrong" rather than "there is none".
        #expect(TavilyClient.resolveKey(environment: "", secretsFile: [:]) == nil)
        #expect(TavilyClient.resolveKey(environment: "   ", secretsFile: [:]) == nil)
        #expect(
            TavilyClient.resolveKey(
                environment: nil, secretsFile: [TavilyClient.environmentKey: "  "]) == nil)
    }

    @Test("Surrounding whitespace is trimmed, because a pasted key carries it")
    func whitespaceIsTrimmed() {
        #expect(
            TavilyClient.resolveKey(environment: "  tvly-x\n", secretsFile: [:]) == "tvly-x")
        #expect(
            TavilyClient.resolveKey(
                environment: nil, secretsFile: [TavilyClient.environmentKey: " tvly-y "])
                == "tvly-y")
    }

    @Test("The variable name is the one the documentation tells people to use")
    func variableNameMatchesTheDocs() {
        #expect(TavilyClient.environmentKey == "TAVILY_API_KEY")
        // The same file the DeepSeek key is read from, so there is one documented place.
        #expect(BuiltInKeys.secretsFileName == ".secrets.env")
    }

    @Test("No key is compiled into the client")
    func noShippedKey() throws {
        // The guard itself: `isConfigured` must be a statement about this machine, not a
        // constant — and the regression this catches is a default being reintroduced.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ChatBotsCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
            .appending(path: "Sources/ChatBotsCore/Research/TavilyClient.swift")
        let text = try String(contentsOf: sources, encoding: .utf8)

        // A real Tavily key is `tvly-` followed by a long token. The documented placeholder is
        // `tvly-dev-your-key-here`, which is shorter than this and does not match.
        let keyPattern = try NSRegularExpression(pattern: #"tvly-[A-Za-z0-9_-]{20,}"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = keyPattern.matches(in: text, range: range)
        #expect(matches.isEmpty, "a Tavily key is compiled into TavilyClient.swift again")
        #expect(!text.contains("defaultAPIKey"), "the built-in default key is back")
    }

    @Test("The room is told search is available only when it is")
    func thePromptTellsTheTruth() {
        // Both sentences, as a pure function of availability — otherwise this test would say
        // whatever the machine it runs on happens to be configured for.
        let without = PromptBuilder.searchRule(available: false)
        #expect(without.contains("not available"))
        #expect(without.contains("Do not claim to have searched"))
        #expect(!without.contains("You have web search tools"))

        let with = PromptBuilder.searchRule(available: true)
        #expect(with.contains("You have web search tools"))
        #expect(!with.contains("not available"))
        // Both keep the rule that matters most for a report's credibility.
        #expect(without.contains("invent a source"))
        #expect(with.contains("invent a source"))
    }
}
