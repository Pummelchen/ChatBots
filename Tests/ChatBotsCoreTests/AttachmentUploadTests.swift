// ChatBotsCoreTests — where an upload is allowed to land
//
// `POST /api/attachments` takes a filename from the request body and the engine writes the
// decoded bytes to a temporary file before reading them back. The filename is data the caller
// chose, not a path, and this file asserts that it can never become one: a traversal and an
// absolute name are contained, and a name that cannot be used at all is refused.
//
// The canary is the assertion that matters. A staging directory is made under the temporary
// directory and removed afterwards, so a file written *outside* it survives the cleanup — the
// tests therefore assert the negative directly, that the escaped location does not exist,
// rather than only that the reply looked reasonable.

import ChatBotsCore
import Foundation
import Testing

/// An engine that does nothing, so these tests are about the upload path.
private actor QuietStub: LLMEngine {
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
        "a reply"
    }
}

/// A service with its own engine and store, and the real extractors installed.
///
/// The ingestor is the one the app installs at launch. Without it the service refuses every
/// upload — "this server was started without document support" — and these tests would pass
/// without ever reaching the write they are about.
@MainActor
private func makeService() -> (EngineService, ConversationEngine) {
    let specs = (0..<2).map { index -> AgentSpec in
        var spec = AgentSpec.seat(index: index)
        spec.displayName = "Seat \(index + 1)"
        return spec
    }
    let stubs = specs.map { QuietStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    engine.setTopic("An upload test")
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "upload-\(UUID().uuidString)"))
    DocumentIngestorProvider.install(SystemDocumentExtractor.ingestor)
    return (EngineService(engine: engine, store: store), engine)
}

/// A fresh path under the temporary directory, and its basename.
@MainActor
private func temporaryCanary(_ label: String) -> (url: URL, name: String) {
    let name = "chatbots-\(label)-\(UUID().uuidString).txt"
    return (FileManager.default.temporaryDirectory.appending(path: name), name)
}

@MainActor
private func attachments(in reply: EngineReply) -> [APIAttachment]? {
    if case .state(let snapshot) = reply { return snapshot.attachments }
    return nil
}

private enum UploadTestError: Error {
    case noPort
}

/// A running API server, so one test can post through the route the browser uses.
@MainActor
private func liveServer() async throws -> (APIServer, URLSession, String) {
    // The side effect is the point: `makeService` installs the real extractor set the server's
    // dispatch will need. The server makes its own `EngineService` around the same engine.
    let (_, engine) = makeService()
    let session = URLSession(configuration: .ephemeral)
    for _ in 0..<8 {
        let port = allocateTestPort()
        let server = APIServer(
            engine: engine,
            store: ConversationStore(
                directory: FileManager.default.temporaryDirectory
                    .appending(path: "upload-http-\(UUID().uuidString)")),
            port: port)
        try server.start()
        if await server.waitUntilReady() {
            return (server, session, "http://127.0.0.1:\(port)")
        }
        server.stop()
    }
    throw UploadTestError.noPort
}

@MainActor
@Suite("Where an upload may be written", .serialized)
struct AttachmentUploadPathTests {

    @Test("A relative traversal filename cannot write outside the staging directory")
    func traversalIsContained() async {
        let (service, _) = makeService()
        // `../<name>` from the per-upload directory lands exactly on this path, which is why it
        // is the canary: before the fix the bytes were written here and survived the cleanup.
        let canary = temporaryCanary("traversal")
        #expect(!FileManager.default.fileExists(atPath: canary.url.path))

        let reply = await service.handle(
            .addAttachment(
                filename: "../\(canary.name)",
                contents: Data("canary bytes".utf8)))

        #expect(
            !FileManager.default.fileExists(atPath: canary.url.path),
            "the upload escaped the staging directory and wrote \(canary.name)")
        // Contained rather than silently renamed to something else: the file the extractor read
        // is named with the final component the caller sent.
        #expect(attachments(in: reply)?.map(\.name) == [canary.name])
    }

    @Test("The traversal from the audit is contained too")
    func auditTraversalIsContained() async {
        let (service, _) = makeService()
        let reply = await service.handle(
            .addAttachment(
                filename: "../../../../tmp/chatbots-traversal-probe.txt",
                contents: Data("canary bytes".utf8)))

        // Refused or contained, but never used as a path: no attachment may carry a separator,
        // because the display name comes from the URL the file was written to.
        if let names = attachments(in: reply)?.map(\.name) {
            #expect(names == ["chatbots-traversal-probe.txt"])
            #expect(names.allSatisfy { !$0.contains("/") && !$0.contains("\\") })
        }
    }

    @Test("An absolute filename is contained")
    func absolutePathIsContained() async {
        let (service, _) = makeService()
        let canary = temporaryCanary("absolute")
        let absolute = "/tmp/\(canary.name)"
        #expect(!FileManager.default.fileExists(atPath: absolute))

        let reply = await service.handle(
            .addAttachment(filename: absolute, contents: Data("canary bytes".utf8)))

        #expect(
            !FileManager.default.fileExists(atPath: absolute),
            "an absolute filename was used as a path")
        #expect(attachments(in: reply)?.map(\.name) == [canary.name])
    }

    @Test("A name that is still not usable after reduction is refused, not renamed")
    func unusableNamesAreRefused() async {
        let (service, _) = makeService()
        for name in ["..", "", "/", "..\\..\\escape.txt"] {
            let reply = await service.handle(
                .addAttachment(filename: name, contents: Data("canary bytes".utf8)))
            guard case .refused(let reason) = reply else {
                Issue.record("\(name.isEmpty ? "an empty name" : name) should be refused")
                return
            }
            #expect(reason.contains("not a usable name"))
        }
    }

    @Test("A normal filename still works and still produces an attachment")
    func normalNameStillWorks() async {
        let (service, engine) = makeService()
        let reply = await service.handle(
            .addAttachment(
                filename: "notes.txt",
                contents: Data("Eggs are ovoid because of the shell.".utf8)))

        let attached = attachments(in: reply)
        #expect(attached?.count == 1)
        #expect(attached?.first?.name == "notes.txt")
        #expect(attached?.first?.kind == DocumentKind.plainText.rawValue)
        #expect(engine.attachments.count == 1)
    }

    @Test("Posting the traversal to the route the API serves is contained there too")
    func httpRouteIsContained() async throws {
        let (server, session, base) = try await liveServer()
        defer { server.stop() }

        let canary = temporaryCanary("http-traversal")
        #expect(!FileManager.default.fileExists(atPath: canary.url.path))

        var request = URLRequest(url: URL(string: "\(base)/api/attachments")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "filename": "../\(canary.name)",
            "content": Data("canary bytes".utf8).base64EncodedString(),
        ])
        let (data, response) = try await session.data(for: request)

        // 200 when the reduced name was usable, 409 when it was refused: either is contained,
        // and the canary is the assertion that decides.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #expect(status == 200 || status == 409, "unexpected status \(status)")
        #expect(
            !FileManager.default.fileExists(atPath: canary.url.path),
            "the route wrote \(canary.name) outside the staging directory")
        if status == 200 {
            let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let names = (snapshot?["attachments"] as? [[String: Any]])?.compactMap {
                $0["name"] as? String
            }
            #expect(names == [canary.name])
        }
    }
}
