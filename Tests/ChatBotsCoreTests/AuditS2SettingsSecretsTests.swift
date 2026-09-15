// ChatBotsCoreTests — what settings are allowed to store (A139).
//
// The per-seat cloud API key was placed into `AgentSpec.openAI.apiKey` and `UserSettings.encoded()`
// wrote the seat array to `UserDefaults` — a plist under `~/Library/Preferences`, readable by anything
// running as this user — while `APIEndpointStore` deliberately nils the key when it copies an endpoint
// and the endpoint sheet tells the user "Keys are stored in the macOS Keychain". The persistence path
// did neither.
//
// The rule is in `encoded()`, which is the only function that writes settings at all, so no caller can
// forget it.

import ChatBotsCore
import Foundation
import Testing

@Suite("Settings do not store the cloud API keys (A139)")
struct SettingsSecretsTests {

    private let key = "sk-not-a-real-key-but-shaped-like-one"

    private func settingsWithAKey() -> UserSettings {
        var spec = AgentSpec.seat(index: 0)
        spec.openAI.baseURL = "https://api.example.com/v1"
        spec.openAI.model = "a-model"
        spec.openAI.apiKey = key
        return UserSettings.defaults(topic: "A topic", seats: [spec])
    }

    @Test("The encoded payload does not contain the key")
    func encodedPayloadHasNoKey() throws {
        let data = try #require(settingsWithAKey().encoded())
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(!text.contains(key), "the key must not be in what goes to the preferences plist")
        #expect(!text.contains("sk-not-a-real"), "not even its beginning")
    }

    @Test("Everything that is not a secret still round-trips")
    func theRestRoundTrips() throws {
        let original = settingsWithAKey()
        let data = try #require(original.encoded())
        let restored = try UserSettings.decoded(from: data)

        #expect(restored.topic == original.topic)
        #expect(restored.seats.count == original.seats.count)
        #expect(restored.seats[0].displayName == original.seats[0].displayName)
        #expect(restored.seats[0].personaID == original.seats[0].personaID)
        // The endpoint itself is not a secret: dropping it would lose the seat's configuration.
        #expect(restored.seats[0].openAI.baseURL == "https://api.example.com/v1")
        #expect(restored.seats[0].openAI.model == "a-model")
        #expect(restored.seats[0].openAI.apiKey == nil, "and the key is the one thing left out")
    }

    @Test("Every seat is cleared, not just the first")
    func everySeatIsCleared() throws {
        var first = AgentSpec.seat(index: 0)
        first.openAI.apiKey = key
        var second = AgentSpec.seat(index: 1)
        second.openAI.apiKey = "another-key"
        let settings = UserSettings.defaults(topic: "Two seats", seats: [first, second])

        let cleared = settings.withoutSecrets()
        #expect(cleared.seats.allSatisfy { $0.openAI.apiKey == nil })
        let data = try #require(settings.encoded())
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(!text.contains("another-key"))
    }

    @Test("Clearing the keys leaves the original settings usable")
    func clearingDoesNotMutateTheOriginal() {
        // A value type, but this is the assertion that keeps it one if the seats ever become a
        // reference type: the live controller still needs its key to make requests.
        let original = settingsWithAKey()
        _ = original.withoutSecrets()
        #expect(original.seats[0].openAI.apiKey == key)
    }
}
