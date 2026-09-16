// ChatBotsCoreTests — the client's event buffer, and a frame it cannot read.
//
// The server bounded each client's event stream at 256 (`.bufferingNewest(256)`) and the client
// built its own with `.unbounded`. So the bound was one-sided: a consumer that stopped draining — a stalled
// interface, a paused window, a test that simply does not read — let the client retain every event the
// engine sent, which is exactly the retention the server's bound exists to prevent. The depth is one shared
// constant now, used by the engine's own stream, the server's per-session stream and the client's.
//
// And the client's reader decoded each payload with `try?` and `continue`d on failure, so a frame this
// build cannot read vanished with no trace. It is counted and its reason kept: not fatal, because the
// framing is intact and an app may be attached to an engine of another build.

import Foundation
import Testing

@testable import ChatBotsCore

@MainActor
@Suite("The client's event stream is bounded where the server's is", .serialized, TransportSerialized())
struct ClientEventBufferTests {

    @Test("A consumer that stops draining cannot make the client retain every event")
    func theClientStreamIsBounded() async throws {
        // A burst past the bound, paced so the server's writer keeps up: if the server were the one dropping,
        // this would measure the wrong buffer.
        let burst = ProtocolLimits.eventBufferDepth + 40
        let fixture = try await makeTransportFixture(maximumTurns: 1) { spec in
            ChattyTransportStub(spec: spec, fragments: burst)
        }
        defer { TransportTeardown.register { await fixture.stop() } }
        try await fixture.server.start()

        let client = makeEngineClient(port: fixture.port)
        try await client.connect()
        defer { TransportTeardown.register { await client.disconnect() } }

        // Nobody drains `client.events` while the room writes. This is the consumer that fell behind.
        fixture.engine.startOrRestart()
        await fixture.engine.waitUntilFinished()

        // Then the consumer arrives. With the buffer bounded it sees the newest `eventBufferDepth` events;
        // unbounded, it sees every one of them.
        let events = try #require(client.events, "the client has no event stream")
        let collected = Task { @MainActor in
            var count = 0
            for await _ in events { count += 1 }
            return count
        }
        try? await Task.sleep(for: .milliseconds(500))
        await client.disconnect()
        let received = await collected.value

        #expect(
            received <= ProtocolLimits.eventBufferDepth,
            "the client retained \(received) events; the bound is \(ProtocolLimits.eventBufferDepth)")
        #expect(received > 0, "the client was sent nothing at all, so this proves nothing")
    }

    @Test("The request channel lets one holder in at a time, and hands over to the waiter")
    func theRequestSlotIsExclusive() async {
        let slot = RequestSlot()
        await slot.acquire()

        var secondHolder = false
        let waiting = Task { @MainActor in
            await slot.acquire()
            secondHolder = true
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!secondHolder, "a second holder took the channel while it was held")

        slot.release()
        _ = await waiting.value
        #expect(secondHolder, "the waiter never got the channel")
        slot.release()
    }

    @Test("A frame this build cannot read is recorded rather than swallowed")
    func anUnreadableFrameIsRecorded() throws {
        let client = makeEngineClient(port: 1)

        // A well-formed *request* payload: valid JSON for the codec, and not a frame. An engine of another
        // build is the honest reason this can happen at all.
        let unreadable = try ProtocolCodec.encode(EngineRequest.fetchState)
        #expect(client.decodedFrame(unreadable) == nil, "a request decoded as a frame")
        #expect(client.unreadableFrames == 1)
        #expect(
            client.lastUnreadableFrame?.contains("Could not decode") == true,
            "the reason should be the codec's: \(client.lastUnreadableFrame ?? "nothing")")

        // The counterweight: a frame this build does know decodes, and is not counted as unreadable.
        let readable = try ProtocolCodec.encode(EngineFrame.reply(.refused("no")))
        #expect(client.decodedFrame(readable)?.asReply != nil)
        #expect(client.unreadableFrames == 1, "a readable frame was counted as unreadable")
    }
}
