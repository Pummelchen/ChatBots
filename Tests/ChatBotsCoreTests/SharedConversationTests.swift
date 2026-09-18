// ChatBotsCoreTests — a conversation somebody can open
//
// The page renders text a language model wrote, which is to say arbitrary text, some of it
// produced by a model that has read the web. The security test here is therefore the important
// one: a message containing a script tag must not be able to escape. The rest check that the
// page is actually usable — that the replay is there and that every turn arrived.

import ChatBotsCore
import Foundation
import Testing

private func record(
    topic: String = "Why are eggs not round?",
    turns: [Turn],
    report: ResearchReport? = nil
) -> StoredConversation {
    var conversation = Conversation(topic: topic, turns: turns)
    conversation.report = report
    var seat = AgentSpec.makeSeats(count: 1)[0]
    seat.displayName = "Ada"
    return StoredConversation(
        id: UUID(), conversation: conversation, seats: [seat], startedAt: .now)
}

private func chat(_ sequence: Int, _ speaker: String, _ text: String) -> Turn {
    Turn(sequence: sequence, speakerID: speaker, speakerName: speaker, kind: .chat, content: text)
}

@Suite("A shared conversation page")
struct SharedConversationPageTests {

    @Test("The page carries the question, the participants and every entry")
    func pageCarriesTheConversation() {
        let page = SharedConversationPage.html(
            record(turns: [
                chat(1, "Ada", "The premise is doing a lot of work here."),
                chat(2, "Otto", "Eggs are not round because they are not spheres."),
            ]))

        #expect(page.contains("Why are eggs not round?"))
        #expect(page.contains("Ada"))
        #expect(page.contains("Otto"))
        #expect(page.contains("The premise is doing a lot of work here."))
        #expect(page.contains("Eggs are not round because they are not spheres."))
        #expect(page.contains("<!doctype html>"))
        // Self-contained: a shared link has to work with no server-side assets behind it.
        #expect(!page.contains("src=\"/app.js\""))
        #expect(!page.contains("<link rel=\"stylesheet\""))
    }

    @Test("A message cannot escape the page")
    func markupCannotEscape() {
        // The whole reason this builder exists rather than reusing the live interface: the text
        // is model output, and a model that has read the web will eventually write a script tag.
        let hostile = "</script><script>alert('xss')</script><img src=x onerror=alert(1)>"
        let page = SharedConversationPage.html(
            record(topic: "A topic with <b>markup</b>", turns: [chat(1, "Ada", hostile)]))

        // The island must not be closable from inside its own data: no raw `</script`
        // anywhere in it, which is the only thing that would end the block early.
        let raw = rawIsland(in: page)
        #expect(!raw.isEmpty)
        #expect(!raw.contains("</script"))
        #expect(!raw.contains("<script"))
        // `<` is escaped, so no tag in the message can become a tag in the document.
        #expect(raw.contains("\\u003c"))
        #expect(!raw.contains("<img"))

        // Attribute text without a `<` is inert inside a JSON block, so its presence is not a
        // problem and asserting its absence would be asserting the wrong thing. What must not
        // happen is it becoming an element, and the two checks above are that.
        #expect(raw.contains("onerror=alert(1)>"))

        // And the same for the topic, which is typed by a person rather than written by a model.
        #expect(page.contains("&lt;b&gt;markup&lt;/b&gt;"))
        #expect(!page.contains("<b>markup</b>"))
    }

    @Test("The page never inserts content as markup")
    func noInnerHTML() {
        // A behavioural guarantee rather than a stylistic one: the script writes every node with
        // textContent, so even a message the escaper somehow missed could not become markup.
        let page = SharedConversationPage.html(record(turns: [chat(1, "Ada", "hello")]))
        #expect(!page.contains("innerHTML"))
        #expect(!page.contains("insertAdjacentHTML"))
        #expect(!page.contains("document.write"))
        #expect(page.contains("textContent = entry.text"))
    }

    @Test("The replay controls are there and wired to something")
    func replayIsPresent() {
        let page = SharedConversationPage.html(record(turns: [chat(1, "Ada", "hello")]))
        for id in ["first", "prev", "play", "next", "last", "speed", "counter"] {
            #expect(page.contains("id=\"\(id)\""))
        }
        // A control with no handler is worse than no control: it looks broken rather than absent.
        #expect(page.contains("playButton.onclick = play"))
        #expect(page.contains("document.addEventListener(\"keydown\""))
        // Keyboard support is how anyone gets through a long transcript.
        #expect(page.contains("ArrowRight"))
    }

    @Test("A short conversation opens fully, and a long one starts at the beginning")
    func shortConversationsAreNotHidden() {
        // A link to a two-turn exchange that opens showing one turn is a page that looks empty.
        let short = SharedConversationPage.html(record(turns: [chat(1, "Ada", "hello")]))
        #expect(short.contains("nodes.length <= 2"))

        // And a reader who does not want the replay can ask for all of it.
        #expect(short.contains("#all"))
    }

    @Test("A report travels with the page rather than being left behind")
    func reportIsIncluded() {
        let report = ResearchReporting.parse(
            "## Key Findings\n\n- FACT: registrations rose — Economist\n",
            question: "A question", participants: ["Economist"],
            stopReason: "the budget was reached", budgetSummary: "quick", rounds: 2, searches: 0)
        let page = SharedConversationPage.html(record(turns: [chat(1, "Ada", "hello")], report: report))
        #expect(page.contains("Research report"))
        #expect(page.contains("registrations rose"))
    }

    @Test("A page with no topic still has a title")
    func untitledPagesReadProperly() {
        let page = SharedConversationPage.html(record(topic: "", turns: [chat(1, "Ada", "hello")]))
        #expect(page.contains("An untitled conversation"))
    }

    @Test("The JSON island is valid JSON once the escaping is undone")
    func dataIsDecodable() throws {
        // Taken out of the real page rather than from the builder directly, so this checks the
        // artefact: the escaping exists to keep the block from being closed early, and if it
        // corrupted the data the page would render nothing.
        let text = "An arrow → and a <tag> and a backslash \\ here"
        let page = SharedConversationPage.html(record(turns: [chat(1, "Ada", text)]))
        let json = island(in: page)
        #expect(!json.isEmpty, "the page must carry a data island")
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let entries = object?["entries"] as? [[String: Any]]
        #expect(entries?.count == 1)
        #expect(entries?.first?["text"] as? String == text)
        // The island carries the transcript and the topic, and nothing about where the page was
        // reached: the `shareBase` key that used to be here had no reader, and its absence is
        // asserted where the page is fetched over a socket (`ShareLinkTests`).
        #expect(object?["shareBase"] == nil)
    }

    /// The data island exactly as it appears in the page, escapes and all.
    ///
    /// This is what the escaping test has to look at: unescaping it first and then checking for
    /// `<script` would fail on a page that is perfectly safe.
    private func rawIsland(in page: String) -> String {
        let marker = "type=\"application/json\">"
        guard let start = page.range(of: marker),
            let end = page.range(of: "</script>", range: start.upperBound..<page.endIndex)
        else { return "" }
        return String(page[start.upperBound..<end.lowerBound])
    }

    /// The island as a JSON parser would see it.
    ///
    /// JSONSerialization escapes the escape: `<` becomes `\u003c` from the builder and the slash
    /// in `</script>` becomes `\/` from JSON, so both are undone here.
    private func island(in page: String) -> String {
        rawIsland(in: page)
            .replacingOccurrences(of: "\\u003c", with: "<")
            .replacingOccurrences(of: "\\/", with: "/")
    }
}

// MARK: - Over the wire

@MainActor
private func shareServer() async throws -> (APIServer, ConversationEngine, URLSession, String) {
    let specs = AgentSpec.makeSeats(count: 2)
    let stubs = specs.map { ShareStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    configuration.maxTurns = 2
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    engine.setTopic("A shared question")
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "share-\(UUID().uuidString)"))
    let session = URLSession(configuration: .ephemeral)
    // Ports come from the shared allocator, so three tests in this suite running in parallel do
    // not all reach for the same one and then log a retry each.
    for _ in 0..<8 {
        let port = allocateTestPort()
        let server = APIServer(engine: engine, store: store, port: port)
        try server.start()
        if await server.waitUntilReady() {
            return (server, engine, session, "http://127.0.0.1:\(port)")
        }
        server.stop()
    }
    throw ShareTestError.noPort
}

private enum ShareTestError: Error { case noPort }

private actor ShareStub: LLMEngine {
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
    ) async throws -> String {
        let text = "According to the filings, a consideration."
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 10, stopReason: "stop")))
        return text
    }
}

@Suite("Sharing over HTTP")
@MainActor
struct SharedConversationHTTPTests {

    @Test("A kept conversation can be opened from its link")
    func linkServesThePage() async throws {
        let (server, engine, session, base) = try await shareServer()
        defer { server.stop() }
        engine.start()
        await engine.waitUntilFinished()

        let listData = try await fetch(session, "\(base)/api/conversations")
        let list = try JSONSerialization.jsonObject(with: listData) as? [[String: Any]]
        let id = try #require(list?.first?["id"] as? String)

        let shareURL = try #require(URL(string: "\(base)/s/\(id)"))
        let (data, response) = try await session.data(from: shareURL)
        let status = (response as? HTTPURLResponse)?.statusCode
        #expect(status == 200)
        #expect(
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?
                .contains("text/html") == true)
        let page = String(bytes: data, encoding: .utf8) ?? ""
        #expect(page.contains("A shared question"))
        #expect(page.contains("id=\"play\""))
    }

    @Test("A link that names nothing says so, rather than opening an empty conversation")
    func unknownLinkIsHonest() async throws {
        let (server, _, session, base) = try await shareServer()
        defer { server.stop() }

        let unknownURL = try #require(URL(string: "\(base)/s/\(UUID().uuidString)"))
        let (data, response) = try await session.data(from: unknownURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        let page = String(bytes: data, encoding: .utf8) ?? ""
        #expect(page.contains("No conversation with that link"))

        // And a malformed one is the same answer rather than a crash.
        let malformedURL = try #require(URL(string: "\(base)/s/not-an-id"))
        let (_, malformed) = try await session.data(from: malformedURL)
        #expect((malformed as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("A client is told where to build a share link")
    func shareBaseIsInTheSnapshot() async throws {
        let (server, _, session, base) = try await shareServer()
        defer { server.stop() }
        let data = try await fetch(session, "\(base)/api/state")
        let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(snapshot?["shareBase"] as? String == base)
    }

    @Test("A page carries no origin, whatever Host it was reached on")
    func sharePageCarriesNoOrigin() async throws {
        let (server, engine, session, base) = try await shareServer()
        defer { server.stop() }
        engine.start()
        await engine.waitUntilFinished()

        let listData = try await fetch(session, "\(base)/api/conversations")
        let list = try JSONSerialization.jsonObject(with: listData) as? [[String: Any]]
        let id = try #require(list?.first?["id"] as? String)

        // The page used to be handed an origin built from the request's `Host` and wrote it into
        // its JSON island, where nothing ever read it. It is rendered from the record alone now,
        // so neither a proxy's host nor the engine's own base appears in it — and the page still
        // arrives with the conversation in it, which is the part that matters. The island carries
        // JSONSerialization's escapes (`\/` for a slash, `\u003c` for `<`), so the page is unescaped
        // the way the replay script does before a value is compared.
        func decoded(_ page: String) -> String {
            page
                .replacingOccurrences(of: "\\u003c", with: "<")
                .replacingOccurrences(of: "\\/", with: "/")
        }

        let shareURL = try #require(URL(string: "\(base)/s/\(id)"))
        var proxied = URLRequest(url: shareURL)
        proxied.setValue("192.168.1.5:7788", forHTTPHeaderField: "Host")
        let (data, response) = try await session.data(for: proxied)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let page = decoded(try #require(String(bytes: data, encoding: .utf8)))
        #expect(page.contains("\"entries\""), "the page did not carry the conversation")
        #expect(!page.contains("192.168.1.5:7788"), "the proxy's host reached the page")
        #expect(!page.contains(base), "the engine's own base reached the page")

        // A Host that is not a host is not special-cased either, because nothing reads the header.
        var hostile = URLRequest(url: shareURL)
        hostile.setValue("evil.example/../admin", forHTTPHeaderField: "Host")
        let (hostileData, _) = try await session.data(for: hostile)
        let hostilePage = decoded(try #require(String(bytes: hostileData, encoding: .utf8)))
        #expect(hostilePage.contains("\"entries\""))
        #expect(!hostilePage.contains("evil.example"), "a Host that is not a host reached the page")
        #expect(!hostilePage.contains("shareBase"), "the island still carries a base nothing reads")
    }
}

/// Fetch a body, so the tests read as assertions rather than as URL plumbing.
private func fetch(_ session: URLSession, _ url: String) async throws -> Data {
    let requestURL = try #require(URL(string: url))
    let result = try await session.data(from: requestURL)
    return result.0
}
