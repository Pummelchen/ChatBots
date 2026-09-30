// ChatBotsCoreTests — the output ceiling on the wire
//
// The app has always been able to hold a seat to a readable pace and the website never could: the
// engine took the value over `POST /api/seat` but did not report it, so a page could neither show
// what a seat was set to nor learn what this build means by "a readable pace" without copying the
// number into the page. Both are on the snapshot now, and both are optional, because a frame from an
// engine that predates them has to keep decoding: a missing ceiling means "none", not a broken state.

import Foundation
import Testing

@testable import ChatBotsCore

/// An engine that does nothing, so a real `EngineService` can stamp a snapshot without weights.
private actor QuietEngine: LLMEngine {
    nonisolated let spec: AgentSpec
    init(spec: AgentSpec) { self.spec = spec }

    var isLoaded: Bool { true }
    var contextWindow: Int { spec.contextWindow }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String { "" }
}

@MainActor
private func service(ceilings: [Double?]) -> EngineService {
    let specs = AgentSpec.makeSeats(count: ceilings.count).enumerated().map { index, spec in
        var copy = spec
        copy.maximumTokensPerSecond = ceilings[index]
        return copy
    }
    let seats = specs.map { ConversationEngine.Seat(spec: $0, engine: QuietEngine(spec: $0)) }
    let engine = ConversationEngine(seats: seats, configuration: .init())
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "seats-pace-\(UUID().uuidString)")
    return EngineService(engine: engine, store: ConversationStore(directory: directory))
}

@Suite("The output ceiling on the wire")
@MainActor
struct SeatPaceSnapshotTests {

    @Test("A snapshot reports each seat's ceiling, so a page can show it")
    func snapshotReportsEachCeiling() {
        let snapshot = service(ceilings: [10, nil, 0]).snapshot()

        // Three different states have to survive the trip: held to ten, never given one, and
        // deliberately switched off. `0` and `nil` mean the same thing to the engine but not to a
        // reader — an interface that showed "off" for both would be right by accident.
        #expect(snapshot.seats.map(\.maximumTokensPerSecond) == [10, nil, 0])
    }

    @Test("The snapshot carries what this build means by a readable pace")
    func snapshotCarriesTheReadableRate() {
        let snapshot = service(ceilings: [nil, nil]).snapshot()

        // The page sends this number to switch a ceiling on, so it comes from `AgentSpec` rather
        // than being written into the JavaScript as a second copy that can drift.
        #expect(snapshot.readableTokensPerSecond == AgentSpec.readableTokensPerSecond)
        #expect(snapshot.readableTokensPerSecond == 10)
    }

    @Test("A frame from an engine that predates both fields still decodes")
    func olderFrameStillDecodes() throws {
        let snapshot = service(ceilings: [10, nil]).snapshot()
        let data = try ProtocolCodec.encode(EngineReply.state(snapshot))

        // Both fields are optional and omitted when nil, so removing them is exactly what an older
        // engine's frame looks like on the wire.
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wrapper = try #require(root["state"] as? [String: Any])
        var state = try #require(wrapper["_0"] as? [String: Any])
        state.removeValue(forKey: "readableTokensPerSecond")
        var seats = try #require(state["seats"] as? [[String: Any]])
        for index in seats.indices { seats[index].removeValue(forKey: "maximumTokensPerSecond") }
        state["seats"] = seats
        var strippedWrapper = wrapper
        strippedWrapper["_0"] = state
        var stripped = root
        stripped["state"] = strippedWrapper

        let decoded = try ProtocolCodec.decodeReply(
            try JSONSerialization.data(withJSONObject: stripped))
        let restored = try #require(decoded.snapshot)

        #expect(restored.readableTokensPerSecond == nil, "an absent rate is absent, not an error")
        #expect(
            restored.seats.allSatisfy { $0.maximumTokensPerSecond == nil },
            "and an absent ceiling reads as none")
        #expect(restored.seats.count == 2, "the rest of the seat is unaffected")
    }
}
