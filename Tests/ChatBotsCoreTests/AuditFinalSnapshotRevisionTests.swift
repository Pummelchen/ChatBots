// ChatBotsCoreTests — A110: snapshots are ordered by a revision, not by the wall clock
//
// A48's guard ordered snapshots by `serverTime`, which `ProtocolCodec` encodes ISO-8601 and is
// therefore whole-second: two snapshots inside one second compare equal, so a `run` reply
// racing a push could apply an older `status` last. The same absent field had a second
// consequence — the guard was the wall clock, so a backwards clock step made every later
// snapshot look stale and froze the interface.
//
// The engine now stamps every snapshot with a monotonic revision, and the ordering rule is
// `APISnapshot.isOlder(than:)`, which the app's guard calls. The app-side call itself cannot be
// imported by this test target (the SwiftUI app is an executable target, and Package.swift is
// fixed), so what is pinned here is the wire field, its Codec round trip, the engine's stamping
// and the ordering rule.

@testable import ChatBotsCore
import Foundation
import Testing

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
private func service() -> EngineService {
    let specs = AgentSpec.makeSeats(count: 2)
    let seats = specs.map { ConversationEngine.Seat(spec: $0, engine: QuietEngine(spec: $0)) }
    let engine = ConversationEngine(seats: seats, configuration: .init())
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "audit-final-a110-\(UUID().uuidString)")
    return EngineService(engine: engine, store: ConversationStore(directory: directory))
}

@Suite("Snapshot ordering uses a monotonic revision (A110)")
@MainActor
struct AuditFinalSnapshotRevisionTests {

    private func base() -> APISnapshot { service().snapshot() }

    @Test("Two snapshots in the same second are ordered by revision")
    func revisionOrdersWithinASecond() {
        let second = Date(timeIntervalSince1970: 1_800_000_000)
        var older = base()
        older.serverTime = second
        older.revision = 7
        var newer = base()
        newer.serverTime = second
        newer.revision = 8

        // Held in locals so a failure prints a Bool rather than two whole snapshots.
        let olderLooksStale = older.isOlder(than: newer)
        let newerLooksStale = newer.isOlder(than: older)
        let selfLooksStale = older.isOlder(than: older)
        #expect(olderLooksStale, "the same whole second cannot separate these")
        #expect(!newerLooksStale)
        #expect(!selfLooksStale, "a snapshot is not older than itself")
    }

    @Test("A backwards clock step does not make a newer snapshot look stale")
    func backwardsClockDoesNotFreeze() {
        var applied = base()
        applied.serverTime = Date(timeIntervalSince1970: 1_800_000_000)
        applied.revision = 12
        var incoming = base()
        // The clock went backwards: the newer snapshot carries an earlier wall time.
        incoming.serverTime = Date(timeIntervalSince1970: 1_799_999_000)
        incoming.revision = 13

        let looksStale = incoming.isOlder(than: applied)
        #expect(
            !looksStale, "the revision must win, or every later snapshot freezes the interface")
        // The old rule would have called it stale, which is the defect being pinned.
        #expect(incoming.serverTime < applied.serverTime, "the clock really did move backwards")
    }

    @Test("An engine that sends no revision falls back to the clock")
    func fallbackForOlderPeer() {
        let later = Date(timeIntervalSince1970: 1_800_000_000)
        let earlier = Date(timeIntervalSince1970: 1_799_999_000)

        // Neither side has a revision: the wall clock, as before.
        var applied = base()
        applied.serverTime = later
        applied.revision = nil
        var incoming = base()
        incoming.serverTime = earlier
        incoming.revision = nil
        let incomingLooksStale = incoming.isOlder(than: applied)
        let appliedLooksStale = applied.isOlder(than: incoming)
        #expect(incomingLooksStale)
        #expect(!appliedLooksStale)

        // The incoming snapshot has a revision but the applied one does not — a peer that
        // upgraded mid-session. There is no common counter, so the clock decides.
        incoming.revision = 99
        let mixedLooksStale = incoming.isOlder(than: applied)
        #expect(mixedLooksStale, "an incomparable revision must not be trusted")
        var newerByClock = base()
        newerByClock.serverTime = Date(timeIntervalSince1970: 1_800_000_001)
        newerByClock.revision = 1
        let newerLooksStale = newerByClock.isOlder(than: applied)
        #expect(!newerLooksStale)
    }

    @Test("The engine stamps a strictly increasing revision on every snapshot")
    func engineStampsMonotonicRevisions() throws {
        let service = service()
        let first = service.snapshot()
        let second = service.snapshot()
        let third = service.snapshot()

        let r1 = try #require(first.revision)
        let r2 = try #require(second.revision)
        let r3 = try #require(third.revision)
        #expect(r1 < r2)
        #expect(r2 < r3)
        #expect(!second.isOlder(than: first))
        let firstLooksStale = first.isOlder(than: second)
        #expect(firstLooksStale)
    }

    @Test("The revision survives the protocol codec")
    func codecRoundTrip() throws {
        var snapshot = base()
        snapshot.revision = 4_242
        // ISO-8601 is whole-second, so give it a whole second to compare exactly.
        snapshot.serverTime = Date(timeIntervalSince1970: 1_800_000_000)

        let data = try ProtocolCodec.encode(EngineReply.state(snapshot))
        let decoded = try ProtocolCodec.decodeReply(data)
        let restored = try #require(decoded.snapshot)
        #expect(restored.revision == 4_242)
        #expect(restored.serverTime == snapshot.serverTime)
        #expect(restored.topic == snapshot.topic)
    }

    @Test("A payload from an engine that predates the field still decodes")
    func payloadWithoutRevisionDecodes() throws {
        var snapshot = base()
        snapshot.revision = 4_242
        snapshot.serverTime = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try ProtocolCodec.encode(EngineReply.state(snapshot))

        // The field is optional and omitted when nil, so removing it is exactly what an older
        // engine's frame looks like on the wire.
        // `EngineReply.state` encodes as `{"state":{"_0":{…}}}`, the synthesized shape for an
        // enum case with an associated value.
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wrapper = try #require(root["state"] as? [String: Any])
        var snapshotObject = try #require(wrapper["_0"] as? [String: Any])
        snapshotObject.removeValue(forKey: "revision")
        var strippedWrapper = wrapper
        strippedWrapper["_0"] = snapshotObject
        var stripped = root
        stripped["state"] = strippedWrapper
        let olderWire = try JSONSerialization.data(withJSONObject: stripped)

        let decoded = try ProtocolCodec.decodeReply(olderWire)
        let restored = try #require(decoded.snapshot)
        #expect(restored.revision == nil, "a missing revision decodes as absent, not as an error")
        #expect(restored.topic == snapshot.topic, "the rest of the state is unaffected")
    }
}
