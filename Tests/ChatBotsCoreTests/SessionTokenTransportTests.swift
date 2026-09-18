// ChatBotsCoreTests — the engine's answer to "which engine are you?"
//
// `.identify` is a request like any other on the one tagged stream, so the client's reply matching
// has to know it: an `.identified` reply answers an `.identify` request and nothing else. These
// tests drive the real listener and the real client, which is the only way to see that the whole
// path agrees — the file rules are in `SessionTokenTests`.

import Foundation
import Testing

@testable import ChatBotsCore

@MainActor
@Suite("The engine proves its identity over the transport", .serialized, TransportSerialized())
struct SessionTokenTransportTests {

    @Test("A client is answered with the token the engine was started with")
    func identifyReturnsTheToken() async throws {
        let fixture = try await makeTransportFixture(sessionToken: "the-run-token")
        defer { TransportTeardown.register { await fixture.stop() } }
        try await fixture.server.start()

        let client = makeEngineClient(port: fixture.port)
        defer { TransportTeardown.register { await client.disconnect() } }
        try await client.connect()

        #expect(try await client.identify() == "the-run-token")
    }

    @Test("An engine started without a token refuses rather than echoing an empty one")
    func noTokenRefuses() async throws {
        let fixture = try await makeTransportFixture()
        defer { TransportTeardown.register { await fixture.stop() } }
        try await fixture.server.start()

        let client = makeEngineClient(port: fixture.port)
        defer { TransportTeardown.register { await client.disconnect() } }
        try await client.connect()

        #expect(try await client.identify() == nil)
    }
}
