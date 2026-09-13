// ChatBotsCoreTests — a typed key is normalised like the file and environment ones (audit A106)
//
// A55 introduced one `BuiltInKeys.normalisedKey` for the file and environment paths, and its
// entry named the third caller: a key the user typed into the endpoint. That path still took
// the value verbatim, so a pasted key with a trailing newline carried a control character into
// the Authorization header and, because the value was non-empty, also suppressed the
// missing-key warning — the app said a key was configured and then sent one that could not
// authenticate. `host(of:)` had the sibling problem: it trimmed `.whitespaces` while
// `responsesURL` trimmed `.whitespacesAndNewlines`, so a base URL ending in a line ending was
// requestable while its host read as nil and the built-in key was withheld from the host it
// belongs to.
//
// The values here are obvious placeholders; a test must never contain a real key.

import Foundation
import Testing

@testable import ChatBotsCore

@Suite("A typed key is normalised like every other key (audit A106)")
struct AuditCLIClientKeyTests {

    private let typed = "sk-placeholder-not-a-real-key"

    private func endpoint(
        baseURL: String = "http://localhost:1234",
        apiKey: String?,
        compatibility: APICompatibility = .extended
    ) -> OpenAIEndpoint {
        OpenAIEndpoint(
            baseURL: baseURL, model: "test-model", apiKey: apiKey, compatibility: compatibility)
    }

    /// The finding, made measurable: pre-fix a typed value came back with its line ending
    /// still attached, so the bearer token on the wire was `sk-…\n`.
    @Test("A typed key with a trailing line ending is trimmed")
    func typedKeyIsTrimmed() {
        #expect(endpoint(apiKey: "\(typed)\n").effectiveAPIKey == typed)
        #expect(endpoint(apiKey: "\(typed)\r\n").effectiveAPIKey == typed)
        #expect(endpoint(apiKey: "\(typed)\r").effectiveAPIKey == typed)
        #expect(endpoint(apiKey: "  \(typed)  ").effectiveAPIKey == typed)
        // And an ordinary key is unchanged, so the normaliser is not rewriting keys.
        #expect(endpoint(apiKey: typed).effectiveAPIKey == typed)
    }

    /// What made the defect invisible: `"sk-…\n"` is non-empty, so the endpoint reported a key
    /// and issued the request. A blank typed key has to read as *absent*, which is the answer
    /// that turns on the missing-key warning.
    @Test("A whitespace-only typed key reads as absent, not as a key")
    func whitespaceOnlyTypedKeyIsAbsent() {
        // A strict host with no built-in key: the only key that could exist is the typed one.
        let strict = endpoint(
            baseURL: "https://api.openai.com", apiKey: " \n", compatibility: .strict)
        #expect(strict.effectiveAPIKey == nil)
        #expect(strict.isMissingKey, "a blank key must not suppress the missing-key warning")

        // Non-strict endpoints do not warn, but they must still not send a blank token.
        #expect(endpoint(baseURL: "https://api.openai.com", apiKey: "\r\n").effectiveAPIKey == nil)
    }

    /// The precedence the doc states: an explicit key wins, then the environment, then the key
    /// built into the app. A blank explicit value is not a key, so it must fall through rather
    /// than shadow the fallback — pre-fix it returned `"\n"` as an explicit key.
    @Test("A blank typed key falls through instead of shadowing the built-in key")
    func blankTypedKeyFallsThrough() {
        let blankOnDeepSeek = endpoint(baseURL: "https://api.deepseek.com", apiKey: "\n")
        #expect(blankOnDeepSeek.effectiveAPIKey == BuiltInKeys.deepSeek)
    }

    /// The two halves of one endpoint have to agree about the same string. `responsesURL`
    /// already accepted a base URL with a trailing line ending; `host(of:)` did not, so the
    /// built-in key was withheld from a host it belonged to. Pre-fix `host(of:)` returned nil
    /// for the first two cases below.
    @Test("The host check trims line endings, as responsesURL already did")
    func hostTrimsLineEndings() {
        #expect(BuiltInKeys.host(of: "api.deepseek.com\n") == "api.deepseek.com")
        #expect(BuiltInKeys.host(of: "https://api.deepseek.com\r\n") == "api.deepseek.com")
        #expect(BuiltInKeys.host(of: "  https://api.deepseek.com  ") == "api.deepseek.com")
        // The request URL and the host check read the same string, and both accept it.
        let withLineEnding = endpoint(baseURL: "https://api.deepseek.com\n", apiKey: nil)
        #expect(withLineEnding.responsesURL != nil)
        #expect(BuiltInKeys.host(of: withLineEnding.baseURL) == "api.deepseek.com")
    }
}
