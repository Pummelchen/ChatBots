// ChatBotsCoreTests — a CRLF `.secrets.env` yields a usable key, and a blank one reads as
// absent
//
// The DeepSeek path trimmed the file value with `.whitespaces`, which does not include `\r`,
// while `TavilyClient` used `.whitespacesAndNewlines`. A file written on Windows — or saved
// CRLF by an editor — therefore produced `"sk-…\r"` on one path. That value is non-empty, so
// `isMissingKey` stayed false and no warning was shown, and the Authorization header carried a
// control character, so the 401 that came back was reported as a wrong key.
//
// The fix is one normaliser both paths use, so the tests assert the parse and the shared
// function rather than a per-caller copy of the trim. The values here are obvious placeholders:
// a test must never contain a real key.

import ChatBotsCore
import Foundation
import Testing

@Suite("A key read from a CRLF file is usable")
struct ClientsKeyTests {

    private let deepSeekValue = "sk-placeholder-not-a-real-key"
    private let tavilyValue = "tvly-placeholder-not-a-real-key"

    /// A directory holding `.secrets.env` written with exactly `contents` (UTF-8).
    private func secretsDirectory(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "chatbots-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: directory.appending(path: BuiltInKeys.secretsFileName))
        return directory
    }

    /// The finding, made measurable: pre-fix every value came back with a trailing `\r`.
    @Test("A CRLF file yields values with no carriage return")
    func crlfValuesAreClean() throws {
        let directory = try secretsDirectory(
            "DEEPSEEK_API_KEY=\(deepSeekValue)\r\nTAVILY_API_KEY=\(tavilyValue)\r\n")
        defer { try? FileManager.default.removeItem(at: directory) }

        let secrets = BuiltInKeys.secretsFile(in: directory)

        #expect(secrets[BuiltInKeys.deepSeekEnvironmentKey] == deepSeekValue)
        #expect(secrets[TavilyClient.environmentKey] == tavilyValue)
        for (name, value) in secrets {
            #expect(
                !value.contains("\r") && !value.contains("\n"),
                "\(name) kept a line ending inside the key")
        }
    }

    /// The other half: the two key paths normalise through the same function, so the same file
    /// gives the same answer whichever path reads it. Pre-fix the Tavily result was clean and
    /// the DeepSeek one was not.
    @Test("Both key paths agree about the same CRLF file")
    func bothPathsAgree() throws {
        let directory = try secretsDirectory(
            "DEEPSEEK_API_KEY=\(deepSeekValue)\r\nTAVILY_API_KEY=\(tavilyValue)\r\n")
        defer { try? FileManager.default.removeItem(at: directory) }

        let secrets = BuiltInKeys.secretsFile(in: directory)
        let viaTavily = TavilyClient.resolveKey(environment: nil, secretsFile: secrets)
        let viaDeepSeek = BuiltInKeys.normalisedKey(secrets[BuiltInKeys.deepSeekEnvironmentKey])

        #expect(viaTavily == tavilyValue)
        #expect(viaDeepSeek == deepSeekValue)
        // Neither may carry a line ending, and neither may be treated as absent: the point of
        // the fix is that a correctly-configured CRLF file produces a key that authenticates.
        #expect(viaTavily?.hasSuffix("\r") == false)
        #expect(viaDeepSeek?.hasSuffix("\r") == false)
    }

    /// What made the defect invisible: `"sk-…\r"` is non-empty, so the endpoint reported a key
    /// and issued the request. Blank-after-trimming must read as *absent*, which is the answer
    /// that turns on the missing-key warning instead of a doomed request.
    @Test("A value that is only a line ending counts as no key")
    func lineEndingsOnlyAreAbsent() {
        #expect(BuiltInKeys.normalisedKey("\r") == nil)
        #expect(BuiltInKeys.normalisedKey("\r\n") == nil)
        #expect(BuiltInKeys.normalisedKey("\n") == nil)
        #expect(BuiltInKeys.normalisedKey("   \r\n") == nil)
        #expect(BuiltInKeys.normalisedKey(nil) == nil)
        // And a surrounding line ending is stripped rather than kept.
        #expect(BuiltInKeys.normalisedKey("\(deepSeekValue)\r\n") == deepSeekValue)
        #expect(BuiltInKeys.normalisedKey("\n\(deepSeekValue)") == deepSeekValue)
    }

    @Test("Quoted values survive CRLF and are unquoted")
    func quotedCrlfValues() throws {
        let directory = try secretsDirectory(
            "DEEPSEEK_API_KEY = \"\(deepSeekValue)\"\r\nTVLY=\"ignored\"\r\n")
        defer { try? FileManager.default.removeItem(at: directory) }

        let secrets = BuiltInKeys.secretsFile(in: directory)
        #expect(secrets[BuiltInKeys.deepSeekEnvironmentKey] == deepSeekValue)
        #expect(secrets["TVLY"] == "ignored")
    }

    /// The measurement behind the fix, kept because it corrects the first reading of the
    /// finding: `split(separator: "\n")` does not split a CRLF file at all, because Swift's
    /// `Character` is a grapheme cluster and `CR LF` is one. A two-key CRLF file used to arrive
    /// as a single entry whose value was the rest of the file — only the first key "parsed",
    /// and its value contained the second. That is worse than a trailing carriage return and it
    /// is why the fix normalises line endings rather than only widening the trim.
    @Test("A CRLF file is split into its lines, comments included")
    func crlfLinesAreSplit() throws {
        let directory = try secretsDirectory(
            "# a note\r\nDEEPSEEK_API_KEY=\(deepSeekValue)\r\n# another\r\nTAVILY_API_KEY=\(tavilyValue)\r\n")
        defer { try? FileManager.default.removeItem(at: directory) }

        let secrets = BuiltInKeys.secretsFile(in: directory)

        #expect(secrets.count == 2, "comments are skipped and the keys are separate entries")
        #expect(secrets[BuiltInKeys.deepSeekEnvironmentKey] == deepSeekValue)
        #expect(secrets[TavilyClient.environmentKey] == tavilyValue)
    }

    /// A lone `\r` ending and a final line with no newline at all both parse.
    @Test("Lone carriage returns and a missing final newline still parse")
    func otherLineEndings() throws {
        let directory = try secretsDirectory(
            "DEEPSEEK_API_KEY=\(deepSeekValue)\rTAVILY_API_KEY=\(tavilyValue)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let secrets = BuiltInKeys.secretsFile(in: directory)
        #expect(secrets[BuiltInKeys.deepSeekEnvironmentKey] == deepSeekValue)
        #expect(secrets[TavilyClient.environmentKey] == tavilyValue)
    }

    @Test("A CRLF environment variable is normalised too")
    func environmentIsNormalised() {
        #expect(
            TavilyClient.resolveKey(environment: "\(tavilyValue)\r\n", secretsFile: [:])
                == tavilyValue)
        #expect(TavilyClient.resolveKey(environment: "\r\n", secretsFile: [:]) == nil)
        // The environment still wins over the file, and blank environment falls through to it.
        #expect(
            TavilyClient.resolveKey(
                environment: "tvly-from-environment",
                secretsFile: [TavilyClient.environmentKey: tavilyValue]) == "tvly-from-environment")
        #expect(
            TavilyClient.resolveKey(
                environment: " ", secretsFile: [TavilyClient.environmentKey: tavilyValue])
                == tavilyValue)
    }
}
