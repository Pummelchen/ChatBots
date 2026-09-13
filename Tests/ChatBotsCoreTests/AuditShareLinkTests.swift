// ChatBotsCoreTests — A99: a share link points at the origin that served the page
//
// A share link used to be built from the engine's own loopback address, which is right for a browser
// on the Mac running the engine and unreachable from the phone the feature exists for. The engine now
// takes an origin from the request's `Host` header, and the web interface prefers the origin it was
// loaded from.
//
// The `Host` header is client-supplied, so reflecting it into a URL is only safe behind a check. That
// check is pure, and this is where it is pinned: the wiring around it needs a socket, but the
// decision about what may be reflected does not.

import Testing

@testable import ChatBotsCore

@Suite("A share link is built from a host that may be reflected (A99)")
struct AuditShareLinkTests {

    @Test("A host and port are accepted as they are")
    func ordinaryHostsPassThrough() {
        #expect(APIServer.validShareHost("192.168.1.5:7788") == "192.168.1.5:7788")
        #expect(APIServer.validShareHost("localhost:7788") == "localhost:7788")
        #expect(APIServer.validShareHost("chatbots.local") == "chatbots.local")
        // Bracketed IPv6, which is what a browser sends for a literal address.
        #expect(APIServer.validShareHost("[::1]:7788") == "[::1]:7788")
    }

    @Test("Anything that is not a host is refused rather than interpolated")
    func everythingElseIsRefused() {
        // A path, so a reflected link could be pointed somewhere else entirely.
        #expect(APIServer.validShareHost("evil.example/../admin") == nil)
        // Userinfo, which turns the origin into an authority for someone else.
        #expect(APIServer.validShareHost("user@host") == nil)
        #expect(APIServer.validShareHost("user:pass@host") == nil)
        // Whitespace and control characters, which is how a header value is smuggled.
        #expect(APIServer.validShareHost("host name") == nil)
        #expect(APIServer.validShareHost("host\nX: y") == nil)
        #expect(APIServer.validShareHost("host\t") == nil)
        // Nothing, and something absurdly long.
        #expect(APIServer.validShareHost("") == nil)
        #expect(APIServer.validShareHost(nil) == nil)
        #expect(APIServer.validShareHost(String(repeating: "a", count: 256)) == nil)
        #expect(APIServer.validShareHost(String(repeating: "a", count: 255)) != nil)
    }
}
