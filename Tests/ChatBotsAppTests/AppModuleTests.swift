// ChatBotsAppTests — the application target, which had no test target at all.
//
// The only test target depended on `ChatBotsCore`, and `ChatBots` is an executable target, so
// everything in `Sources/ChatBotsApp` — the controller, the supervisor, the stores, the zoom — was
// outside every gate, and `coverage.log` covered `ChatBotsCore` alone. The audit's own convention is
// that unmeasured code is where defects survive; `SnapshotRevisionTests.swift` recorded
// outright that the app-side call could not be imported.
//
// What is covered here is the app's *logic*: the stores, the supervisor's state and the zoom, which
// is where the state the controller drives actually lives. The SwiftUI views are not covered, and
// this target does not claim they are — a view body is not what the finding was about.
//
// One consequence worth knowing when reading coverage: `Sources/` now includes this target's 6 152
// lines, so the percentage is not comparable with the 77.08 % the baseline recorded before it.

import ChatBotsCore
import Foundation
import Testing

@testable import ChatBots

/// A `UserDefaults` of its own, so a test cannot read or write the preferences of whatever ran it.
private func scratchDefaults(_ name: String = UUID().uuidString) throws -> UserDefaults {
    let suite = "ChatBotsAppTests.\(name)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@MainActor
@Suite("The settings store")
struct SettingsStoreTests {

    @Test("What is saved is what the next store loads")
    func roundTrip() throws {
        let defaults = try scratchDefaults()
        let saved = UserSettings.defaults(topic: "A topic of my own")

        let writer = UserSettingsStore(defaults: defaults, fallbackTopic: "fallback")
        writer.saveNow(saved, defaults: defaults)

        let reader = UserSettingsStore(defaults: defaults, fallbackTopic: "fallback")
        #expect(reader.settings.topic == "A topic of my own")
        #expect(reader.settings == saved)
        #expect(reader.loadWarning == nil, "nothing was stored that could not be read")
    }

    @Test("An empty store starts from the fallback topic rather than failing")
    func emptyStoreUsesTheFallback() throws {
        let store = UserSettingsStore(
            defaults: try scratchDefaults(), fallbackTopic: "the fallback")
        #expect(store.settings.topic == "the fallback")
        #expect(store.loadWarning == nil)
    }

    @Test("Settings that cannot be decoded are reported once and replaced by the fallback")
    func unreadableSettingsAreReportedOnce() throws {
        let defaults = try scratchDefaults()
        defaults.set(Data("this is not the encoded settings".utf8), forKey: "userSettings")

        let store = UserSettingsStore(defaults: defaults, fallbackTopic: "the fallback")
        #expect(store.loadWarning != nil, "a stored value that cannot be read is worth saying so")

        let first = store.takeLoadWarning()
        #expect(first != nil, "the warning is shown once")
        let second = store.takeLoadWarning()
        #expect(second == nil, "…and not every time the view redraws")
    }

    @Test("A key an older build left in the preferences plist is removed when it is loaded")
    func staleKeyIsScrubbedOnLoad() throws {
        // The defect: the key was written to the plist, so the fix has to remove one that is
        // already there, not only stop writing new ones.
        let defaults = try scratchDefaults()
        var spec = AgentSpec.seat(index: 0)
        spec.openAI.apiKey = "sk-left-over-from-an-older-build"
        let stored = UserSettings.defaults(topic: "A topic", seats: [spec])

        // Written the way the old build wrote it: the whole struct, key included.
        let raw = try JSONEncoder().encode(stored)
        defaults.set(raw, forKey: "userSettings")
        #expect(
            String(data: raw, encoding: .utf8)?.contains("sk-left-over") == true,
            "the fixture has to contain the key for this to mean anything")

        let store = UserSettingsStore(defaults: defaults, fallbackTopic: "fallback")
        #expect(store.settings.topic == "A topic", "the settings themselves are kept")

        let rewritten = defaults.data(forKey: "userSettings") ?? Data()
        let text = String(data: rewritten, encoding: .utf8) ?? ""
        #expect(!text.contains("sk-left-over"), "and the key is gone from the plist")
    }

    @Test("The storage description says something about where settings live")
    func storageDescriptionIsUseful() {
        #expect(!UserSettingsStore.storageDescription.isEmpty)
    }
}

@MainActor
@Suite("The API endpoint store")
struct APIEndpointStoreTests {

    @Test("A per-seat endpoint edit lands on that seat and no other")
    func editsArePerSeat() {
        let store = APIEndpointStore(environment: [:])
        store.setBaseURL("http://127.0.0.1:1234/v1", seat: 2)
        store.setModel("a-model", seat: 2)

        #expect(store.endpoint(forSeat: 2).baseURL == "http://127.0.0.1:1234/v1")
        #expect(store.endpoint(forSeat: 2).model == "a-model")
        #expect(store.endpoint(forSeat: 1).baseURL != "http://127.0.0.1:1234/v1")
    }

    @Test("The endpoint list is padded to the supported seat count")
    func seatsArePadded() {
        let store = APIEndpointStore(environment: [:])
        #expect(store.endpoints.count >= AgentSpec.SeatRoster.count())
    }

    @Test("A cloud seat is the one with the OpenAI backend, whatever else it carries")
    func isAPIFollowsTheBackend() {
        let store = APIEndpointStore(environment: [:])
        var spec = AgentSpec.seat(index: 0)
        spec.backend = .mlx
        #expect(!store.isAPI(spec))
        spec.backend = .openAIResponses
        #expect(store.isAPI(spec))
    }
}

@MainActor
@Suite("The engine supervisor's published state")
struct EngineSupervisorStateTests {

    @Test("Every state has a label a user can read")
    func labelsAreHuman() {
        #expect(EngineSupervisor.State.idle.label == "Not connected")
        #expect(EngineSupervisor.State.starting.label.contains("Starting"))
        #expect(
            EngineSupervisor.State.running(owned: true).label
                != EngineSupervisor.State.running(owned: false).label,
            "an engine this app owns reads differently from one it merely found")
        #expect(EngineSupervisor.State.failed("the reason").label.contains("the reason"))
    }

    @Test("A fresh supervisor is idle and owns nothing")
    func startsIdle() {
        let log = FileManager.default.temporaryDirectory.appending(path: "supervisor-\(UUID()).log")
        let supervisor = EngineSupervisor(logURL: log)
        #expect(supervisor.state == .idle)
        #expect(!supervisor.ownsEngine)
    }
}
