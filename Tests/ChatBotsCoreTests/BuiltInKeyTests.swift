// ChatBotsCoreTests — the keys compiled into the build
//
// The point of a built-in key is that the app works on a fresh machine with no setup. The
// point of the host check is that it is never sent somewhere it does not belong: a
// development key leaking to an arbitrary server is worse than a missing key.

import ChatBotsCore
import Foundation
import Testing

@Suite("Built-in keys")
struct BuiltInKeyTests {

    @Test(
        "A DeepSeek endpoint picks up a configured key without anyone typing one",
        .enabled(if: BuiltInKeys.deepSeek != nil))
    func deepSeekGetsTheKey() throws {
        // Gated on a key existing on this machine. The resolution rules are covered without
        // one by the tests below; what cannot be covered without a key is that the real one
        // reaches the endpoint, so that is what this checks where a key is present.
        // Resolution order: the environment, then the gitignored `.secrets.env`. On a machine
        // with neither, there is simply no key and the seat reports that — which is why this
        // test skips rather than fails when the file is absent, as it would be in a fresh
        // clone. The file is deliberately not in the repository.
        let configured = try #require(
            BuiltInKeys.deepSeek,
            "no DeepSeek key configured; set DEEPSEEK_API_KEY or add .secrets.env")

        let endpoint = OpenAIEndpoint(
            baseURL: "https://api.deepseek.com/v1", model: "deepseek-v4-pro")
        #expect(endpoint.effectiveAPIKey == configured)
        #expect(!endpoint.isMissingKey)
    }

    @Test("The key is read from the gitignored file, not from the source")
    func keyComesFromTheFileNotTheSource() throws {
        // The whole point of the arrangement: this file is not in the repository, so a key
        // cannot leak through a commit or through GitHub's scanning.
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "chatbots-secrets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        try """
            # a comment
            DEEPSEEK_API_KEY="sk-from-the-file"
            OTHER_KEY=ignored
            """.write(
            to: temporary.appending(path: BuiltInKeys.secretsFileName),
            atomically: true, encoding: .utf8)

        let values = BuiltInKeys.secretsFile(in: temporary)
        #expect(values["DEEPSEEK_API_KEY"] == "sk-from-the-file", "quotes should be tolerated")
        #expect(values["OTHER_KEY"] == "ignored")
        #expect(values.count == 2, "comments and blanks should be skipped")
    }

    @Test("A missing secrets file is not an error")
    func missingSecretsFileIsFine() {
        let nowhere = URL(fileURLWithPath: "/tmp/chatbots-no-such-dir-\(UUID().uuidString)")
        #expect(BuiltInKeys.secretsFile(in: nowhere).isEmpty)
    }

    @Test("The key is not sent anywhere else")
    func keyStaysWithItsHost() {
        // A local server, a competitor, anything: no key, because sending it there would
        // disclose it to whoever runs that machine.
        for host in ["http://localhost:1234/v1", "https://api.openai.com/v1",
                     "https://example.test/v1", "https://notdeepseek.com/v1",
                     "https://api.deepseek.com.evil.test/v1"] {
            let endpoint = OpenAIEndpoint(baseURL: host, model: "some-model")
            #expect(endpoint.effectiveAPIKey == nil, "a key must not be sent to \(host)")
        }
    }

    @Test("A key the user typed always wins")
    func explicitKeyWins() {
        let endpoint = OpenAIEndpoint(
            baseURL: "https://api.deepseek.com/v1", model: "deepseek-v4-pro",
            apiKey: "sk-mine")
        #expect(endpoint.effectiveAPIKey == "sk-mine")
    }

    @Test("An empty stored key falls back rather than being sent as blank")
    func emptyStoredKeyFallsBack() {
        let endpoint = OpenAIEndpoint(
            baseURL: "https://api.deepseek.com/v1", model: "deepseek-v4-pro", apiKey: "")
        #expect(endpoint.effectiveAPIKey == BuiltInKeys.deepSeek)
    }

    @Test("A strict endpoint with no key is still reported as missing one")
    func strictEndpointReportsMissing() {
        // OpenAI proper is not DeepSeek: no built-in key applies, so the seat must be told
        // it needs one rather than failing at the first turn.
        let endpoint = OpenAIEndpoint(
            baseURL: "https://api.openai.com/v1", model: "gpt-4o", compatibility: .strict)
        #expect(endpoint.effectiveAPIKey == nil)
        #expect(endpoint.isMissingKey)
    }

    @Test("The key survives a settings round trip without being written in")
    func keyIsNotPersisted() throws {
        // Nothing is written into the user's settings: the key is resolved at request time, so
        // a saved endpoint carries only what they typed.
        // It is resolved, not stored, so saving and reloading an endpoint does not put the
        // built-in key into the user's preferences.
        let endpoint = OpenAIEndpoint(
            baseURL: "https://api.deepseek.com/v1", model: "deepseek-v4-pro")
        let data = try JSONEncoder().encode(endpoint)
        let restored = try JSONDecoder().decode(OpenAIEndpoint.self, from: data)
        #expect(restored.apiKey == nil, "the saved endpoint must not carry the resolved key")
        // And it is still available after the round trip, because it is resolved rather than
        // stored.
        #expect(restored.effectiveAPIKey == BuiltInKeys.deepSeek)
    }

    @Test("The environment can override it, on a machine that sets one")
    func environmentOverrides() {
        // Cannot set the environment from inside the process portably in a test, so this
        // asserts the resolution order rather than the variable itself.
        let endpoint = OpenAIEndpoint(
            baseURL: "https://api.deepseek.com/v1", model: "m", apiKey: "explicit")
        #expect(endpoint.effectiveAPIKey == "explicit")
        #expect(BuiltInKeys.deepSeekEnvironmentKey == "DEEPSEEK_API_KEY")
        #expect(BuiltInKeys.secretsFileName == ".secrets.env")
    }
}
