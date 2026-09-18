// ChatBotsCore — reading the engine's stream on the client side
//
// Split out of `WebTransportClient.swift`, which held the session, the request path and the frame
// reader in one 584-line file. The reader did not change; only the file it lives in did.

import Foundation
import WebTransportNetworkRuntime

extension WebTransportEngineClient {

    /// The frame a payload carries, or nil — recorded — when this build cannot read it.
    ///
    /// Internal so a test can hand it a payload no decoder reads and see what the client does with it,
    /// which is the only way to reach this path without a peer that speaks a different protocol.
    func decodedFrame(_ payload: Data) -> EngineFrame? {
        do {
            return try ProtocolCodec.decodeFrame(payload)
        } catch {
            unreadableFrames += 1
            lastUnreadableFrame = error.localizedDescription
            return nil
        }
    }

    /// Read frames until the stream ends, routing each to its destination.
    ///
    /// Every path checks the reader generation before touching shared state. A reader is
    /// cancelled cooperatively, so one suspended in `receive()` can wake after `teardown()` has
    /// installed the next session's continuations; without the check it would `failReader` the
    /// new session with the old one's error.
    func read(from stream: WebTransportNetworkBidirectionalStream) async {
        let generation = readerGeneration
        var buffer = Data()
        while true {
            if Task.isCancelled || generation != readerGeneration { return }
            let chunk: Data
            do {
                chunk = try await stream.receive()
            } catch {
                guard generation == readerGeneration else { return }
                failReader(error.localizedDescription)
                return
            }
            guard generation == readerGeneration else { return }
            if chunk.isEmpty {
                failReader(readerError ?? "the engine closed the stream")
                return
            }
            buffer.append(chunk)
            guard readBufferedFrames(from: &buffer, generation: generation) else { return }
        }
    }

    /// Read every whole frame currently buffered, routing each to its destination. `false`
    /// means the reader has stopped and the caller must return.
    private func readBufferedFrames(from buffer: inout Data, generation: Int) -> Bool {
        while true {
            guard generation == readerGeneration else { return false }
            let result: LengthFraming.ReadResult
            do {
                result = try LengthFraming.read(from: buffer)
            } catch let error as ProtocolError {
                // The length prefix is the only thing that says where the next frame
                // begins, so a refused frame cannot be skipped and every later frame is
                // unreachable. Stop the reader with the reason rather than looping on a
                // buffer that will never advance — which is what the discarded `try?` did,
                // leaving a client that was connected, silent and useless.
                failReader(error.errorDescription ?? "a frame was refused")
                return false
            } catch {
                failReader(error.localizedDescription)
                return false
            }
            guard case .message(let payload, let remainder) = result else { return true }
            buffer = remainder
            guard let frame = decodedFrame(payload) else { continue }
            guard deliver(frame) else { return false }
        }
    }

    /// Route one decoded frame. `false` means the reader has stopped.
    private func deliver(_ frame: EngineFrame) -> Bool {
        switch frame {
        case .reply(let reply):
            return deliver(reply)
        case .event(let event):
            eventContinuation?.yield(event)
            return true
        case .request:
            // Only the engine answers requests; a client receiving one is a
            // misdirected frame.
            return true
        }
    }

    /// Hand one reply to the request it answers. `false` means the reader has stopped.
    private func deliver(_ reply: EngineReply) -> Bool {
        // Matched to the request, not to the position. The slot held by the sender
        // means the head of the queue is the request the engine is answering.
        guard let pending = pendingReplies.first else {
            // No request can be waiting for this. A protocol the client cannot
            // misalign — one request, one reply, in order — so the only honest
            // reading is that the frame order is no longer trustworthy.
            failReader("a reply arrived when no request was outstanding")
            return false
        }
        pendingReplies.removeFirst()
        if pending.abandoned {
            // The sender gave up waiting, so its reply is still owed and is being
            // consumed here. That is what keeps the next request's reply next.
            return true
        }
        guard Self.reply(reply, answers: pending.request) else {
            failReader(
                "the engine answered \(Self.name(of: pending.request)) with "
                    + Self.name(of: reply))
            return false
        }
        pending.continuation.yield(reply)
        return true
    }

    /// Whether `reply` can be the answer to `request`.
    ///
    /// The wire has no correlation id, so the request is the only identity available and this
    /// is the one check the reply itself supports. `EngineService`'s answers are known exactly:
    /// `.refused` and `.failed` can follow any request, `.state` is the generic answer to most
    /// commands, and the reads that have their own reply case are never answered by a state
    /// snapshot. A snapshot arriving while one of them is outstanding is a misdelivered reply
    /// and is reported as one rather than handed over.
    private static func reply(_ reply: EngineReply, answers request: EngineRequest) -> Bool {
        switch reply {
        case .refused, .failed:
            return true
        case .state:
            return stateAnswers(request)
        case .report:
            return isReportRequest(request)
        case .savedConversations:
            // Both of the saved-conversation commands answer with the list.
            return isSavedConversationRequest(request)
        case .rosters:
            return isRosterRequest(request)
        case .scenarios:
            return isScenarioRequest(request)
        case .identified:
            return isIdentifyRequest(request)
        }
    }

    /// `.state` is the generic answer to most commands; the reads that have their own reply
    /// case are never answered by a state snapshot.
    private static func stateAnswers(_ request: EngineRequest) -> Bool {
        switch request {
        case .fetchReport, .listSavedConversations, .deleteSavedConversation, .listRosters,
            .listScenarios:
            return false
        default:
            return true
        }
    }

    private static func isReportRequest(_ request: EngineRequest) -> Bool {
        if case .fetchReport = request { return true }
        return false
    }

    private static func isSavedConversationRequest(_ request: EngineRequest) -> Bool {
        switch request {
        case .listSavedConversations, .deleteSavedConversation: return true
        default: return false
        }
    }

    private static func isRosterRequest(_ request: EngineRequest) -> Bool {
        if case .listRosters = request { return true }
        return false
    }

    private static func isScenarioRequest(_ request: EngineRequest) -> Bool {
        if case .listScenarios = request { return true }
        return false
    }

    private static func isIdentifyRequest(_ request: EngineRequest) -> Bool {
        if case .identify = request { return true }
        return false
    }

    /// How a frame is named in a mismatch, so the failure says what crossed with what.
    private static func name(of request: EngineRequest) -> String {
        switch request {
        case .fetchReport: return "a report request"
        case .listSavedConversations: return "a saved-conversation list request"
        case .deleteSavedConversation: return "a delete-conversation request"
        case .listRosters: return "a line-up request"
        case .listScenarios: return "a scenario request"
        default: return "the outstanding request"
        }
    }

    /// How a reply is named in a mismatch.
    private static func name(of reply: EngineReply) -> String {
        switch reply {
        case .state: return "a state snapshot"
        case .report: return "a report"
        case .savedConversations: return "a saved-conversation list"
        case .rosters: return "a line-up list"
        case .scenarios: return "a scenario list"
        case .identified: return "an identity token"
        case .refused: return "a refusal"
        case .failed: return "a failure"
        }
    }

    /// End the reader with a reason, and wake anything waiting on it immediately.
    ///
    /// A waiting `send` learns the reason now rather than at its own timeout, and the event
    /// stream ends, so "the connection is dead" is a sentence the caller can read instead of a
    /// wait that eventually gives up.
    private func failReader(_ reason: String) {
        readerError = reason
        for reply in pendingReplies { reply.continuation.finish() }
        eventContinuation?.finish()
    }
}
