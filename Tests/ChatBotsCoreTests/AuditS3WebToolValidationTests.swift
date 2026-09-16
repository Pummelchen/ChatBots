// ChatBotsCoreTests — what `fetch_page` will accept as a URL (A159).
//
// The guard was `URL(string:)` and `url.scheme?.hasPrefix("http")`, and both halves were wrong in a way the
// probe in `AUDIT/baseline/swift64/a159-probe/url-shapes.swift` measures:
//
//   * `httpx://example.com` and `httpfoo://example.com` were accepted — schemes this tool does not claim,
//     handed to the extractor because they began with the right four letters;
//   * `http:`, `http://` and `http:///path` were accepted — they parse as URLs and name nothing to fetch;
//   * `HTTP://EXAMPLE.COM` and `Https://example.com` were *refused* — the same two schemes, spelled the way
//     RFC 3986 §3.1 allows;
//   * `http://example.com/a b` was accepted, and that space would travel to the extractor inside the URL.
//
// The argument is model-controlled, so this is a boundary: the shape that crosses it should be the shape the
// tool documents.

import Foundation
import Testing

@testable import ChatBotsCore

@Suite("What fetch_page accepts as a URL (A159)")
struct WebToolURLValidationTests {

    @Test("An ordinary http or https URL is accepted")
    func ordinaryURLsAreAccepted() throws {
        for raw in [
            "https://example.com/article",
            "http://example.com",
            "https://example.com:8443/x?q=1#f",
            "http://127.0.0.1:1/x",
            "http://[::1]:1/x",
            "https://sub.example.co.uk/a/b/c.html",
        ] {
            #expect(FetchPageTool.readableURL(raw) != nil, "\(raw) was refused")
        }
    }

    @Test("The scheme is matched exactly, and without regard to case")
    func theSchemeIsExact() throws {
        // The two the tool claims, in any spelling: schemes are case-insensitive, and these used to be
        // refused while `httpx:` was accepted.
        for raw in ["HTTP://EXAMPLE.COM/x", "Https://example.com", "hTTpS://example.com/x"] {
            #expect(FetchPageTool.readableURL(raw) != nil, "\(raw) was refused")
        }
        // And nothing else, however much it looks like http at the front. Each of these was accepted.
        for raw in [
            "httpx://example.com",
            "httpfoo://example.com",
            "httpsx://example.com",
            "ftp://example.com",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<b>x</b>",
        ] {
            #expect(FetchPageTool.readableURL(raw) == nil, "\(raw) was accepted")
        }
    }

    @Test("A URL with no host is refused")
    func aHostIsRequired() throws {
        // All three parse as URLs; none names anything to fetch.
        for raw in ["http:", "http://", "http:///path", "https://", "http://?q=1"] {
            #expect(FetchPageTool.readableURL(raw) == nil, "\(raw) was accepted")
        }
        // The counterweight: the same scheme with a host is fine, including a bare host and a port.
        #expect(FetchPageTool.readableURL("http://example.com") != nil)
        #expect(FetchPageTool.readableURL("http://example.com:80") != nil)
    }

    @Test("Whitespace is refused, and a relative reference with no scheme")
    func theShapeIsAnAbsoluteURL() throws {
        for raw in [
            "http://example.com/a b",
            "http://exa mple.com/x",
            "http://example.com/a\nb",
            "http://example.com/a\tb",
            "example.com/x",
            "/api/state",
            "",
            "   ",
        ] {
            #expect(FetchPageTool.readableURL(raw) == nil, "\(raw.debugDescription) was accepted")
        }
        // Surrounding whitespace is trimmed rather than refused: that is the model being sloppy, not wrong.
        // A trailing newline is the same case, which is why the refusal is about whitespace *inside*.
        #expect(FetchPageTool.readableURL("  https://example.com/x  ") != nil)
        #expect(FetchPageTool.readableURL("https://example.com/x\n") != nil)
    }

    @Test("The tool refuses a URL it cannot read, before it asks the extractor anything")
    func theToolRefusesWithoutReachingTheExtractor() async throws {
        // No API key is configured in the test environment, so anything that reached the client would fail
        // with a different sentence. This pins that the refusal happens first — the argument is the model's,
        // and a bad one is an answer to the model rather than a request to Tavily.
        let tool = FetchPageTool()
        do {
            _ = try await tool.run(argument: "httpx://example.com")
            Issue.record("an unreadable URL was passed to the extractor")
        } catch let error as ChatBotsError {
            #expect(error.localizedDescription.contains("is not a readable http(s) URL"))
            #expect(error.localizedDescription.contains("httpx://example.com"), "the argument is quoted back")
        }
    }
}
