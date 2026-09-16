// ChatBotsCoreTests — the core's dead declarations are gone or wired
//
// A pass over the core found six declarations that were written or named but never used:
// `ConflictState.positions` and `notePosition`, which recorded a seat's own account of where it stood
// "so a later reversal can be noticed" while nothing ever read them; `leadingSeat`, used only by a
// test although its comment said several characters aim at it; `quietestSeatIgnoring(settledQuestions:)`,
// which never read the parameter its name promised a rule about; `OpenAIResponsesEngine.lastError`,
// written twice and read never; and `HTTPServer.closeStreams()`, which documented a reset path that
// never called it. The same scan found `ResearchDirection.isDirected`, used by four assertions and no
// production code.
//
// What was for something is wired and what was not is gone. `leadingSeat` is the wired one — the
// personas are told to aim at "whoever is currently winning", and the seat that phrase names is now
// stated in the brief — and this file holds both halves: the behaviour of that line, and the absence
// of the declarations that had no consumer at all, with counterweights for the parts that must stay
// (the beats, the stream cleanup on stop, the failure report, the quietest-seat rule).

import Foundation
import Testing

@testable import ChatBotsCore

@Suite("The core's dead declarations are gone or wired")
struct CoreDeadDeclarationTests {

    /// A file in this package, for a property only its text can show.
    private func text(of path: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ChatBotsCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
            .appending(path: path)
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Every Swift source in `Sources/`, so a declaration that moves house is still seen.
    private func sources() -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources")
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return walk.compactMap { entry in
            guard let name = entry as? String, name.hasSuffix(".swift") else { return nil }
            let url = root.appending(path: name)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (name, source)
        }
    }

    /// A conflict state in which each named seat has won a beat.
    private func state(beatsWonBy winners: [String], first: AgentSpec, second: AgentSpec) -> ConflictState {
        var conflict = ConflictState()
        for (index, winner) in winners.enumerated() {
            let target = winner == first.id ? second.id : first.id
            conflict.apply(
                signals: [TurnSignal(kind: .concession, confidence: 1.0, target: target)],
                from: winner, others: [first.id, second.id], sequence: index + 1, summary: nil)
        }
        return conflict
    }

    @Test("The brief names the seat the room rates highest")
    func theBriefNamesTheLeader() {
        let first = AgentSpec.seat(index: 0)
        let second = AgentSpec.seat(index: 1)
        let conflict = state(beatsWonBy: [first.id], first: first, second: second)

        // From the seat that is behind: the leader is named, because an id means nothing to a model.
        let behind = PromptBuilder.socialContext(
            for: second, others: [first], conversation: Conversation(topic: "T", conflict: conflict))
        #expect(behind?.contains("Right now the room rates \(first.displayName) highest.") == true)

        // From the seat that is ahead: told "you" rather than its own name.
        let ahead = PromptBuilder.socialContext(
            for: first, others: [second], conversation: Conversation(topic: "T", conflict: conflict))
        #expect(ahead?.contains("Right now the room rates you highest.") == true)
    }

    @Test("A level room is given no leader, and the beats still reach the prompt")
    func aLevelRoomHasNoLeader() {
        let first = AgentSpec.seat(index: 0)
        let second = AgentSpec.seat(index: 1)
        let conflict = state(beatsWonBy: [first.id, second.id], first: first, second: second)

        let brief = PromptBuilder.socialContext(
            for: second, others: [first], conversation: Conversation(topic: "T", conflict: conflict))
        // The counterweight: the brief is there, and it is the *leader* line that is absent. A rule
        // that named a seat from a level room would be the "pick someone at random" failure.
        #expect(brief?.contains("What has just happened:") == true)
        #expect(brief?.contains("Right now the room rates") == false)
    }

    @Test("The declarations the finding named are not in the sources")
    func theDeadDeclarationsAreGone() throws {
        let all = sources().map(\.1).joined(separator: "\n")
        #expect(sources().count > 20, "the walk found only \(sources().count) files")
        // Declaration-shaped, not bare names: the comments that explain why each one went name them,
        // and a scan that could not tell a comment from a declaration would forbid saying so.
        for declaration in [
            "func notePosition",
            "var positions:",
            "func closeStreams",
            "var isDirected",
            "func quietestSeatIgnoring",
        ] {
            #expect(!all.contains(declaration), "Sources/ still declares \(declaration)")
        }
        let engine = try text(of: "Sources/ChatBotsCore/OpenAI/OpenAIResponsesEngine.swift")
        #expect(!engine.contains("lastError"), "the write-only lastError is back")
    }

    @Test("What those declarations were for is still there (the counterweights)")
    func theUsefulPartsRemain() throws {
        let conflict = try text(of: "Sources/ChatBotsCore/Conversation/ConflictState.swift")
        let http = try text(of: "Sources/ChatBotsCore/HTTP/HTTPServer.swift")
        let engine = try text(of: "Sources/ChatBotsCore/OpenAI/OpenAIResponsesEngine.swift")
        let director = try text(of: "Sources/ChatBotsCore/Research/ResearchDirector.swift")
        let prompt = try text(of: "Sources/ChatBotsCore/Prompt/PromptBuilder.swift")
        #expect(conflict.contains("beatsWon"), "the beats the leader is judged on are gone")
        #expect(
            http.contains("streams.removeAll"),
            "stopping the server no longer drops the streams it was holding")
        #expect(
            engine.contains("onStateChange(.failed"),
            "a failed load is no longer reported to the caller")
        #expect(
            director.contains("quietestSeat()"),
            "the quietest-seat rule lost its caller instead of its unused parameter")
        #expect(
            prompt.contains("conversation.conflict.leadingSeat"),
            "leadingSeat is not wired into the brief")
    }
}
