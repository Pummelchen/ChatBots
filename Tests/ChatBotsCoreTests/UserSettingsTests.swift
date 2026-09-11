// ChatBotsCoreTests — settings survive a relaunch, and survive a bumpy upgrade

import ChatBotsCore
import Foundation
import Testing

@Suite("User settings")
struct UserSettingsTests {

    @Test("A full round trip keeps every seat setting")
    func roundTrip() throws {
        var seat = AgentSpec.seat(index: 0)
        seat.personaID = "historian"
        seat.thinking = .high
        seat.backend = .openAIResponses
        seat.openAI = OpenAIEndpoint(
            baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini",
            compatibility: .strict)
        seat.temperature = 0.42
        seat.maxTokens = 1234

        var second = AgentSpec.seat(index: 1)
        second.personaID = "comedian"
        second.thinking = .off

        let settings = UserSettings(
            topic: "Grüße 🥚 日本語", moderatorDraft: "half-typed thought",
            showReasoning: false, seats: [seat, second])

        let data = try #require(settings.encoded())
        let restored = try UserSettings.decoded(from: data)

        #expect(restored.topic == "Grüße 🥚 日本語")
        #expect(restored.moderatorDraft == "half-typed thought")
        #expect(restored.showReasoning == false)
        #expect(restored.seats.count == 2)

        // The values the persona, thinking and backend controls actually set.
        #expect(restored.seats[0].personaID == "historian")
        #expect(restored.seats[0].thinking == .high)
        #expect(restored.seats[0].backend == .openAIResponses)
        #expect(restored.seats[0].openAI.baseURL == "https://api.openai.com/v1")
        #expect(restored.seats[0].openAI.model == "gpt-4o-mini")
        #expect(restored.seats[0].openAI.compatibility == .strict)
        #expect(restored.seats[0].temperature == 0.42)
        #expect(restored.seats[0].maxTokens == 1234)
        #expect(restored.seats[1].personaID == "comedian")
        #expect(restored.seats[1].thinking == .off)
    }

    @Test("A payload from before a field existed still loads")
    func decodesOlderPayload() throws {
        // Only the fields that existed then; everything else must take its default rather
        // than invalidating the file.
        let json = #"{"version":1,"topic":"Why are eggs not round?","showReasoning":true,"seats":[]}"#
        let restored = try UserSettings.decoded(from: Data(json.utf8))
        #expect(restored.topic == "Why are eggs not round?")
        #expect(restored.seats.isEmpty, "an empty roster is corrected by reconciliation")
        #expect(restored.reconciled(supportedSeatCount: 2).seats.count == 2)
    }

    @Test("Unreadable data is reported rather than silently replaced")
    func corruptPayloadThrows() {
        let garbage = Data("this is not json".utf8)
        #expect(throws: (any Error).self) {
            try UserSettings.decoded(from: garbage)
        }
    }

    @Test("A stored roster is reconciled with what the app supports")
    func reconcilesSeatCount() {
        let two = (0..<2).map { AgentSpec.seat(index: $0) }
        let four = (0..<4).map { AgentSpec.seat(index: $0) }

        // Stored more than supported: keep the first ones, in order.
        let trimmed = UserSettings(topic: "t", seats: four).reconciled(supportedSeatCount: 2)
        #expect(trimmed.seats.map(\.id) == ["Agent 1", "Agent 2"])

        // Stored fewer: fill from the roster defaults so every seat has a spec.
        let padded = UserSettings(topic: "t", seats: two).reconciled(supportedSeatCount: 4)
        #expect(padded.seats.count == 4)
        #expect(padded.seats.map(\.id) == ["Agent 1", "Agent 2", "Agent 3", "Agent 4"])

        // An empty roster is replaced outright.
        let filled = UserSettings(topic: "t", seats: []).reconciled(supportedSeatCount: 2)
        #expect(filled.seats.count == 2)

        // And a nonsensical target is passed through untouched rather than crashing.
        #expect(UserSettings(topic: "t", seats: two).reconciled(supportedSeatCount: 0).seats.count == 2)
    }

    @Test("Reconciliation preserves what the user set on the seats it keeps")
    func reconciliationKeepsUserValues() {
        var seat = AgentSpec.seat(index: 0)
        seat.personaID = "skeptic"
        seat.thinking = .minimal
        let settings = UserSettings(topic: "t", seats: [seat]).reconciled(supportedSeatCount: 2)

        #expect(settings.seats[0].personaID == "skeptic")
        #expect(settings.seats[0].thinking == .minimal)
        // The appended seat gets its own defaults, not a copy of the first.
        #expect(settings.seats[1].id == "Agent 2")
        #expect(settings.seats[1].personaID == AgentSpec.defaultPersonaID(forIndex: 1))
    }

    @Test("Defaults are a usable configuration")
    func defaultsAreUsable() {
        let settings = UserSettings.defaults(topic: "Why are eggs not round?")
        #expect(settings.topic == "Why are eggs not round?")
        #expect(settings.showReasoning)
        #expect(settings.seats.count == AgentSpec.SeatRoster.shippingCount)
        #expect(settings.version == UserSettings.currentVersion)
        // Distinct styles, so a fresh install is not two identical participants.
        #expect(Set(settings.seats.map(\.personaID)).count == settings.seats.count)
    }

    @Test("Every field is carried by encoding, including the sampler")
    func encodesEveryField() throws {
        var seat = AgentSpec.seat(index: 0)
        seat.topK = 7
        seat.minP = 0.11
        seat.presencePenalty = -2.5
        seat.repetitionPenalty = 1.25
        seat.contextWindow = 4096
        seat.webSearchEnabled = false
        seat.modelID = "some/other-model"

        let data = try #require(UserSettings(topic: "t", seats: [seat]).encoded())
        let restored = try UserSettings.decoded(from: data).seats[0]

        #expect(restored.topK == 7)
        #expect(restored.minP == 0.11)
        #expect(restored.presencePenalty == -2.5)
        #expect(restored.repetitionPenalty == 1.25)
        #expect(restored.contextWindow == 4096)
        #expect(restored.webSearchEnabled == false)
        #expect(restored.modelID == "some/other-model")
    }
}
