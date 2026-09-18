// ChatBotsCore — reading an OpenAI-compatible SSE response
//
// Split out of `OpenAIResponsesClient.swift`, which had grown past the repository's 500-line
// limit when the event-line cap was added. This is the whole of "turn a byte stream of `data:`
// frames into `OpenAIStreamEvent`s"; the request, its URL and its trace stay in the client.

import Foundation

extension OpenAIResponsesClient {

    /// Read `bytes` as an event stream, yielding each event, and enforce completion.
    ///
    /// A completed response is the only thing that counts as success (see the client's header).
    /// The loop can end at EOF or at `data: [DONE]`, and either can happen mid-stream when a
    /// connection drops, a proxy truncates, or a server is killed — so "the bytes stopped" is
    /// not evidence that the turn finished. `sawCompleted` is what separates the two.
    ///
    /// The decoding itself lives in `EventStreamDecoder`, one byte at a time; this function is
    /// only the loop around it.
    func readEventStream(
        _ bytes: URLSession.AsyncBytes,
        into continuation: AsyncThrowingStream<OpenAIStreamEvent, Error>.Continuation
    ) async throws {
        var decoder = EventStreamDecoder()
        readLoop: for try await byte in bytes {
            try Task.checkCancellation()
            if decoder.consume(byte, into: continuation) { break readLoop }
        }
        decoder.flush(into: continuation)
        try decoder.throwIfTruncated()
    }

    /// Turns a byte stream into SSE events, holding the state the read loop used to keep.
    ///
    /// Pulled out of `readEventStream` because line assembly, JSON decoding and the per-event
    /// switch together put that function over its `cyclomatic_complexity` budget. Splitting it
    /// this way also puts "which event types are terminal" in one place.
    private struct EventStreamDecoder {

        /// The server said the response completed.
        private var sawCompleted = false
        /// A failure was already reported, so truncation must not also be reported.
        private var sawFailure = false
        private var utf8 = OpenAIResponsesClient.UTF8StreamBuffer()
        private var lineBytes: [UInt8] = []
        private var lineTooLong = false

        /// Feed one byte. Returns true when the read should stop.
        ///
        /// Lines are accumulated by hand rather than with `bytes.lines`, which buffers a whole
        /// line before yielding it: `maximumEventLineBytes` bounds that, and a longer line is
        /// refused with a reason rather than truncated, because a truncated event is not one this
        /// client can act on.
        mutating func consume(
            _ byte: UInt8,
            into continuation: AsyncThrowingStream<OpenAIStreamEvent, Error>.Continuation
        ) -> Bool {
            guard byte == UInt8(ascii: "\n") else {
                append(byte)
                return false
            }
            if lineTooLong {
                return report(
                    "the stream carried an event line that was too long", into: continuation)
            }
            let lineBytesForThisLine = lineBytes
            lineBytes.removeAll(keepingCapacity: true)
            guard let line = String(bytes: lineBytesForThisLine, encoding: .utf8) else {
                // The API speaks UTF-8. A line that is not is a protocol violation, and skipping
                // it silently is how a truncated answer looked complete.
                return report("the stream carried a line that was not UTF-8", into: continuation)
            }
            return decode(line, into: continuation)
        }

        /// Emit whatever the UTF-8 buffer still holds when the stream ends.
        ///
        /// Called after the loop, whether it stopped at `[DONE]`, at a failure or at EOF, which
        /// is what the read loop did when this state was local to it.
        mutating func flush(
            into continuation: AsyncThrowingStream<OpenAIStreamEvent, Error>.Continuation
        ) {
            let tail = utf8.flush()
            if !tail.isEmpty { continuation.yield(.text(tail)) }
        }

        /// Throw when the stream ended without the server ever saying it completed.
        ///
        /// Whatever text arrived is a fragment, and reporting it as a finished turn would record
        /// a `stop` with zero usage — the token statistics silently become 0, and a half answer
        /// is indistinguishable from a whole one. Throwing is what makes the caller's normal
        /// error handling report the turn as failed instead.
        func throwIfTruncated() throws {
            guard sawCompleted || sawFailure else {
                throw OpenAIResponsesError.streamFailed(
                    "the connection ended before the response completed, so the reply is incomplete")
            }
        }

        private mutating func append(_ byte: UInt8) {
            if lineBytes.count < OpenAIResponsesClient.maximumEventLineBytes {
                lineBytes.append(byte)
            } else {
                lineTooLong = true
            }
        }

        /// Record a failure and ask the caller to stop. The message becomes the `.failed` event.
        private mutating func report(
            _ message: String,
            into continuation: AsyncThrowingStream<OpenAIStreamEvent, Error>.Continuation
        ) -> Bool {
            sawFailure = true
            continuation.yield(.failed(message))
            return true
        }

        /// One complete line: a `data:` payload is decoded, anything else is skipped.
        private mutating func decode(
            _ line: String,
            into continuation: AsyncThrowingStream<OpenAIStreamEvent, Error>.Continuation
        ) -> Bool {
            guard let payload = OpenAIResponsesClient.dataPayload(from: line) else { return false }
            // Labelled so a terminal event can end the read, not merely the `switch` it is
            // decoded in. A `break` inside a case only leaves the case.
            if payload == "[DONE]" { return true }
            guard
                let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                    as? [String: Any]
            else {
                // The Responses API's `data:` payloads are JSON. A line that is not is a
                // protocol violation, and dropping it silently meant a stream could lose
                // events and still finish with a well-formed `response.completed`, so a
                // partial answer was indistinguishable from a whole one.
                return report(
                    "the stream carried an event that could not be read", into: continuation)
            }
            return handle(event, into: continuation)
        }

        /// Apply one decoded event. Returns true when the read should stop.
        private mutating func handle(
            _ event: [String: Any],
            into continuation: AsyncThrowingStream<OpenAIStreamEvent, Error>.Continuation
        ) -> Bool {
            switch EventKind(type: event["type"] as? String ?? "") {
            case .textDelta:
                yieldTextDelta(event, into: continuation)
            case .reasoningDelta:
                yieldReasoningDelta(event, into: continuation)
            case .completed:
                // A response can complete having produced no text at all when the model
                // only reasoned or only called a tool; the caller decides what that means.
                sawCompleted = true
                continuation.yield(.completed(OpenAIResponsesClient.usage(from: event)))
            case .failure:
                // The server has already given its answer, so the read ends here. Without this
                // the loop went back for a connection a server may hold open, and the turn
                // stayed alive until the 600-second request timeout — ten minutes of waiting for
                // a failure that was reported at once. It is also what concludes a stream that
                // reports failure and then sends nothing: a missing terminal event is a failure
                // the reader must act on rather than wait out.
                return report(
                    OpenAIResponsesClient.failureMessage(from: event), into: continuation)
            case .ignored:
                break
            }
            return false
        }

        private mutating func yieldTextDelta(
            _ event: [String: Any],
            into continuation: AsyncThrowingStream<OpenAIStreamEvent, Error>.Continuation
        ) {
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return }
            // Through the buffer: a chunk may end mid-character.
            let safe = utf8.append(delta)
            if !safe.isEmpty {
                continuation.yield(.text(safe))
            }
        }

        private mutating func yieldReasoningDelta(
            _ event: [String: Any],
            into continuation: AsyncThrowingStream<OpenAIStreamEvent, Error>.Continuation
        ) {
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return }
            continuation.yield(.reasoning(delta))
        }
    }

    /// The event's `type`, mapped to the handful of kinds this client acts on.
    ///
    /// The three event names that mean failure, and the two that mean completion, are the
    /// same answer here, so the switch in `EventStreamDecoder.handle` has one case per
    /// behaviour rather than one per name.
    private enum EventKind {
        case textDelta
        case reasoningDelta
        case completed
        case failure
        case ignored

        init(type: String) {
            switch type {
            case "response.output_text.delta": self = .textDelta
            case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
                self = .reasoningDelta
            case "response.completed", "response.done": self = .completed
            case "response.failed", "response.incomplete", "error": self = .failure
            default: self = .ignored
            }
        }
    }
}
