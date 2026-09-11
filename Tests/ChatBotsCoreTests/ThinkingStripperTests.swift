// ChatBotsCoreTests — the <think> splitter
//
// This is the one piece of stream handling that would otherwise be untestable
// (it sits between a live model and the transcript), so it is exercised directly.

import ChatBotsCore
import Testing

@Suite("ThinkingStripper")
struct ThinkingStripperTests {

    @Test("Primed stream routes the thought, then the answer")
    func primedStream() {
        var stripper = ThinkingStripper(startsPrimed: true)

        var reasoning = ""
        var answer = ""
        for chunk in ["The topic ", "is about eggs", ".", "\n</think>\n", "Eggs are ovoid "] {
            let segment = stripper.process(chunk)
            reasoning += segment.reasoning
            answer += segment.answer
        }
        let tail = stripper.finalize()
        reasoning += tail.reasoning
        answer += tail.answer

        #expect(reasoning == "The topic is about eggs.")
        #expect(answer == "Eggs are ovoid ")
        #expect(stripper.hasReasoning)
    }

    @Test("Unprimed stream consumes an explicit opening delimiter")
    func unprimedStream() {
        var stripper = ThinkingStripper(startsPrimed: false)
        var reasoning = ""
        var answer = ""
        for chunk in ["<think>", "hmm", "</think>", "Done."] {
            let segment = stripper.process(chunk)
            reasoning += segment.reasoning
            answer += segment.answer
        }
        #expect(reasoning == "hmm")
        #expect(answer == "Done.")
    }

    @Test("A delimiter split across chunks is not leaked as text")
    func splitDelimiter() {
        var stripper = ThinkingStripper(startsPrimed: true)
        var reasoning = ""
        var answer = ""
        for chunk in ["thought", "</thi", "nk>", "answer"] {
            let segment = stripper.process(chunk)
            reasoning += segment.reasoning
            answer += segment.answer
        }
        #expect(reasoning == "thought")
        #expect(answer == "answer")
        // The partial delimiter must never have been emitted as answer text.
        #expect(!answer.contains("<"))
    }

    @Test("Answer text containing an opening delimiter is preserved")
    func answerKeepsOpeningDelimiter() {
        var stripper = ThinkingStripper(startsPrimed: true)
        var answer = ""
        for chunk in ["</think>", "Use <think> as a tag."] {
            let segment = stripper.process(chunk)
            answer += segment.answer
        }
        let tail = stripper.finalize()
        answer += tail.answer
        #expect(answer == "Use <think> as a tag.")
    }

    @Test("A model that never closes the thought keeps everything in reasoning")
    func unclosedReasoning() {
        var stripper = ThinkingStripper(startsPrimed: true)
        var reasoning = ""
        var answer = ""
        for chunk in ["still thinking", " and thinking"] {
            let segment = stripper.process(chunk)
            reasoning += segment.reasoning
            answer += segment.answer
        }
        let tail = stripper.finalize()
        reasoning += tail.reasoning
        answer += tail.answer

        #expect(answer.isEmpty)
        #expect(reasoning == "still thinking and thinking")
        #expect(stripper.isInsideReasoning == false)  // finalized
    }

    @Test("Reasoning mode maps to the expected chat-template flag")
    func templateFlags() {
        #expect(ReasoningMode.off.templateContext?["enable_thinking"] as? Bool == false)
        #expect(ReasoningMode.stream.templateContext?["enable_thinking"] as? Bool == true)
        #expect(ReasoningMode.discard.templateContext?["enable_thinking"] as? Bool == true)
    }
}
