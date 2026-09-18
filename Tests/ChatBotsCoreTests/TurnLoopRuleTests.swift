// ChatBotsCoreTests — the turn-loop rules that need no model at all.
//
// Prompt framing, stop reasons, failure reporting, the reasoning ceiling and the gate that serialises
// access. These were the later suites of `TurnLoopModelTests.swift`.

import Foundation
import Synchronization
import Testing

@testable import ChatBotsCore

@Suite("Turn-loop rules without a model")
struct TurnLoopRuleTests {

    @Test("The tool round is framed as assistant calls, results, then a user turn")
    func toolRoundFramingRule() {
        var entries = [MLXEngine.TurnEntry(role: "user", content: "q")]
        MLXEngine.appendToolRound(
            &entries,
            dispatched: [
                MLXEngine.DispatchedCall(
                    call: TurnLoopHarness.call("web_search", argument: "a", id: "c1"),
                    outcome: ToolOutcome(text: "one", summary: "ran")),
                MLXEngine.DispatchedCall(
                    call: TurnLoopHarness.call("fetch_page", argument: "b", id: "c2"),
                    outcome: ToolOutcome(text: "two", summary: "ran")),
            ])

        #expect(entries.map(\.role) == ["user", "assistant", "tool", "tool", "user"])
        #expect(entries[1].toolCalls.map(\.id) == ["c1", "c2"])
        #expect(entries[1].content.isEmpty)
        #expect(entries[2].toolResultID == "c1")
        #expect(entries[2].content.contains("one"), "the tool's data is still there")
        #expect(
            entries[2].content.contains("BEGIN TOOL DATA"),
            "and it is fenced, because it comes from outside the app")
        #expect(entries[3].toolResultID == "c2")
        #expect(entries[4].content == MLXEngine.toolContinuation)
    }

    @Test("A finished turn reports at most the failures it earned, in order")
    func noticeRule() {
        // A clean answer earns nothing.
        #expect(
            MLXEngine.turnNotices(
                finalAnswer: "an answer", sawReasoning: false, reasoningWasTruncated: false,
                loopDetected: false, budget: .init(thinking: .high, ceiling: 8_192, generationCap: 9_000)
            ).isEmpty)

        // Reasoning and no answer, with the ceiling not reached: the budget notice.
        let spent = MLXEngine.turnNotices(
            finalAnswer: "", sawReasoning: true, reasoningWasTruncated: false,
            loopDetected: false, budget: .init(thinking: .high, ceiling: 8_192, generationCap: 9_000))
        #expect(spent.count == 1)
        #expect(spent[0].name == "generation")
        #expect(spent[0].message.contains("9000-token"))

        // The ceiling reached and no answer: only the ceiling's notice, not the budget's.
        let truncated = MLXEngine.turnNotices(
            finalAnswer: "", sawReasoning: true, reasoningWasTruncated: true,
            loopDetected: false, budget: .init(thinking: .minimal, ceiling: 128, generationCap: 640))
        #expect(truncated.count == 1)
        #expect(truncated[0].name == "thinking")
        #expect(truncated[0].message.contains("128 reasoning tokens"))
        #expect(truncated[0].message.contains("before the model produced an answer"))

        // The ceiling reached *with* an answer keeps the answer and says so.
        let cutOffWithAnswer = MLXEngine.turnNotices(
            finalAnswer: "partial", sawReasoning: true, reasoningWasTruncated: true,
            loopDetected: false, budget: .init(thinking: .minimal, ceiling: 128, generationCap: 640))
        #expect(cutOffWithAnswer[0].message.contains("keeps the answer written so far"))

        // A repetition loop is reported after the budget notice and before the ceiling's.
        let all = MLXEngine.turnNotices(
            finalAnswer: "", sawReasoning: true, reasoningWasTruncated: true,
            loopDetected: true, budget: .init(thinking: .minimal, ceiling: 128, generationCap: 640))
        #expect(all.map(\.name) == ["generation", "thinking"])
        #expect(all[0].message.contains("repetition loop"))
    }

    @Test("A stray delimiter or echoed speaker tag is removed from the answer")
    func cleanRule() {
        let seat = TurnLoopHarness.spec(id: "Agent 1", displayName: "Mira")
        let turn = TurnLoopHarness.settings(seat)
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
            from: TurnLoopHarness.info(prompt: 100, generation: 50, generateTime: 5),
            started: started, now: Date(timeIntervalSince1970: 1_002))
        #expect(stats.promptTokens == 100)
        #expect(stats.generationTokens == 50)
        #expect(stats.tokensPerSecond == 10)
        #expect(stats.seconds == 2)
        #expect(stats.cachedPromptTokens == 0)

        // A zero generation time must not divide by zero.
        let zero = MLXEngine.stats(
            from: TurnLoopHarness.info(prompt: 1, generation: 1, generateTime: 0), started: started)
        #expect(zero.tokensPerSecond == 0)
    }

    @Test("The model's tool spec carries the provider's own description")
    func toolSpecRule() {
        let tool = TurnLoopHarness.StubTool(name: "web_search")
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
        let seat = TurnLoopHarness.spec()

        let good = AttachedDocument(
            name: "chart.png", kind: .image, byteCount: TurnLoopHarness.tinyPNG.count,
            imageData: TurnLoopHarness.tinyPNG)
        let text = AttachedDocument(name: "notes.txt", kind: .plainText, text: "hello")
        let undecodable = AttachedDocument(
            name: "broken.png", kind: .image, byteCount: 3, imageData: Data([0x01, 0x02, 0x03]))

        let images = MLXEngine.usableImages(from: [good, text, undecodable], specID: seat.id)
        #expect(images == [TurnLoopHarness.tinyPNG], "the document is ignored and the broken image is dropped")
    }

    @Test("One turn dispatches at most the per-turn tool-call cap")
    func toolCallsAreCappedPerTurn() {
        // `roundAdvance` bounds the rounds, not the calls a round may carry, and the search
        // budget is checked once before the turn — so one model response could spend an
        // unbounded number of billed calls. The cap is enforced across the whole turn.
        let many = Array(1...20)
        let first = MLXEngine.toolCallsWithinBudget(many, alreadyDispatched: 0)
        #expect(first.run.count == MLXEngine.maximumToolCallsPerTurn)
        #expect(first.truncated)

        let partway = MLXEngine.toolCallsWithinBudget(many, alreadyDispatched: 6)
        #expect(partway.run.count == 2)
        #expect(partway.truncated)

        let spent = MLXEngine.toolCallsWithinBudget(
            many, alreadyDispatched: MLXEngine.maximumToolCallsPerTurn)
        #expect(spent.run.isEmpty)
        #expect(spent.truncated, "a turn that has spent the cap is refused another call")

        let roomy = MLXEngine.toolCallsWithinBudget([1, 2], alreadyDispatched: 0)
        #expect(roomy.run == [1, 2])
        #expect(!roomy.truncated, "a turn inside the cap is not truncated")
    }
}

// MARK: - The seat's own surface

@Suite("An unloaded seat still behaves")
struct SeatSurfaceTests {

    @Test("A fresh seat reports its spec and is not loaded")
    func freshSeat() async {
        let seat = TurnLoopHarness.spec(thinking: .medium)
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
        let seat = TurnLoopHarness.spec(displayName: "Mira")
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
        let engine = MLXEngine(spec: TurnLoopHarness.spec()) { state in states.withLock { $0.append(state) } }

        await engine.unload()

        #expect(await engine.isLoaded == false)
        #expect(states.withLock { $0 } == [.idle])
    }

    @Test("Attachments keep only what the engine can actually use")
    func attachmentsFilter() async {
        let engine = MLXEngine(spec: TurnLoopHarness.spec())
        let good = AttachedDocument(
            name: "chart.png", kind: .image, byteCount: TurnLoopHarness.tinyPNG.count,
            imageData: TurnLoopHarness.tinyPNG)
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
        var mlxSeat = TurnLoopHarness.spec()
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

    func enter() -> Int {
        live.withLock {
            $0 += 1
            return $0
        }
    }
    func leave() {
        live.withLock { $0 -= 1 }
        completed.withLock { $0 += 1 }
    }
    func noteIfOverlapping(_ holders: Int) { if holders > 1 { overlapped.withLock { $0 = true } } }
    var didOverlap: Bool { overlapped.withLock { $0 } }
    var completionCount: Int { completed.withLock { $0 } }
}

@Suite("The MLX gate serialises access")
struct MLXGateTests {

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
            try await MLXGate.exclusive { () async throws in throw Boom() }
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
