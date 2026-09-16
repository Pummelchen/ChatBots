// ChatBotsCoreTests — the empty-result retry is decided after the blank-hit filter
//
// The advanced-depth retry fired only when the mapped array was empty, but the removal of
// blank and untitled hits ran after that test. A response of three blank items therefore mapped
// to a non-empty array, skipped the retry, and was then stripped to `[]` — so `WebSearchTool`
// reported "No results" for exactly the case the retry exists for. The recursive call also
// dropped `includeAnswer`, so a caller that asked for Tavily's own answer lost it on the retry.
//
// The ordering lives in one function now, so it is tested directly and end to end against a
// local server that scripts the basic and advanced responses differently. That end-to-end test
// is what pins the `includeAnswer` forwarding, which a pure test could not see.

import Foundation
import Testing

@testable import ChatBotsCore

/// The JSON body the client posts, so the test can assert what each attempt asked for.
private struct TavilyRequestBody: Decodable {
    let search_depth: String
    let include_answer: Bool
}

/// A loopback server that answers `/search` with a body chosen by `search_depth`, recording
/// every attempt.
@MainActor
private final class ScriptedTavilyServer {

    @MainActor
    private final class State {
        var seen: [TavilyRequestBody] = []
        var basicBody = Data(#"{"results":[]}"#.utf8)
        var advancedBody = Data(#"{"results":[]}"#.utf8)
    }

    private let state: State
    private let server: HTTPServer
    let port: UInt16

    var attempts: [TavilyRequestBody] { state.seen }

    init(basicBody: Data, advancedBody: Data) async throws {
        // The handler captures this instance, so it has to be the one the accessor reads: a
        // separate default-valued property would leave `attempts` always empty.
        let state = State()
        state.basicBody = basicBody
        state.advancedBody = advancedBody

        var started: HTTPServer?
        var chosenPort: UInt16 = 0
        for _ in 0..<8 {
            let candidate = allocateTestPort()
            let server = HTTPServer(
                port: candidate,
                handler: { request in
                    let parsed = try? JSONDecoder().decode(
                        TavilyRequestBody.self, from: request.body)
                    state.seen.append(
                        parsed ?? TavilyRequestBody(search_depth: "", include_answer: false))
                    let body =
                        parsed?.search_depth == "advanced" ? state.advancedBody : state.basicBody
                    return HTTPResponse(body: body)
                })
            try server.start()
            if await server.waitUntilReady() {
                started = server
                chosenPort = candidate
                break
            }
            server.stop()
        }
        guard let started else { throw ScriptedServerError.noPort }
        self.state = state
        self.server = started
        self.port = chosenPort
    }

    func stop() { server.stop() }

    func client() -> TavilyClient {
        TavilyClient(
            apiKey: "tvly-placeholder-not-a-real-key", baseURL: "http://127.0.0.1:\(port)")
    }
}

/// Three hits that carry neither content nor a title: what the blank filter removes.
private let blankResults = Data(
    #"""
    {"results":[
      {"title":null,"url":"https://a.example","content":"","score":0.1},
      {"title":null,"url":"https://b.example","content":"","score":0.2},
      {"title":null,"url":"https://c.example","content":"","score":0.3}
    ]}
    """#.utf8)

/// One hit with something to give the model.
private let realResult = Data(
    #"{"results":[{"title":"A real page","url":"https://real.example","content":"some text","score":0.9}]}"#
        .utf8)

/// A response with no items at all. Unlike `blankResults`, this retried even before the fix, so
/// it isolates the dropped `includeAnswer` from the ordering defect.
private let noResults = Data(#"{"results":[]}"#.utf8)

private func hit(title: String, content: String) -> TavilyClient.SearchHit {
    TavilyClient.SearchHit(title: title, url: "https://x.example", content: content, score: nil)
}

@MainActor
@Suite("The empty-result retry follows the blank filter")
struct ClientsSearchTests {

    // MARK: - The rule itself

    @Test("Blank hits are removed before the retry is decided")
    func blanksCountAsEmpty() {
        let blanks = [
            hit(title: "(untitled)", content: ""),
            hit(title: "(untitled)", content: ""),
            hit(title: "(untitled)", content: ""),
        ]
        #expect(TavilyClient.outcome(for: blanks, depth: .basic) == .retryAdvanced)
        // At advanced depth there is nowhere further to go: an empty result is the answer.
        #expect(TavilyClient.outcome(for: blanks, depth: .advanced) == .hits([]))
    }

    @Test("One usable hit among blanks is used, not retried")
    func oneUsableHitIsEnough() {
        let usable = hit(title: "Real", content: "text")
        let outcome = TavilyClient.outcome(
            for: [hit(title: "(untitled)", content: ""), usable], depth: .basic)
        #expect(outcome == .hits([usable]))
    }

    @Test("A hit is only blank when it has neither title nor content")
    func blankNeedsBoth() {
        let titled = hit(title: "A title", content: "")
        let withContent = hit(title: "(untitled)", content: "words")
        #expect(TavilyClient.outcome(for: [titled], depth: .basic) == .hits([titled]))
        #expect(TavilyClient.outcome(for: [withContent], depth: .basic) == .hits([withContent]))
    }

    @Test("An empty response retries at basic and stops at advanced")
    func emptyResponseRetriesOnce() {
        #expect(TavilyClient.outcome(for: [], depth: .basic) == .retryAdvanced)
        #expect(TavilyClient.outcome(for: [], depth: .advanced) == .hits([]))
    }

    // MARK: - End to end, against a scripted server

    /// The finding, exactly: pre-fix the blank response was stripped to `[]` and returned with
    /// no second attempt.
    @Test("Three blank items retry at advanced and return the real hits")
    func blankResponseRetries() async throws {
        let server = try await ScriptedTavilyServer(
            basicBody: blankResults, advancedBody: realResult)
        defer { server.stop() }

        let hits = try await server.client().search(query: "an oddly phrased query")

        #expect(hits.count == 1)
        #expect(hits.first?.title == "A real page")
        #expect(
            server.attempts.map(\.search_depth) == ["basic", "advanced"],
            "the blank response must be what triggers the advanced attempt")
    }

    @Test("A usable basic response is not retried")
    func usableResponseIsNotRetried() async throws {
        let server = try await ScriptedTavilyServer(
            basicBody: realResult, advancedBody: blankResults)
        defer { server.stop() }

        let hits = try await server.client().search(query: "an ordinary query")

        #expect(hits.count == 1)
        #expect(server.attempts.map(\.search_depth) == ["basic"])
    }

    /// The recursive call dropped `includeAnswer`, so the retry asked for less than the first
    /// attempt did. The second attempt has to ask for the same thing. The basic body has no
    /// items at all, so the retry happens even under the old ordering and this assertion is
    /// about the dropped parameter rather than about the ordering.
    @Test("The advanced retry keeps includeAnswer")
    func retryKeepsIncludeAnswer() async throws {
        let server = try await ScriptedTavilyServer(
            basicBody: noResults, advancedBody: realResult)
        defer { server.stop() }

        _ = try await server.client().search(query: "a query", includeAnswer: true)

        #expect(server.attempts.map(\.include_answer) == [true, true])
        #expect(server.attempts.map(\.search_depth) == ["basic", "advanced"])
    }

    /// A caller already at advanced depth gets one attempt and an empty result, not a loop.
    @Test("An advanced search does not retry again")
    func advancedDoesNotRetry() async throws {
        let server = try await ScriptedTavilyServer(
            basicBody: realResult, advancedBody: blankResults)
        defer { server.stop() }

        let hits = try await server.client().search(query: "a query", depth: .advanced)

        #expect(hits.isEmpty)
        #expect(server.attempts.map(\.search_depth) == ["advanced"])
    }
}

// MARK: - The tool the models are given

/// `web_search` is what research mode is built around, and only its properties were covered: the tool's
/// three branches — an empty query, no results at all, and the formatted list — were never executed.
/// They are tested here rather than in a file of their own because the scripted Tavily server above is
/// the thing they need, and it is private to this file.
@MainActor
@Suite("The web_search tool's own branches")
struct WebSearchToolTests {

    /// A Tavily response carrying `count` usable hits.
    private func body(count: Int) -> Data {
        let items = (1...max(count, 1)).prefix(count).map { index in
            """
            {"title":"Title \(index)","url":"https://\(index).example","content":"Snippet \(index)","score":0.5}
            """
        }
        return Data("{\"results\":[\(items.joined(separator: ","))]}".utf8)
    }

    @Test("An empty query is refused before any request is made")
    func emptyQueryIsRefused() async {
        // A port nothing listens on, so a request would fail differently: what this asserts is that no
        // request is attempted at all.
        let tool = WebSearchTool(
            client: TavilyClient(apiKey: "unused", baseURL: "http://127.0.0.1:9"), maxResults: 3)
        do {
            _ = try await tool.run(argument: " \n\t ")
            Issue.record("an empty query must not be searched for")
        } catch let error as ChatBotsError {
            guard case .toolFailed(let reason) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(reason.contains("empty search query"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("Hits become a numbered list with their URLs, and a summary that says how many")
    func hitsAreFormatted() async throws {
        let server = try await ScriptedTavilyServer(
            basicBody: body(count: 2), advancedBody: body(count: 2))
        defer { server.stop() }

        let outcome = try await WebSearchTool(client: server.client(), maxResults: 3)
            .run(argument: "why are eggs ovoid")

        #expect(outcome.text.contains("Search results for \"why are eggs ovoid\":"))
        #expect(outcome.text.contains("1. Title 1"))
        #expect(outcome.text.contains("URL: https://1.example"))
        #expect(outcome.text.contains("Snippet 1"))
        #expect(outcome.text.contains("2. Title 2"), "every hit is listed, not just the first")
        #expect(outcome.text.contains("Cite the URLs"), "and the model is told what to do with them")
        #expect(outcome.summary == "2 result(s) for \"why are eggs ovoid\" — Title 1")
    }

    @Test("A search that finds nothing says so instead of returning an empty list")
    func noResultsIsItsOwnAnswer() async throws {
        // Both depths answer empty, which is what the client's basic-then-advanced retry needs to end
        // with no hits at all — the only way this branch is reached.
        let empty = Data(#"{"results":[]}"#.utf8)
        let server = try await ScriptedTavilyServer(basicBody: empty, advancedBody: empty)
        defer { server.stop() }

        let outcome = try await WebSearchTool(client: server.client())
            .run(argument: "a query with no answers")

        #expect(outcome.text == "No results for \"a query with no answers\".")
        #expect(outcome.summary == "no results for \"a query with no answers\"")
    }
}
