// ChatBotsCoreTests — a share page carries no origin from the request, though a fix once added one
//
// The share page used to be given the origin it was reached on: the request's `Host` was checked by
// `validShareHost` and handed to `SharedConversationPage.html` as `shareBase`, which wrote it into the
// page's JSON island. Nothing ever read it. Every URL the page needs is relative — it renders no links
// at all — so the parameter, the island key and the validator existed to feed a key with no consumer,
// and reflecting a client-supplied header is a surface worth not having for nothing. The whole chain is
// gone, and what that feature actually needs still works: the link a reader copies is built by
// the front ends, the web interface from the origin the browser is reading at with the engine's
// reported base as its fallback (`web/app.js`), and the desktop app from that reported base
// (`ChatController.shareLink(for:)`), which `--share-base` sets.
//
// This is the behavioural statement of that: with a hostile `Host` and with an ordinary one, nothing
// from the header reaches the page; the page arrives with the conversation in it; and the page itself
// renders no absolute URL and carries no base. The request is written by hand because a `Host` header
// is not something `URLSession` will let a test choose (`RawConnection`).

import Foundation
import Testing

@testable import ChatBotsCore

@MainActor
@Suite("A share page carries no origin from the request")
struct ShareLinkTests {

    /// A saved conversation, so `/s/<id>` has something to render.
    private func savedRecord(in fixture: APIServerFixture, topic: String) -> UUID {
        let id = UUID()
        // The turn is built first and the array written on one line: a multi-line array literal with one
        // element is a trailing comma that SwiftLint wants and swift-format does not, and neither tool's
        // answer can be satisfied while both are right about their own rule.
        let turn = Turn(
            sequence: 1, speakerName: "Agent 1", kind: .chat,
            content: "The shared conversation body.")
        let conversation = Conversation(topic: topic, turns: [turn])
        let record = StoredConversation(
            id: id, conversation: conversation, seats: AgentSpec.makeSeats(count: 2),
            startedAt: .now)
        #expect(fixture.server.engineService.store.save(record))
        return id
    }

    /// One raw request, read to the end, so "does not appear" is a statement about the whole response
    /// rather than about the first packet.
    private func fetch(_ path: String, host: String, port: UInt16) async throws -> String {
        let client = try RawConnection(port: port)
        defer { client.cancel() }
        #expect(await client.connect())
        client.send("GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n")
        var reply = Data()
        while let chunk = await client.receiveOnce(timeout: .seconds(1)) {
            reply.append(chunk)
        }
        return String(bytes: reply, encoding: .utf8) ?? ""
    }

    @Test("A client-supplied Host never reaches the page")
    func theHostIsNotReflected() async throws {
        let fixture = try await makeAPIServerFixture()
        defer { fixture.server.stop() }
        let id = savedRecord(in: fixture, topic: "Reached from somewhere odd")

        let hostile = try await fetch("/s/\(id.uuidString)", host: "evil.example", port: fixture.port)
        // The page arrived with the conversation in it: the counterweight that makes the absences
        // below mean something rather than describing a 404 that contains nothing.
        #expect(hostile.contains("The shared conversation body."))
        #expect(!hostile.contains("evil.example"), "the Host header was reflected into the page")
        #expect(!hostile.contains("shareBase"), "the island still carries a base nothing reads")

        // An ordinary host is not reflected either: the point is that the page needs no origin, not
        // that one value is refused.
        let ordinary = try await fetch(
            "/s/\(id.uuidString)", host: "chatbots.local:7788", port: fixture.port)
        #expect(ordinary.contains("The shared conversation body."))
        #expect(!ordinary.contains("chatbots.local:7788"))
    }

    @Test("The page needs no base: no island field, no absolute URL")
    func thePageNeedsNoBase() {
        let turn = Turn(sequence: 1, speakerName: "Agent 1", kind: .chat, content: "Body.")
        let record = StoredConversation(
            id: UUID(),
            conversation: Conversation(topic: "A page with no links", turns: [turn]),
            seats: AgentSpec.makeSeats(count: 2), startedAt: .now)
        let html = SharedConversationPage.html(record)
        #expect(html.contains("A page with no links"))
        #expect(html.contains("Body."))
        #expect(!html.contains("shareBase"))
        #expect(!html.contains("http://"), "something in the page would be an absolute URL")
        #expect(!html.contains("https://"))
    }
}
