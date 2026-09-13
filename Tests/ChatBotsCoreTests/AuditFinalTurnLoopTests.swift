// ChatBotsCoreTests — A02: one generation turn, driven by a stub instead of weights
//
// `MLXEngine.swift` was at 2.2 % line coverage because the whole turn — prompt assembly, the
// tool rounds, the thinking ceiling, the refusal paths and the notices a finished turn owes the
// reader — lived inside a function whose first statement loaded a model. None of that logic
// needs a GPU; only the call that produces the model's stream does.
//
// `MLXEngine.runTurn` takes that stream as an injected `makeStream`, so these tests drive the
// real turn loop with a scripted `Generation` list. They assert what the loop *sent* (each
// round's `RoundPrompt`), what it *emitted* and what it *returned* — the same code the loaded
// engine runs, not a re-implementation of it.

@testable import ChatBotsCore
import Foundation
import MLXLMCommon
import Synchronization
import Testing

// MARK: - Stubs

/// The rounds a stub model will produce, one scripted list per `makeStream` call, plus every
/// round prompt the loop actually sent.
private actor ScriptedRounds {
    private var rounds: [[Generation]]
    private var prompts: [MLXEngine.RoundPrompt] = []

    init(_ rounds: [[Generation]]) { self.rounds = rounds }

    func stream(for prompt: MLXEngine.RoundPrompt) -> AsyncThrowingStream<Generation, Error> {
        prompts.append(prompt)
        let script = rounds.isEmpty ? [] : rounds.removeFirst()
        return AsyncThrowingStream<Generation, Error> { continuation in
            for generation in script { continuation.yield(generation) }
            continuation.finish()
        }
    }

    func recorded() -> [MLXEngine.RoundPrompt] { prompts }
}

/// Everything the turn emitted, in order.
private final class EventRecorder: Sendable {
    private let storage = Mutex<[TurnEvent]>([])

    func record(_ event: TurnEvent) { storage.withLock { $0.append(event) } }
    var events: [TurnEvent] { storage.withLock { $0 } }

    var tokens: [String] {
        events.compactMap { if case .token(_, let text) = $0 { return text } else { return nil } }
    }
    var reasoning: [String] {
        events.compactMap {
            if case .reasoning(_, let text) = $0 { return text } else { return nil }
        }
    }
    var failures: [(name: String, message: String)] {
        events.compactMap {
            if case .toolFailure(_, let name, let message) = $0 { return (name, message) }
            return nil
        }
    }
    var finished: [(text: String, stats: TurnStats)] {
        events.compactMap {
            if case .turnFinished(_, let text, let stats) = $0 { return (text, stats) }
            return nil
        }
    }
    var toolResults: [(name: String, summary: String, detail: String)] {
        events.compactMap {
            if case .toolResult(_, let name, let summary, let detail) = $0 {
                return (name, summary, detail)
            }
            return nil
        }
    }
}

/// The tool calls the loop reported before dispatch.
private final class CallRecorder: Sendable {
    private let storage = Mutex<[(name: String, argument: String)]>([])
    func record(_ name: String, _ argument: String) {
        storage.withLock { $0.append((name, argument)) }
    }
    var calls: [(name: String, argument: String)] { storage.withLock { $0 } }
}

/// A tool that records what it was asked, so "it ran" is a fact rather than an inference.
private final class StubTool: ToolProvider {
    let name: String
    let description = "a tool used by the turn-loop tests"
    let argumentName = "query"
    let argumentDescription = "what to look up"
    private let received = Mutex<[String]>([])

    init(name: String) { self.name = name }

    var arguments: [String] { received.withLock { $0 } }

    func run(argument: String) async throws -> ToolOutcome {
        received.withLock { $0.append(argument) }
        return ToolOutcome(text: "result for \(argument)", summary: "\(name) ran")
    }
}

/// A 1×1 PNG, so the image path carries real decodable bytes.
private let tinyPNG = Data(
    base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)!

// MARK: - Fixtures

private func spec(
    id: String = "Agent 1",
    displayName: String = "Mira",
    thinking: ThinkingMode = .off
) -> AgentSpec {
    AgentSpec(
        id: id, displayName: displayName, maxTokens: 512, contextWindow: 32_768,
        webSearchEnabled: true, thinking: thinking)
}

private func settings(
    _ spec: AgentSpec, thinking: ThinkingMode? = nil, contextWindow: Int? = 32_768
) -> TurnSettings {
    TurnSettings(spec: spec, thinking: thinking ?? spec.thinking, contextWindow: contextWindow)
}

private func info(
    prompt: Int = 10, generation: Int = 4, generateTime: Double = 2
) -> GenerateCompletionInfo {
    GenerateCompletionInfo(
        promptTokenCount: prompt, generationTokenCount: generation,
        promptTime: 0.5, generationTime: generateTime, stopReason: .stop)
}

private func call(_ name: String, argument: String, id: String) -> ToolCall {
    ToolCall(
        function: .init(name: name, arguments: ["query": .string(argument)]), id: id)
}

/// Run one turn through the real loop with a scripted model.
@discardableResult
private func performTurn(
    engine: MLXEngine,
    settings turnSettings: TurnSettings,
    messages: [PromptMessage],
    tools: [any ToolProvider] = [],
    images: [Data] = [],
    rounds: ScriptedRounds,
    events: EventRecorder,
    calls: CallRecorder = CallRecorder()
) async throws -> String {
    try await engine.runTurn(
        settings: turnSettings,
        messages: messages,
        tools: tools,
        images: images,
        makeStream: { await rounds.stream(for: $0) },
        onToolCall: { name, argument in calls.record(name, argument) },
        onEvent: { events.record($0) })
}

// MARK: - The turn loop

@Suite("The turn loop runs on a stubbed model (A02)")
struct AuditFinalTurnLoopTests {

    @Test("Prompt assembly sends the opening messages unchanged, in order")
    func promptAssembly() async throws {
        let engine = MLXEngine(spec: spec())
        let rounds = ScriptedRounds([[.chunk("Hi there"), .info(info())]])
        let events = EventRecorder()

        let text = try await performTurn(
            engine: engine,
            settings: settings(spec()),
            messages: [
                PromptMessage(role: .system, content: "You are Mira."),
                PromptMessage(role: .user, content: "What is the cost?"),
            ],
            rounds: rounds,
            events: events)

        #expect(text == "Hi there")
        let prompts = await rounds.recorded()
        #expect(prompts.count == 1)
        #expect(prompts[0].entries.map(\.role) == ["system", "user"])
        #expect(prompts[0].entries.map(\.content) == ["You are Mira.", "What is the cost?"])
        #expect(prompts[0].imageHostIndex == nil, "no images were attached")
        #expect(prompts[0].images.isEmpty)
        #expect(prompts[0].toolSpecs == nil, "no tools were offered")
        #expect(events.tokens == ["Hi there"])
        #expect(events.finished.count == 1)
        #expect(events.finished.first?.text == "Hi there")
    }

    @Test("The reported stats come from the round's info event")
    func statsAreMeasured() async throws {
        let engine = MLXEngine(spec: spec())
        let rounds = ScriptedRounds([[.chunk("ok"), .info(info(prompt: 123, generation: 7))]])
        let events = EventRecorder()

        _ = try await performTurn(
            engine: engine, settings: settings(spec()),
            messages: [PromptMessage(role: .user, content: "hi")],
            rounds: rounds, events: events)

        let stats = try #require(events.finished.first?.stats)
        #expect(stats.promptTokens == 123)
        #expect(stats.generationTokens == 7)
        #expect(stats.prefillSeconds == 0.5)
        #expect(stats.stopReason == "stop")
        #expect(stats.tokensPerSecond == 3.5, "7 tokens over 2 seconds")
        #expect(await engine.lastStats == stats, "the seat keeps the turn's stats")
    }

    @Test("Images ride on the last user entry of the first round only")
    func imagesRideOnTheFirstRound() async throws {
        let engine = MLXEngine(spec: spec())
        let rounds = ScriptedRounds([[.chunk("seen"), .info(info())]])
        let events = EventRecorder()

        _ = try await performTurn(
            engine: engine, settings: settings(spec()),
            messages: [
                PromptMessage(role: .system, content: "sys"),
                PromptMessage(role: .user, content: "look"),
            ],
            images: [tinyPNG],
            rounds: rounds, events: events)

        let prompts = await rounds.recorded()
        #expect(prompts.count == 1)
        #expect(prompts[0].images.count == 1)
        #expect(prompts[0].imageHostIndex == 1, "the user entry is the image host")
        #expect(prompts[0].toolSpecs == nil)
    }

    @Test("A tool round is framed as the template requires, and callable again")
    func toolRoundFraming() async throws {
        let tool = StubTool(name: "web_search")
        let engine = MLXEngine(spec: spec())
        let rounds = ScriptedRounds([
            [.chunk("Let me check."), .toolCall(call("web_search", argument: "ev market", id: "c1")), .info(info())],
            [.chunk("The market grew."), .info(info())],
        ])
        let events = EventRecorder()
        let calls = CallRecorder()

        let text = try await performTurn(
            engine: engine, settings: settings(spec()),
            messages: [PromptMessage(role: .user, content: "question")],
            tools: [tool], rounds: rounds, events: events, calls: calls)

        // The answer accumulates across rounds: round one's preamble is part of the turn.
        #expect(text == "Let me check.The market grew.")
        #expect(tool.arguments == ["ev market"], "the offered tool ran with the model's argument")
        #expect(calls.calls.map(\.name) == ["web_search"])
        #expect(calls.calls.first?.argument == "ev market")
        #expect(events.toolResults.count == 1)
        #expect(events.toolResults.first?.summary == "web_search ran")

        let prompts = await rounds.recorded()
        #expect(prompts.count == 2)
        #expect(prompts[0].toolSpecs != nil, "the model was offered the tool")
        // The second round restates the whole log: the opening message, the assistant turn
        // carrying the call, one tool result, and the continuation user turn.
        let second = prompts[1]
        #expect(second.entries.map(\.role) == ["user", "assistant", "tool", "user"])
        #expect(second.entries[1].toolCalls.count == 1)
        #expect(second.entries[1].toolCalls.first?.function.name == "web_search")
        #expect(second.entries[2].toolResultID == "c1")
        #expect(second.entries[2].content == "result for ev market")
        #expect(second.entries[3].content == MLXEngine.toolContinuation)
    }

    @Test("A call for a tool the turn did not offer is refused, not run")
    func refusalPath() async throws {
        // `web_search` is offered, so the round may dispatch; `rm_rf` is not, so dispatch must
        // refuse it and hand the refusal back to the model rather than reaching the network.
        let offered = StubTool(name: "web_search")
        let engine = MLXEngine(spec: spec())
        let rounds = ScriptedRounds([
            [.toolCall(call("rm_rf", argument: "/", id: "evil")), .info(info())],
            [.chunk("Understood."), .info(info())],
        ])
        let events = EventRecorder()

        _ = try await performTurn(
            engine: engine, settings: settings(spec()),
            messages: [PromptMessage(role: .user, content: "question")],
            tools: [offered], rounds: rounds, events: events)

        #expect(offered.arguments.isEmpty, "the offered tool was never called")
        #expect(events.toolResults.count == 1)
        #expect(events.toolResults.first?.summary.contains("refused rm_rf") == true)
        let prompts = await rounds.recorded()
        #expect(prompts.count == 2)
        let refusal = try #require(prompts[1].entries.first { $0.role == "tool" })
        #expect(refusal.content.contains("is not available in this turn"))
        #expect(refusal.content.contains("web_search"), "the refusal names what is available")
    }

    @Test("Tool rounds are bounded, whatever the model keeps asking for")
    func toolRoundsAreBounded() async throws {
        let tool = StubTool(name: "web_search")
        let engine = MLXEngine(spec: spec())
        let rounds = ScriptedRounds([
            [.toolCall(call("web_search", argument: "1", id: "c1"))],
            [.toolCall(call("web_search", argument: "2", id: "c2"))],
            [.toolCall(call("web_search", argument: "3", id: "c3"))],
            [.toolCall(call("web_search", argument: "4", id: "c4"))],
        ])
        let events = EventRecorder()

        _ = try await performTurn(
            engine: engine, settings: settings(spec()),
            messages: [PromptMessage(role: .user, content: "question")],
            tools: [tool], rounds: rounds, events: events)

        #expect(tool.arguments == ["1", "2", "3"], "the fourth call is not dispatched")
        let promptCount = await rounds.recorded().count
        #expect(promptCount == 4)
    }

    @Test("The reasoning ceiling ends the turn and fails it with no answer")
    func ceilingEndsTheTurn() async throws {
        // `.minimal` is a 128-reasoning-token ceiling, counted at four characters per token.
        let thinking = ThinkingMode.minimal
        let seat = spec(thinking: thinking)
        let engine = MLXEngine(spec: seat)
        let rounds = ScriptedRounds([[.chunk(String(repeating: "deliberating ", count: 60)), .info(info())]])
        let events = EventRecorder()

        var thrown: ReasoningCeilingError?
        do {
            _ = try await performTurn(
                engine: engine, settings: settings(seat, thinking: thinking),
                messages: [PromptMessage(role: .user, content: "question")],
                rounds: rounds, events: events)
            Issue.record("a ceiling-abandoned turn with no answer must not return success")
        } catch let error as ReasoningCeilingError {
            thrown = error
        }

        let ceiling = try #require(thrown)
        #expect(ceiling.mode == thinking)
        #expect(ceiling.ceiling == thinking.reasoningTokenBudget)
        #expect(events.finished.isEmpty, "no successful turn was reported")
        let failure = try #require(events.failures.first { $0.name == "thinking" })
        #expect(failure.message.contains("ended before the model produced an answer"))
        #expect(await engine.lastStats != nil, "the turn's stats survive the failure")
    }

    @Test("Reasoning with no answer is reported as having spent the budget")
    func spentBudgetNotice() async throws {
        // `.high` leaves 8 192 reasoning tokens of headroom, so the ceiling is not what ends
        // this turn — the model simply never stops thinking.
        let thinking = ThinkingMode.high
        let seat = spec(thinking: thinking)
        let engine = MLXEngine(spec: seat)
        let rounds = ScriptedRounds([[.chunk(String(repeating: "thinking about it ", count: 20)), .info(info())]])
        let events = EventRecorder()

        let text = try await performTurn(
            engine: engine, settings: settings(seat, thinking: thinking),
            messages: [PromptMessage(role: .user, content: "question")],
            rounds: rounds, events: events)

        #expect(text.isEmpty)
        #expect(!events.reasoning.isEmpty, "the reasoning was streamed")
        let failure = try #require(events.failures.first { $0.name == "generation" })
        #expect(failure.message.contains("spent the whole"))
        #expect(failure.message.contains("\(settings(seat, thinking: thinking).generationCap)-token"))
        #expect(events.finished.count == 1, "the empty turn is still reported as finished")
    }

    @Test("Fabricated tool syntax is stripped and the speaker tag removed")
    func fabricatedSyntaxAndSpeakerTag() async throws {
        let engine = MLXEngine(spec: spec(displayName: "Mira"))
        let rounds = ScriptedRounds([
            [.chunk("[web_search]\nquery: capital cost\nMira: The capital cost is 12%."), .info(info())]
        ])
        let events = EventRecorder()

        let text = try await performTurn(
            engine: engine, settings: settings(spec(displayName: "Mira")),
            messages: [PromptMessage(role: .user, content: "question")],
            rounds: rounds, events: events)

        #expect(text == "The capital cost is 12%.")
    }

    @Test("The round's parameters mirror the turn's settings")
    func parametersMirrorSettings() async throws {
        var seat = spec()
        seat.presencePenalty = -0.5
        seat.repetitionPenalty = 1.1
        seat.temperature = 0.4
        seat.topP = 0.8
        seat.topK = 20
        seat.minP = 0.05

        let turn = settings(seat, thinking: .off)
        let parameters = MLXEngine.parameters(for: turn)
        #expect(parameters.maxTokens == turn.generationCap)
        #expect(parameters.temperature == Float(0.4))
        #expect(parameters.topP == Float(0.8))
        #expect(parameters.topK == 20)
        #expect(parameters.minP == Float(0.05))
        #expect(parameters.presencePenalty == Float(-0.5))
        #expect(parameters.repetitionPenalty == Float(1.1))
        #expect(parameters.presenceContextSize == 256)
        #expect(parameters.repetitionContextSize == 256)

        // An absent penalty stays off rather than becoming zero.
        let bare = MLXEngine.parameters(for: settings(spec()))
        #expect(bare.presencePenalty == nil)
        #expect(bare.repetitionPenalty == nil)
    }

    @Test("A round with no info event still reports honest statistics")
    func statsWithoutInfo() async throws {
        let engine = MLXEngine(spec: spec())
        let rounds = ScriptedRounds([[.chunk("ok")]])
        let events = EventRecorder()

        _ = try await performTurn(
            engine: engine, settings: settings(spec()),
            messages: [PromptMessage(role: .user, content: "hi")],
            rounds: rounds, events: events)

        let stats = try #require(events.finished.first?.stats)
        #expect(stats.generationTokens == 0)
        #expect(stats.seconds >= 0)
    }
}

// MARK: - The pure pieces the loop is built from

@Suite("Turn-loop rules without a model (A02)")
struct AuditFinalTurnRuleTests {

    @Test("The tool round is framed as assistant calls, results, then a user turn")
    func toolRoundFramingRule() {
        var entries = [MLXEngine.TurnEntry(role: "user", content: "q")]
        MLXEngine.appendToolRound(
            &entries,
            dispatched: [
                MLXEngine.DispatchedCall(
                    call: call("web_search", argument: "a", id: "c1"),
                    outcome: ToolOutcome(text: "one", summary: "ran")),
                MLXEngine.DispatchedCall(
                    call: call("fetch_page", argument: "b", id: "c2"),
                    outcome: ToolOutcome(text: "two", summary: "ran")),
            ])

        #expect(entries.map(\.role) == ["user", "assistant", "tool", "tool", "user"])
        #expect(entries[1].toolCalls.map(\.id) == ["c1", "c2"])
        #expect(entries[1].content.isEmpty)
        #expect(entries[2].toolResultID == "c1")
        #expect(entries[2].content == "one")
        #expect(entries[3].toolResultID == "c2")
        #expect(entries[4].content == MLXEngine.toolContinuation)
    }

    @Test("A finished turn reports at most the failures it earned, in order")
    func noticeRule() {
        // A clean answer earns nothing.
        #expect(
            MLXEngine.turnNotices(
                finalAnswer: "an answer", sawReasoning: false, reasoningWasTruncated: false,
                loopDetected: false, thinking: .high, ceiling: 8_192, generationCap: 9_000
            ).isEmpty)

        // Reasoning and no answer, with the ceiling not reached: the budget notice.
        let spent = MLXEngine.turnNotices(
            finalAnswer: "", sawReasoning: true, reasoningWasTruncated: false,
            loopDetected: false, thinking: .high, ceiling: 8_192, generationCap: 9_000)
        #expect(spent.count == 1)
        #expect(spent[0].name == "generation")
        #expect(spent[0].message.contains("9000-token"))

        // The ceiling reached and no answer: only the ceiling's notice, not the budget's.
        let truncated = MLXEngine.turnNotices(
            finalAnswer: "", sawReasoning: true, reasoningWasTruncated: true,
            loopDetected: false, thinking: .minimal, ceiling: 128, generationCap: 640)
        #expect(truncated.count == 1)
        #expect(truncated[0].name == "thinking")
        #expect(truncated[0].message.contains("128 reasoning tokens"))
        #expect(truncated[0].message.contains("before the model produced an answer"))

        // The ceiling reached *with* an answer keeps the answer and says so.
        let cutOffWithAnswer = MLXEngine.turnNotices(
            finalAnswer: "partial", sawReasoning: true, reasoningWasTruncated: true,
            loopDetected: false, thinking: .minimal, ceiling: 128, generationCap: 640)
        #expect(cutOffWithAnswer[0].message.contains("keeps the answer written so far"))

        // A repetition loop is reported after the budget notice and before the ceiling's.
        let all = MLXEngine.turnNotices(
            finalAnswer: "", sawReasoning: true, reasoningWasTruncated: true,
            loopDetected: true, thinking: .minimal, ceiling: 128, generationCap: 640)
        #expect(all.map(\.name) == ["generation", "thinking"])
        #expect(all[0].message.contains("repetition loop"))
    }

    @Test("A stray delimiter or echoed speaker tag is removed from the answer")
    func cleanRule() {
        let seat = spec(id: "Agent 1", displayName: "Mira")
        let turn = settings(seat)
        #expect(MLXEngine.clean("  hello  ", settings: turn) == "hello")
        #expect(MLXEngine.clean("<think>hello", settings: turn) == "hello")
        #expect(MLXEngine.clean("</think>\nhello", settings: turn) == "hello")
        #expect(MLXEngine.clean("[Agent 1] hello", settings: turn) == "hello")
        #expect(MLXEngine.clean("Agent 1: hello", settings: turn) == "hello")
        #expect(MLXEngine.clean("Mira: hello", settings: turn) == "hello")
        #expect(MLXEngine.clean("hello Mira: there", settings: turn) == "hello Mira: there")
        #expect(MLXEngine.clean("<thinking> is not a delimiter", settings: turn) == "<thinking> is not a delimiter")
    }

    @Test("The stop reason is reported as the template's own word")
    func stopReasonNames() {
        #expect(MLXEngine.describe(.stop) == "stop")
        #expect(MLXEngine.describe(.length) == "length")
        #expect(MLXEngine.describe(.cancelled) == "cancelled")
    }

    @Test("Statistics are derived from the info event")
    func statsRule() {
        let started = Date(timeIntervalSince1970: 1_000)
        let stats = MLXEngine.stats(
            from: info(prompt: 100, generation: 50, generateTime: 5),
            started: started, now: Date(timeIntervalSince1970: 1_002))
        #expect(stats.promptTokens == 100)
        #expect(stats.generationTokens == 50)
        #expect(stats.tokensPerSecond == 10)
        #expect(stats.seconds == 2)
        #expect(stats.cachedPromptTokens == 0)

        // A zero generation time must not divide by zero.
        let zero = MLXEngine.stats(
            from: info(prompt: 1, generation: 1, generateTime: 0), started: started)
        #expect(zero.tokensPerSecond == 0)
    }

    @Test("The model's tool spec carries the provider's own description")
    func toolSpecRule() {
        let tool = StubTool(name: "web_search")
        let toolSpec = MLXEngine.toolSpec(for: tool)
        #expect(toolSpec["type"] as? String == "function")
        let function = toolSpec["function"] as? [String: any Sendable]
        #expect(function?["name"] as? String == "web_search")
        #expect(function?["description"] as? String == tool.description)
        let parameters = function?["parameters"] as? [String: any Sendable]
        #expect(parameters?["type"] as? String == "object")
        #expect((parameters?["required"] as? [String]) == ["query"])
    }

    @Test("Only decodable images reach the engine")
    func usableImageRule() {
        let seat = spec()

        let good = AttachedDocument(
            name: "chart.png", kind: .image, byteCount: tinyPNG.count, imageData: tinyPNG)
        let text = AttachedDocument(name: "notes.txt", kind: .plainText, text: "hello")
        let undecodable = AttachedDocument(
            name: "broken.png", kind: .image, byteCount: 3, imageData: Data([0x01, 0x02, 0x03]))

        let images = MLXEngine.usableImages(from: [good, text, undecodable], specID: seat.id)
        #expect(images == [tinyPNG], "the document is ignored and the broken image is dropped")
    }
}

// MARK: - The seat's own surface

@Suite("An unloaded seat still behaves (A02)")
struct AuditFinalSeatSurfaceTests {

    @Test("A fresh seat reports its spec and is not loaded")
    func freshSeat() async {
        let seat = spec(thinking: .medium)
        let engine = MLXEngine(spec: seat)

        #expect(await engine.isLoaded == false)
        #expect(await engine.contextWindow == 32_768)
        #expect(await engine.thinking == .medium)
        #expect(await engine.lastStats == nil)
        #expect(await engine.attachedImageCount == 0)
        #expect(await engine.currentSpec == seat)
        #expect(await engine.persona == PersonaCatalog.style(id: seat.personaID, mode: seat.mode))
    }

    @Test("Live changes move currentSpec and leave spec alone")
    func liveConfiguration() async {
        let seat = spec(displayName: "Mira")
        let concrete = MLXEngine(spec: seat)
        // Called through the protocol, which is the shape the shipped call sites use
        // (`ConversationEngine.seatEngine(for:)` returns `any LLMEngine`). Calling these on the
        // concrete actor type resolves to the protocol extension's async no-op default instead
        // — a separate, latent defect reported with this task rather than fixed here.
        let engine: any LLMEngine = concrete

        await engine.setThinking(.high)
        await engine.setPersona(PersonaLibrary.neutral.id)
        await engine.setDisplayName("Iris")

        #expect(await concrete.thinking == .high)
        #expect(await concrete.spec.displayName == "Mira", "the protocol's spec is immutable")
        let live = await concrete.currentSpec
        #expect(live.thinking == .high)
        #expect(live.displayName == "Iris")
        #expect(live.id == seat.id)
    }

    @Test("Unloading an unloaded seat reports idle")
    func unloadReportsIdle() async {
        let states = Mutex<[EngineState]>([])
        let engine = MLXEngine(spec: spec()) { state in states.withLock { $0.append(state) } }

        await engine.unload()

        #expect(await engine.isLoaded == false)
        #expect(states.withLock { $0 } == [.idle])
    }

    @Test("Attachments keep only what the engine can actually use")
    func attachmentsFilter() async {
        let engine = MLXEngine(spec: spec())
        let good = AttachedDocument(
            name: "chart.png", kind: .image, byteCount: tinyPNG.count, imageData: tinyPNG)
        let text = AttachedDocument(name: "notes.txt", kind: .plainText, text: "hello")
        let broken = AttachedDocument(
            name: "broken.png", kind: .image, byteCount: 3, imageData: Data([0x01]))

        await engine.setAttachments([good, text])
        #expect(await engine.attachedImageCount == 1)

        await engine.setAttachments([text, broken])
        #expect(await engine.attachedImageCount == 0, "a broken image is not held")
    }

    @Test("Engine state reports readiness only for ready")
    func engineStateReadiness() {
        #expect(EngineState.ready.isReady)
        #expect(!EngineState.idle.isReady)
        #expect(!EngineState.loading(progress: 0.5).isReady)
        #expect(!EngineState.failed("no").isReady)
    }

    @Test("A seat built with one engine answers on either backend")
    @MainActor
    func oneEngineAnswersEitherBackend() async {
        // This is the invariant the old `mlx ?? openAI!` asserted with a force unwrap: at
        // least one engine is always installed, so the fallback cannot be empty.
        var mlxSeat = spec()
        let mlx = MLXEngine(spec: mlxSeat)
        let seat = ConversationEngine.Seat(spec: mlxSeat, engine: mlx)
        #expect((seat.engine as? MLXEngine) != nil)

        mlxSeat.backend = .openAIResponses
        let apiSeat = ConversationEngine.Seat(spec: mlxSeat, engine: mlx)
        #expect(
            (apiSeat.engine as? MLXEngine) != nil,
            "the only installed engine answers either backend")

        let engine = ConversationEngine(seats: [seat], configuration: .init())
        #expect((engine.mlxEngine(for: seat.spec.id) as? MLXEngine) != nil)
        #expect((engine.seatEngine(for: seat.spec.id) as? MLXEngine) != nil)
    }
}

// MARK: - The MLX gate

/// Watches for two holders of the gate at once. A class because `Mutex` is non-copyable and
/// so cannot be captured by the task-group closures directly.
private final class GateProbe: Sendable {
    private let live = Mutex(0)
    private let overlapped = Mutex(false)
    private let completed = Mutex(0)

    func enter() -> Int { live.withLock { $0 += 1; return $0 } }
    func leave() { live.withLock { $0 -= 1 }; completed.withLock { $0 += 1 } }
    func noteIfOverlapping(_ holders: Int) { if holders > 1 { overlapped.withLock { $0 = true } } }
    var didOverlap: Bool { overlapped.withLock { $0 } }
    var completionCount: Int { completed.withLock { $0 } }
}

@Suite("The MLX gate serialises access (A02)")
struct AuditFinalMLXGateTests {

    @Test("Exclusive access returns what the body returned")
    func exclusiveReturnsBody() async throws {
        let value = try await MLXGate.exclusive { 41 + 1 }
        #expect(value == 42)
    }

    @Test("Two exclusive bodies never overlap")
    func exclusiveSerialises() async {
        let probe = GateProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await MLXGate.exclusive {
                        probe.noteIfOverlapping(probe.enter())
                        try? await Task.sleep(for: .milliseconds(2))
                        probe.leave()
                    }
                }
            }
        }

        #expect(probe.didOverlap == false, "two bodies held the gate at once")
        #expect(probe.completionCount == 8, "every waiter was let in")
    }

    @Test("A throwing body still releases the gate")
    func throwingBodyReleases() async {
        struct Boom: Error {}
        do {
            try await MLXGate.exclusive { () async throws -> Void in throw Boom() }
            Issue.record("the body's error must propagate")
        } catch is Boom {
            // expected
        } catch {
            Issue.record("wrong error: \(error)")
        }
        // If the release on the error path were missing, this second acquire would hang; the
        // test's own deadline is the assertion that it does not.
        let after = try? await MLXGate.exclusive { "released" }
        #expect(after == "released")
    }
}
