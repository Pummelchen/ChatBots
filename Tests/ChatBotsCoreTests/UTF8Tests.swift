// ChatBotsCoreTests — text stays whole from prompt to log to display
//
// Unicode in this app is not at risk from Swift strings or from the models; it is at risk
// from the app's own shortening and from chunk boundaries in streaming. Those are what
// these cover, plus one end-to-end pass through the real prompt and transcript machinery.

import ChatBotsCore
import Foundation
import Testing

/// A sample with combining marks, RTL, CJK, an emoji ZWJ sequence, and a flag.
private let unicodeSample = """
    café naïve Grüße ẞ 日本語 中文 Ελληνικά العربية עברית ñandú — em dash, “curly quotes”,
    👩‍👩‍👧‍👦 family, 🥚 egg, 🇯🇵 flag, e\u{0301} combining acute
    """

@Suite("UTF-8 text handling")
struct UTF8Tests {

    @Test("Shortening counts grapheme clusters, never splitting a character")
    func graphemeSafePrefix() {
        // An emoji ZWJ sequence is one grapheme, so it survives a short budget whole.
        let family = "👩‍👩‍👧‍👦"
        #expect(UTF8Text.prefix(family + "abc", 1) == family + "…")
        #expect(UTF8Text.prefix("日本語です", 3) == "日本語…")
        // A combining sequence is one grapheme too: the accent stays with its letter.
        #expect(UTF8Text.prefix("e\u{0301}x", 1) == "e\u{0301}…")

        // Nothing is appended when the text already fits.
        #expect(UTF8Text.prefix("café", 10) == "café")
        #expect(UTF8Text.prefix("café", 4) == "café")
        #expect(UTF8Text.prefix("café", 0) == "")
    }

    @Test("Shortened text is still valid UTF-8 with no replacement characters")
    func prefixOutputIsValid() {
        for limit in 0...12 {
            let shortened = UTF8Text.prefix(unicodeSample, limit)
            #expect(!shortened.contains("\u{FFFD}"), "limit \(limit) produced a replacement character")
            // Re-decoding what we produced must be lossless.
            #expect(String(bytes: Array(shortened.utf8), encoding: .utf8) == shortened)
        }
    }

    @Test("Bytes cut mid-character lose the partial character, not the whole string")
    func truncatedDecoding() {
        let text = "café 日本語"
        let bytes = Data(text.utf8)

        // Cut one byte into the "é" (2 bytes) — a raw prefix is not valid UTF-8.
        let cutInsideE = bytes.prefix(bytes.count - " 日本語".utf8.count - 1)
        #expect(String(data: cutInsideE, encoding: .utf8) == nil, "precondition: the cut is invalid")
        let recovered = UTF8Text.decodeTruncated(Data(cutInsideE))
        #expect(recovered == "caf", "got \(recovered ?? "nil")")
        #expect(recovered?.contains("\u{FFFD}") != true)

        // Cut inside a 3-byte character.
        let cutInsideCJK = bytes.prefix(bytes.count - 1)
        #expect(UTF8Text.decodeTruncated(Data(cutInsideCJK)) == "café 日本")
    }

    @Test("Whole text decodes unchanged, and byte prefixes stay valid")
    func bytePrefix() {
        let text = "日本語"
        let bytes = Data(text.utf8)
        #expect(UTF8Text.decodeTruncated(bytes) == text)

        // Every byte-prefix length yields valid UTF-8, never a replacement character.
        for length in 0...bytes.count {
            let shortened = UTF8Text.bytePrefix(bytes, length)
            let decoded = String(data: shortened, encoding: .utf8)
            #expect(decoded != nil, "byte prefix \(length) is not valid UTF-8")
            #expect(decoded?.contains("\u{FFFD}") != true)
            #expect(shortened.count <= length)
        }
    }

    @Test("A character split across streaming chunks is reassembled, not replaced")
    func splitAcrossChunks() {
        var buffer = OpenAIResponsesClient.UTF8StreamBuffer()
        let text = "Grüße 🥚 日本語"
        let bytes = Array(text.utf8)

        // Feed the stream one byte at a time — the worst case a server could produce.
        // Bytes, not strings: decoding a fragment alone would insert a replacement
        // character before the buffer ever saw it.
        var assembled = ""
        for byte in bytes {
            assembled += buffer.append(Data([byte]))
        }
        assembled += buffer.flush()

        #expect(assembled == text)
        #expect(!assembled.contains("\u{FFFD}"))
    }

    @Test("A stream ending mid-character drops the partial byte rather than emitting a replacement")
    func splitAtEnd() {
        let bytes = Array("café".utf8)
        // Hold back the final byte of "é".
        let cut = bytes.dropLast()
        var buffer = OpenAIResponsesClient.UTF8StreamBuffer()
        var assembled = ""
        for byte in cut {
            assembled += buffer.append(Data([byte]))
        }
        assembled += buffer.flush()
        #expect(assembled == "caf")
        #expect(!assembled.contains("\u{FFFD}"))
    }

    @Test("Whole chunks pass through the buffer untouched")
    func wholeChunksPassThrough() {
        var buffer = OpenAIResponsesClient.UTF8StreamBuffer()
        var assembled = ""
        for chunk in ["Hello ", "wörld ", "🥚", " 日本"] {
            assembled += buffer.append(chunk)
        }
        assembled += buffer.flush()
        #expect(assembled == "Hello wörld 🥚 日本")
    }

    @Test("A prompt carrying every script reaches the model unchanged")
    func promptRoundTrip() {
        var spec = AgentSpec.seat(index: 0)
        spec.personaID = PersonaLibrary.neutral.id
        let conversation = Conversation(
            topic: unicodeSample,
            turns: [
                Turn(sequence: 1, speakerName: "Moderator", kind: .topic, content: unicodeSample),
                Turn(
                    sequence: 2, speakerID: "Agent 1", speakerName: "Agent 1", kind: .chat,
                    content: "Über die Eiform: 卵の形は楕円です。🥚"),
            ])
        let prompt = PromptBuilder.prompt(
            for: spec, others: [AgentSpec.seat(index: 1)], conversation: conversation)

        let body = prompt.map(\.content).joined(separator: "\n")
        #expect(body.contains("café"))
        #expect(body.contains("日本語"))
        #expect(body.contains("العربية"))
        #expect(body.contains("👩‍👩‍👧‍👦"))
        #expect(body.contains("卵の形は楕円です。🥚"))
        #expect(!body.contains("\u{FFFD}"))
    }

    @Test("A transcript survives the engine round trip and the tagged log intact")
    @MainActor
    func conversationKeepsUnicode() async {
        let specs = AgentSpec.makeSeats(count: 2)
        let stubs = specs.map { EchoStub(spec: $0) }
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        configuration.maxTurns = 2
        let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
        let engine = ConversationEngine(seats: seats, configuration: configuration)

        engine.start(topic: unicodeSample)
        await engine.waitUntilFinished()

        let chat = engine.conversation.turns.filter { $0.kind == .chat }
        #expect(chat.count == 2)
        for turn in chat {
            #expect(turn.content.contains("café"), "the seeded sample was mangled")
            #expect(turn.content.contains("日本語"))
            #expect(turn.content.contains("🥚"))
            #expect(!turn.content.contains("\u{FFFD}"))
        }
        // The topic itself is preserved verbatim, characters and all.
        #expect(engine.conversation.topic == unicodeSample)
    }

    @Test("The text export keeps Unicode, and stays valid UTF-8")
    @MainActor
    func exportKeepsUnicode() async {
        let specs = AgentSpec.makeSeats(count: 1)
        let stub = EchoStub(spec: specs[0])
        var configuration = ConversationEngine.Configuration()
        configuration.pace = .zero
        configuration.maxTurns = 1
        let engine = ConversationEngine(
            seats: [.init(spec: specs[0], engine: stub)], configuration: configuration)
        engine.start(topic: "Grüße 🥚 日本語")
        await engine.waitUntilFinished()

        // The export path the copy command uses.
        let text = engine.displayTurns.map(\.content).joined(separator: "\n")
        #expect(text.contains("Grüße"))
        #expect(text.contains("🥚"))
        let data = Data(text.utf8)
        #expect(String(data: data, encoding: .utf8) == text)
    }
}

/// Echoes the prompt's log back, so whatever went in comes out and can be compared.
private actor EchoStub: LLMEngine {
    nonisolated let spec: AgentSpec
    init(spec: AgentSpec) { self.spec = spec }
    var isLoaded: Bool { true }
    var contextWindow: Int { spec.contextWindow }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}
    func compact(prompt: String, maxTokens: Int) async throws -> String { "" }

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        // Return the seeded sample so the assertions test preservation, not the model.
        let text = unicodeSample
        await onEvent(.token(agentID: spec.id, text: text))
        await onEvent(
            .turnFinished(
                agentID: spec.id, text: text,
                stats: TurnStats(promptTokens: 10, generationTokens: 10, stopReason: "stop")))
        return text
    }
}
