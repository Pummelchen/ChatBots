// ChatBotsCoreTests — the token never reaches the unauthenticated HTTP API
//
// The whole point of answering `.identify` on the transport only is that `/api/*` has no password
// and listens on every interface the deployment gives it. So this is the invariant, pinned from
// outside: a plausible identity path is a 404 over a real socket, and the bytes the HTTP API does
// serve — the state snapshot — do not contain the token anywhere.

import ChatBotsCore
import Foundation
import Testing

@MainActor
@Suite("The session token is not reachable over HTTP")
struct SessionTokenHTTPTests {

    @Test("There is no HTTP route that asks the engine to identify itself")
    func noIdentifyRoute() async throws {
        let fixture = try await makeAPIServerFixture(sessionToken: "the-run-token")
        defer { fixture.server.stop() }

        // A POST, because a GET 404 falls through to the static-asset fallback; a command is what
        // a token request would be, and a command that is not a route is a 404.
        for path in ["/api/identify", "/api/identity", "/api/session-token"] {
            let url = try #require(URL(string: "\(fixture.base)\(path)"))
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)

            let (_, response) = try await fixture.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            #expect(status == 404, "\(path) answered \(status.map(String.init) ?? "nothing")")
        }
    }

    @Test("No snapshot the HTTP API serves contains the token")
    func snapshotCarriesNoToken() async throws {
        // Issued rather than written out here, for two reasons. A literal 64-character hex string
        // sitting next to the word `token` is what `gitleaks` reports as a generic API key, and this
        // repository's CI fails on that — a test fixture that trips the secret scanner costs more
        // than it proves. And a token the engine actually produced is a better subject for "the API
        // must not serve this" than one invented in the test.
        let runDirectory = FileManager.default.temporaryDirectory
            .appending(path: "session-token-http-\(UUID().uuidString)")
        let token = try SessionToken.issue(in: runDirectory)
        defer { SessionToken.remove(from: runDirectory) }
        let fixture = try await makeAPIServerFixture(sessionToken: token)
        defer { fixture.server.stop() }

        let url = try #require(URL(string: "\(fixture.base)/api/state"))
        let (data, _) = try await fixture.session.data(from: url)
        let served = String(data: data, encoding: .utf8) ?? ""
        #expect(!served.contains(token), "the state the web API serves must not carry the token")

        // And not in the snapshot itself, whatever a transport does with it: the token lives on
        // `EngineService`, not in the type every front end serialises.
        let encoded = try JSONEncoder().encode(fixture.server.engineService.snapshot())
        let snapshot = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!snapshot.contains(token), "APISnapshot must not carry the token")
    }
}
