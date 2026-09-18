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
    func readEventStream(
        _ bytes: URLSession.AsyncBytes,
        into continuation: AsyncThrowingStream<OpenAIStreamEvent, Error>.Continuation
    ) async throws {
        var sawCompleted = false
        // An explicit failure is already the answer; it is reported as `.failed` and the caller
        // turns it into the thrown error. It must not also produce the truncation error below,
        // which would replace the server's own reason with a less useful one.
        var sawFailure = false
        var utf8 = UTF8StreamBuffer()
        // Labelled so a terminal event can end the read, not merely the `switch` it is decoded
        // in. A `break` inside a case only leaves the case.
        //
        // Lines are accumulated by hand rather than with `bytes.lines`, which buffers a whole
        // line before yielding it: `maximumEventLineBytes` bounds that, and a longer line is
        // refused with a reason rather than truncated, because a truncated event is not one this
        // client can act on.
        var lineBytes: [UInt8] = []
        var lineTooLong = false
        readLoop: for try await byte in bytes {
            try Task.checkCancellation()
            if byte != UInt8(ascii: "\n") {
                if lineBytes.count < Self.maximumEventLineBytes {
                    lineBytes.append(byte)
                } else {
                    lineTooLong = true
                }
                continue
            }
            let lineBytesForThisLine = lineBytes
            lineBytes.removeAll(keepingCapacity: true)
            if lineTooLong {
                lineTooLong = false
                sawFailure = true
                continuation.yield(.failed("the stream carried an event line that was too long"))
                break readLoop
            }
            guard let line = String(bytes: lineBytesForThisLine, encoding: .utf8) else {
                // The API speaks UTF-8. A line that is not is a protocol violation, and skipping
                // it silently is how a truncated answer looked complete.
                sawFailure = true
                continuation.yield(.failed("the stream carried a line that was not UTF-8"))
                break readLoop
            }
            guard let payload = Self.dataPayload(from: line) else { continue }
            if payload == "[DONE]" { break }
            guard
                let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                    as? [String: Any]
            else {
                // The Responses API's `data:` payloads are JSON. A line that is not is a
                // protocol violation, and dropping it silently meant a stream could lose
                // events and still finish with a well-formed `response.completed`, so a
                // partial answer was indistinguishable from a whole one.
                sawFailure = true
                continuation.yield(.failed("the stream carried an event that could not be read"))
                break readLoop
            }

            let type = event["type"] as? String ?? ""
            switch type {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String, !delta.isEmpty {
                    // Through the buffer: a chunk may end mid-character.
                    let safe = utf8.append(delta)
                    if !safe.isEmpty {
                        continuation.yield(.text(safe))
                    }
                }

            case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
                if let delta = event["delta"] as? String, !delta.isEmpty {
                    continuation.yield(.reasoning(delta))
                }

            case "response.completed", "response.done":
                // A response can complete having produced no text at all when the model
                // only reasoned or only called a tool; the caller decides what that means.
                sawCompleted = true
                continuation.yield(.completed(Self.usage(from: event)))

            case "response.failed", "response.incomplete":
                let message = Self.failureMessage(from: event)
                sawFailure = true
                continuation.yield(.failed(message))
                // The server has already given its answer, so the read ends here. Without this
                // the loop went back for a connection a server may hold open, and the turn
                // stayed alive until the 600-second request timeout — ten minutes of waiting for
                // a failure that was reported at once. It is also what concludes a stream that
                // reports failure and then sends nothing: a missing terminal event is a failure
                // the reader must act on rather than wait out.
                break readLoop

            case "error":
                sawFailure = true
                continuation.yield(.failed(Self.failureMessage(from: event)))
                break readLoop

            default:
                break
            }
        }

        let tail = utf8.flush()
        if !tail.isEmpty { continuation.yield(.text(tail)) }

        // Truncated: the stream ended without the server ever saying it completed. Whatever
        // text arrived is a fragment, and reporting it as a finished turn would record a
        // `stop` with zero usage — the token statistics silently become 0, and a half answer is
        // indistinguishable from a whole one. Throwing is what makes the caller's normal
        // error handling report the turn as failed instead.
        if !sawCompleted, !sawFailure {
            throw OpenAIResponsesError.streamFailed(
                "the connection ended before the response completed, so the reply is incomplete")
        }
    }
}
