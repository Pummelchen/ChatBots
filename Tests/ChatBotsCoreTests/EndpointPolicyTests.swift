// ChatBotsCoreTests — where a configured endpoint may point.
//
// A seat's base URL is configuration, and before the origin rule any web page could set it. It went into
// `URL(string:)` with no scheme or host check and was fetched by a session that followed redirects,
// so `file:///…` read the local disk and `http://169.254.169.254/…` reached a cloud metadata service
// whose error body is echoed into the snapshot every front end displays.
//
// What is *not* refused matters as much as what is: loopback and LAN addresses are how LM Studio and
// Ollama are reached, which is the app's main use, so the rules are scheme and link-local only.

import Foundation
import Testing

@testable import ChatBotsCore

@Suite("A configured endpoint is checked before anything is sent to it")
struct EndpointPolicyTests {

    private func refusal(_ baseURL: String, path: String = "/v1/responses") -> String? {
        guard let url = URL(string: baseURL + path) else { return "unparseable" }
        return OpenAIEndpoint.endpointRefusal(url)
    }

    @Test("A base URL that is not http or https is refused")
    func nonHTTPSchemesAreRefused() {
        #expect(refusal("file:///etc/passwd", path: "") != nil, "file:// made a request read the disk")
        #expect(refusal("ftp://example.com") != nil)
        #expect(refusal("data:text/plain,hello", path: "") != nil)
        #expect(
            OpenAIEndpoint(baseURL: "file:///etc").responsesURL == nil,
            "and the endpoint produces no URL at all, so there is nothing to fetch")
    }

    @Test("A link-local address is refused")
    func linkLocalIsRefused() {
        // The cloud metadata service every SSRF write-up starts with.
        #expect(refusal("http://169.254.169.254") != nil)
        #expect(refusal("http://169.254.0.1:8080") != nil)
        #expect(refusal("http://[fe80::1]") != nil)
    }

    @Test("The endpoints this app is actually for are allowed")
    func localAndLANEndpointsStillWork() {
        // Refusing these would close the finding by breaking the product.
        #expect(refusal("http://localhost:1234") == nil)
        #expect(refusal("http://127.0.0.1:1234") == nil)
        #expect(refusal("http://192.168.1.10:1234") == nil)
        #expect(refusal("http://ollama.local:11434") == nil, "a LAN name is how a second Mac is reached")
        #expect(refusal("https://api.deepseek.com") == nil)
        // And they still produce the URL they always did.
        #expect(
            OpenAIEndpoint(baseURL: "http://localhost:1234").responsesURL?.absoluteString
                == "http://localhost:1234/v1/responses")
        #expect(
            OpenAIEndpoint(baseURL: "https://api.deepseek.com/v1").responsesURL?.absoluteString
                == "https://api.deepseek.com/v1/responses")
    }

    @Test("A refused endpoint fails as itself, and says which rule refused it")
    func refusedEndpointIsItsOwnError() async {
        let client = OpenAIResponsesClient(endpoint: OpenAIEndpoint(baseURL: "http://169.254.169.254"))
        var thrown: (any Error)?
        do {
            for try await _ in client.stream(OpenAIResponsesClient.Request(input: "hello")) {
                Issue.record("nothing should stream from a refused endpoint")
            }
        } catch {
            thrown = error
        }
        guard case .refusedEndpoint(let value, let reason)? = thrown as? OpenAIResponsesError else {
            Issue.record("expected a refusedEndpoint error, got \(String(describing: thrown))")
            return
        }
        #expect(value.contains("169.254"))
        #expect(reason.contains("link-local"))
    }

    @Test("A redirect is not followed")
    func redirectsAreNotFollowed() async throws {
        // A local server that answers 302 to a link-local address, which is the shape a validated
        // endpoint would otherwise use to reach a host that was never validated. The client must
        // report the 302 rather than fetching what it points at.
        let server = try RedirectingServer(target: "http://169.254.169.254/latest/meta-data/")
        defer { server.stop() }
        let client = OpenAIResponsesClient(endpoint: OpenAIEndpoint(baseURL: server.base))

        var thrown: (any Error)?
        do {
            for try await _ in client.stream(OpenAIResponsesClient.Request(input: "hello")) {
                Issue.record("a redirect must not produce a stream")
            }
        } catch {
            thrown = error
        }
        guard case .http(let status, _)? = thrown as? OpenAIResponsesError else {
            Issue.record("expected an http error for the redirect itself, got \(String(describing: thrown))")
            return
        }
        #expect(status == 302, "the redirect response is the answer, not an invitation")
    }

    @Test("The models probe uses the same policy and the same redirect refusal as generation")
    func modelsProbeHonoursBothControls() async throws {
        // The reachability probe used to build its own URL and call `URLSession.shared`, which
        // skipped `endpointRefusal` and followed redirects while the Authorization header was
        // attached — a link-local or `file://` base URL was fetched and a 302 was followed to a
        // host the check never saw.
        #expect(
            OpenAIEndpoint(baseURL: "http://169.254.169.254").modelsURL == nil,
            "the probe URL must be refused exactly as the generation URL is")
        #expect(
            OpenAIEndpoint(baseURL: "file:///etc").modelsURL == nil,
            "a file:// base URL must produce no probe URL")
        #expect(
            OpenAIEndpoint(baseURL: "http://localhost:1234").modelsURL?.absoluteString
                == "http://localhost:1234/v1/models")
        #expect(
            OpenAIEndpoint(baseURL: "https://api.deepseek.com/v1").modelsURL?.absoluteString
                == "https://api.deepseek.com/v1/models")

        let server = try RedirectingServer(target: "http://169.254.169.254/latest/meta-data/")
        defer { server.stop() }
        let client = OpenAIResponsesClient(endpoint: OpenAIEndpoint(baseURL: server.base))

        var thrown: (any Error)?
        do {
            _ = try await client.modelsBody()
        } catch {
            thrown = error
        }
        guard case .http(let status, _)? = thrown as? OpenAIResponsesError else {
            Issue.record(
                "the probe must report the 302, not follow it; got \(String(describing: thrown))")
            return
        }
        #expect(status == 302, "the redirect response is the answer, not an invitation")
    }
}

/// A minimal HTTP server that answers every request with a redirect.
private struct RedirectingServer {
    let base: String
    private let listener: Int32
    private let thread: Thread

    init(target: String) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RedirectingServerError.cannotBind }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw RedirectingServerError.cannotBind
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        self.listener = descriptor
        self.base = "http://127.0.0.1:\(UInt16(bigEndian: actual.sin_port))"
        self.thread = Thread {
            // One connection is all this test makes; accept, answer, close.
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var scratch = [UInt8](repeating: 0, count: 4096)
            _ = read(client, &scratch, scratch.count)
            let response = """
                HTTP/1.1 302 Found\r
                Location: \(target)\r
                Content-Length: 0\r
                Connection: close\r
                \r

                """
            _ = response.withCString { write(client, $0, strlen($0)) }
        }
        thread.start()
    }

    func stop() {
        close(listener)
    }
}

private enum RedirectingServerError: Error { case cannotBind }
