// ChatBotsCoreTests — one generation turn, driven by a stub instead of weights.
//
// `MLXEngine.runTurn` takes the model's stream as an injected `makeStream`, so these tests drive the
// real turn loop with a scripted list and assert what it sent, emitted and returned. The suite was the
// first half of `TurnLoopModelTests.swift`.

import Foundation
import Testing

@testable import ChatBotsCore

@Suite("The turn loop runs on a stubbed model")
struct TurnLoopModelTests {

    @Test("Prompt assembly sends the opening messages unchanged, in order")
    func promptAssembly() async throws {
        let engine = MLXEngine(spec: TurnLoopHarness.spec())
        let rounds = TurnLoopHarness.ScriptedRounds([[.chunk("Hi there"), .info(TurnLoopHarness.info())]])
        let events = TurnLoopHarness.EventRecorder()

        let text = try await TurnLoopHarness.performTurn(
            engine: engine,
            settings: TurnLoopHarness.settings(TurnLoopHarness.spec()),
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
        let engine = MLXEngine(spec: TurnLoopHarness.spec())
        let rounds = TurnLoopHarness.ScriptedRounds([
            [.chunk("ok"), .info(TurnLoopHarness.info(prompt: 123, generation: 7))]
        ])
        let events = TurnLoopHarness.EventRecorder()

        _ = try await TurnLoopHarness.performTurn(
            engine: engine, settings: TurnLoopHarness.settings(TurnLoopHarness.spec()),
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
        let engine = MLXEngine(spec: TurnLoopHarness.spec())
        let rounds = TurnLoopHarness.ScriptedRounds([[.chunk("seen"), .info(TurnLoopHarness.info())]])
        let events = TurnLoopHarness.EventRecorder()

        _ = try await TurnLoopHarness.performTurn(
            engine: engine, settings: TurnLoopHarness.settings(TurnLoopHarness.spec()),
            messages: [
                PromptMessage(role: .system, content: "sys"),
                PromptMessage(role: .user, content: "look"),
            ],
            images: [TurnLoopHarness.tinyPNG],
            rounds: rounds, events: events)

        let prompts = await rounds.recorded()
        #expect(prompts.count == 1)
        #expect(prompts[0].images.count == 1)
        #expect(prompts[0].imageHostIndex == 1, "the user entry is the image host")
        #expect(prompts[0].toolSpecs == nil)
    }

    @Test("A tool round is framed as the template requires, and callable again")
    func toolRoundFraming() async throws {
        let tool = TurnLoopHarness.StubTool(name: "web_search")
        let engine = MLXEngine(spec: TurnLoopHarness.spec())
        let rounds = TurnLoopHarness.ScriptedRounds([
            [
                .chunk("Let me check."), .toolCall(TurnLoopHarness.call("web_search", argument: "ev market", id: "c1")),
                .info(TurnLoopHarness.info()),
            ],
            [.chunk("The market grew."), .info(TurnLoopHarness.info())],
        ])
        let events = TurnLoopHarness.EventRecorder()
        let calls = TurnLoopHarness.CallRecorder()

        let text = try await TurnLoopHarness.performTurn(
            engine: engine, settings: TurnLoopHarness.settings(TurnLoopHarness.spec()),
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
        let offered = TurnLoopHarness.StubTool(name: "web_search")
        let engine = MLXEngine(spec: TurnLoopHarness.spec())
        let rounds = TurnLoopHarness.ScriptedRounds([
            [.toolCall(TurnLoopHarness.call("rm_rf", argument: "/", id: "evil")), .info(TurnLoopHarness.info())],
            [.chunk("Understood."), .info(TurnLoopHarness.info())],
        ])
        let events = TurnLoopHarness.EventRecorder()

        _ = try await TurnLoopHarness.performTurn(
            engine: engine, settings: TurnLoopHarness.settings(TurnLoopHarness.spec()),
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
        let tool = TurnLoopHarness.StubTool(name: "web_search")
        let engine = MLXEngine(spec: TurnLoopHarness.spec())
        let rounds = TurnLoopHarness.ScriptedRounds([
            [.toolCall(TurnLoopHarness.call("web_search", argument: "1", id: "c1"))],
            [.toolCall(TurnLoopHarness.call("web_search", argument: "2", id: "c2"))],
            [.toolCall(TurnLoopHarness.call("web_search", argument: "3", id: "c3"))],
            [.toolCall(TurnLoopHarness.call("web_search", argument: "4", id: "c4"))],
        ])
        let events = TurnLoopHarness.EventRecorder()

        _ = try await TurnLoopHarness.performTurn(
            engine: engine, settings: TurnLoopHarness.settings(TurnLoopHarness.spec()),
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
        let seat = TurnLoopHarness.spec(thinking: thinking)
        let engine = MLXEngine(spec: seat)
        let rounds = TurnLoopHarness.ScriptedRounds([
            [.chunk(String(repeating: "deliberating ", count: 60)), .info(TurnLoopHarness.info())]
        ])
        let events = TurnLoopHarness.EventRecorder()

        var thrown: ReasoningCeilingError?
        do {
            _ = try await TurnLoopHarness.performTurn(
                engine: engine, settings: TurnLoopHarness.settings(seat, thinking: thinking),
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
        let seat = TurnLoopHarness.spec(thinking: thinking)
        let engine = MLXEngine(spec: seat)
        let rounds = TurnLoopHarness.ScriptedRounds([
            [.chunk(String(repeating: "thinking about it ", count: 20)), .info(TurnLoopHarness.info())]
        ])
        let events = TurnLoopHarness.EventRecorder()

        let text = try await TurnLoopHarness.performTurn(
            engine: engine, settings: TurnLoopHarness.settings(seat, thinking: thinking),
            messages: [PromptMessage(role: .user, content: "question")],
            rounds: rounds, events: events)

        #expect(text.isEmpty)
        #expect(!events.reasoning.isEmpty, "the reasoning was streamed")
        let failure = try #require(events.failures.first { $0.name == "generation" })
        #expect(failure.message.contains("spent the whole"))
        #expect(failure.message.contains("\(TurnLoopHarness.settings(seat, thinking: thinking).generationCap)-token"))
        #expect(events.finished.count == 1, "the empty turn is still reported as finished")
    }

    @Test("Fabricated tool syntax is stripped and the speaker tag removed")
    func fabricatedSyntaxAndSpeakerTag() async throws {
        let engine = MLXEngine(spec: TurnLoopHarness.spec(displayName: "Mira"))
        let rounds = TurnLoopHarness.ScriptedRounds([
            [
                .chunk("[web_search]\nquery: capital cost\nMira: The capital cost is 12%."),
                .info(TurnLoopHarness.info()),
            ]
        ])
        let events = TurnLoopHarness.EventRecorder()

        let text = try await TurnLoopHarness.performTurn(
            engine: engine, settings: TurnLoopHarness.settings(TurnLoopHarness.spec(displayName: "Mira")),
            messages: [PromptMessage(role: .user, content: "question")],
            rounds: rounds, events: events)

        #expect(text == "The capital cost is 12%.")
    }

    @Test("The round's parameters mirror the turn's settings")
    func parametersMirrorSettings() async throws {
        var seat = TurnLoopHarness.spec()
        seat.presencePenalty = -0.5
        seat.repetitionPenalty = 1.1
        seat.temperature = 0.4
        seat.topP = 0.8
        seat.topK = 20
        seat.minP = 0.05

        let turn = TurnLoopHarness.settings(seat, thinking: .off)
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
        let bare = MLXEngine.parameters(for: TurnLoopHarness.settings(TurnLoopHarness.spec()))
        #expect(bare.presencePenalty == nil)
        #expect(bare.repetitionPenalty == nil)
    }

    @Test("A round with no info event still reports honest statistics")
    func statsWithoutInfo() async throws {
        let engine = MLXEngine(spec: TurnLoopHarness.spec())
        let rounds = TurnLoopHarness.ScriptedRounds([[.chunk("ok")]])
        let events = TurnLoopHarness.EventRecorder()

        _ = try await TurnLoopHarness.performTurn(
            engine: engine, settings: TurnLoopHarness.settings(TurnLoopHarness.spec()),
            messages: [PromptMessage(role: .user, content: "hi")],
            rounds: rounds, events: events)

        let stats = try #require(events.finished.first?.stats)
        #expect(stats.generationTokens == 0)
        #expect(stats.seconds >= 0)
    }
}

// MARK: - The pure pieces the loop is built from
