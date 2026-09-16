// ChatBotsCoreTests — the wire protocol between an interface and the engine
//
// The framing rules are the part that goes wrong silently: a read that lands mid-message
// either blocks forever or truncates without complaining. These tests exercise the byte-level
// edges directly, which is possible because the framing is separate from the transport.

import ChatBotsCore
import Foundation
import Testing

@Suite("Length-prefixed framing")
struct LengthFramingTests {

    private func framed(_ text: String) -> Data {
        LengthFraming.frame(Data(text.utf8))
    }

    @Test("A frame round-trips")
    func roundTrip() throws {
        let payload = Data(#"{"hello":"world"}"#.utf8)
        let framed = LengthFraming.frame(payload)
        let result = try LengthFraming.read(from: framed)
        guard case .message(let message, let remainder) = result else {
            Issue.record("expected a whole message")
            return
        }
        #expect(message == payload)
        #expect(remainder.isEmpty)
    }

    @Test("The length is big-endian and precedes the payload")
    func layout() {
        let framed = framed("abc")
        #expect(framed.count == 4 + 3)
        // 3 in big-endian is 00 00 00 03 — a little-endian writer would put 03 last.
        #expect(Array(framed.prefix(4)) == [0x00, 0x00, 0x00, 0x03])
        #expect(Array(framed.suffix(3)) == Array("abc".utf8))
    }

    @Test("An empty buffer is incomplete, not an error")
    func emptyIsIncomplete() throws {
        guard case .incomplete = try LengthFraming.read(from: Data()) else {
            Issue.record("an empty buffer should be incomplete")
            return
        }
    }

    @Test("A partial header is incomplete")
    func partialHeader() throws {
        for count in 1...3 {
            let buffer = framed("hello").prefix(count)
            guard case .incomplete = try LengthFraming.read(from: Data(buffer)) else {
                Issue.record("\(count) bytes of header should be incomplete")
                return
            }
        }
    }

    @Test("A partial payload is incomplete, and none of it is lost")
    func partialPayload() throws {
        let full = framed("hello world")
        // Everything except the last byte.
        let partial = full.dropLast()
        guard case .incomplete = try LengthFraming.read(from: Data(partial)) else {
            Issue.record("a short payload should be incomplete")
            return
        }
        // Completing it yields the whole message: nothing was consumed by the failed read.
        guard case .message(let message, _) = try LengthFraming.read(from: full) else {
            Issue.record("expected a message once complete")
            return
        }
        #expect(String(decoding: message, as: UTF8.self) == "hello world")
    }

    @Test("Two frames in one buffer yield the first and the remainder")
    func twoFrames() throws {
        // The normal case on a stream: several messages arrive in one read.
        var buffer = framed("first")
        buffer.append(framed("second"))

        guard case .message(let first, let remainder) = try LengthFraming.read(from: buffer) else {
            Issue.record("expected a message")
            return
        }
        #expect(String(decoding: first, as: UTF8.self) == "first")

        guard case .message(let second, let rest) = try LengthFraming.read(from: remainder) else {
            Issue.record("expected the second message")
            return
        }
        #expect(String(decoding: second, as: UTF8.self) == "second")
        #expect(rest.isEmpty)
    }

    @Test("A message containing a newline survives, which is why length prefixes are used")
    func newlinesInPayload() throws {
        // A topic or a pasted question can contain newlines. With a delimiter instead of a
        // length this would split in the wrong place.
        let payload = Data("line one\nline two\n\nline four".utf8)
        let result = try LengthFraming.read(from: LengthFraming.frame(payload))
        guard case .message(let message, _) = result else {
            Issue.record("expected a message")
            return
        }
        #expect(message == payload)
    }

    @Test("An absurd length is refused rather than buffered")
    func oversizedIsRefused() {
        // A corrupt or hostile length must not make the reader allocate gigabytes.
        var buffer = Data()
        var length = UInt32(ProtocolLimits.maximumMessageBytes + 1).bigEndian
        buffer.append(Data(bytes: &length, count: 4))
        #expect(throws: ProtocolError.self) {
            _ = try LengthFraming.read(from: buffer)
        }
    }

    @Test("A message of exactly the limit is accepted")
    func exactlyTheLimit() throws {
        // The boundary is where an off-by-one lives.
        var buffer = Data()
        var length = UInt32(ProtocolLimits.maximumMessageBytes).bigEndian
        buffer.append(Data(bytes: &length, count: 4))
        buffer.append(Data(repeating: 0x41, count: ProtocolLimits.maximumMessageBytes))
        guard case .message(let message, _) = try LengthFraming.read(from: buffer) else {
            Issue.record("a message at the limit should be accepted")
            return
        }
        #expect(message.count == ProtocolLimits.maximumMessageBytes)
    }

    @Test("A sender refuses a message over the cap rather than framing it")
    func checkedFramingRefusesOversize() {
        // The frame is not put on the wire at all: its length prefix would say where the next
        // frame begins, so a receiver that refuses it can never read past it. The error names
        // the size and the limit instead.
        let over = Data(count: ProtocolLimits.maximumMessageBytes + 1)
        do {
            _ = try LengthFraming.frameChecked(over)
            Issue.record("an over-cap message should be refused at the sender")
        } catch let error as ProtocolError {
            #expect(error == .messageTooLarge(ProtocolLimits.maximumMessageBytes + 1))
            #expect(
                error.errorDescription?.contains("\(ProtocolLimits.maximumMessageBytes)") == true)
        } catch {
            Issue.record("expected a ProtocolError, got \(error)")
        }
    }

    @Test("An attachment at the engine's own size limit fits the wire cap")
    func largestAttachmentIsAccepted() throws {
        // This is the reconciliation, exercised rather than declared: the documented attachment
        // limit has to become a message the cap accepts, or the limit is a claim the transport
        // refuses. It was 64 MB against a 32 MB message cap, so a legitimate attachment over
        // roughly 24 MB could never be sent.
        let contents = Data(
            repeating: 0x41, count: AttachmentLimits.defaultMaximumFileBytes)
        let framed = try LengthFraming.frameChecked(
            try ProtocolCodec.encode(
                EngineRequest.addAttachment(filename: "largest.txt", contents: contents)))

        guard case .message(let payload, let remainder) = try LengthFraming.read(from: framed) else {
            Issue.record("the largest legitimate message should be readable")
            return
        }
        #expect(payload.count <= ProtocolLimits.maximumMessageBytes)
        #expect(remainder.isEmpty)
        // And it really is the largest attachment, not a smaller stand-in.
        let decoded = try ProtocolCodec.decodeRequest(payload)
        guard case .addAttachment(_, let decodedContents) = decoded else {
            Issue.record("expected the attachment request back")
            return
        }
        #expect(decodedContents.count == AttachmentLimits.defaultMaximumFileBytes)
    }

    @Test("The three size limits are derived from one place")
    func limitsAreDerivedFromTheAttachmentLimit() {
        let attachment = AttachmentLimits.defaultMaximumFileBytes
        let base64 =
            (attachment * ProtocolLimits.base64Numerator + ProtocolLimits.base64Denominator - 1)
            / ProtocolLimits.base64Denominator
        // The message cap covers the base64 form and the JSON around it.
        #expect(ProtocolLimits.maximumMessageBytes >= base64 + ProtocolLimits.envelopeOverheadBytes)
        // The HTTP body is the same request, so it carries the same budget.
        #expect(HTTPParser.maximumBodyBytes == ProtocolLimits.maximumMessageBytes)
        // And the shipped limits are the ones the derivation names.
        #expect(AttachmentLimits.standard.maximumFileBytes == attachment)
    }
}

@Suite("Protocol messages")
struct ProtocolMessageTests {

    @Test("Every request survives a round trip")
    func requestsRoundTrip() throws {
        // Including the ones carrying data: a document, a topic with newlines, a seat change.
        let requests: [EngineRequest] = [
            .start, .pause, .resume, .stop, .reset, .compact, .fetchState, .fetchReport,
            .setTopic("Why are eggs not oval?\nSeriously."),
            .steer("Stay on the shell question."),
            .setShowReasoning(false),
            .setMode(.research),
            .setResearchBudget(.deep),
            .updateSeat(
                .init(
                    seatID: "Agent 1", name: "Mira", personaID: "villain",
                    thinking: .high, backend: .openAIResponses,
                    baseURL: "https://api.deepseek.com/v1", apiModel: "deepseek-v4-flash")),
            .addAttachment(filename: "paper.pdf", contents: Data([0x25, 0x50, 0x44, 0x46])),
            .removeAttachment(id: "5E3A"),
            .clearAttachments,
        ]
        for request in requests {
            let data = try ProtocolCodec.encode(request)
            #expect(try ProtocolCodec.decodeRequest(data) == request)
        }
    }

    @Test("A seat change carries only what was asked for")
    func seatChangeIsPartial() throws {
        // The point of a partial change: a nil field means "leave it", not "set it to nil", so
        // renaming a seat cannot silently reset its persona.
        let change = EngineRequest.SeatChange(seatID: "Agent 2", name: "Otto")
        let decoded = try ProtocolCodec.decodeRequest(
            try ProtocolCodec.encode(EngineRequest.updateSeat(change)))
        guard case .updateSeat(let seat) = decoded else {
            Issue.record("expected a seat change")
            return
        }
        #expect(seat.name == "Otto")
        #expect(seat.personaID == nil)
        #expect(seat.thinking == nil)
        #expect(seat.backend == nil)
    }

    @Test("A refusal is an answer, not a transport failure")
    func refusalIsDistinct() throws {
        let reply = EngineReply.refused("the topic cannot be changed once the conversation has started")
        let decoded = try ProtocolCodec.decodeReply(try ProtocolCodec.encode(reply))
        guard case .refused(let reason) = decoded else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("cannot be changed"))
        #expect(decoded.snapshot == nil)
    }

    @Test("An event round-trips, including a streamed fragment")
    func eventsRoundTrip() throws {
        let event = EngineEvent.output(
            .init(agentID: "Agent 1", text: "a fragment", kind: "token"))
        let decoded = try ProtocolCodec.decodeEvent(try ProtocolCodec.encode(event))
        guard case .output(let delta) = decoded else {
            Issue.record("expected an output event")
            return
        }
        #expect(delta.agentID == "Agent 1")
        #expect(delta.text == "a fragment")
        #expect(delta.isOutput)
    }

    @Test("Encoding is stable, so a wire capture can be diffed")
    func encodingIsDeterministic() throws {
        let request = EngineRequest.updateSeat(
            .init(seatID: "Agent 1", name: "Mira", thinking: .low))
        #expect(try ProtocolCodec.encode(request) == (try ProtocolCodec.encode(request)))
    }

    @Test("Garbage is reported as a decode failure, not a crash")
    func garbageIsRejected() {
        #expect(throws: ProtocolError.self) {
            _ = try ProtocolCodec.decodeRequest(Data("not json".utf8))
        }
    }

    @Test("A message survives the round trip through both framings")
    func endToEndFraming() throws {
        // What the transport actually does: encode, frame, split across two reads, decode.
        let request = EngineRequest.setTopic("A topic with a\nnewline and ünïcode 🥚")
        let framed = LengthFraming.frame(try ProtocolCodec.encode(request))

        let firstHalf = framed.prefix(framed.count / 2)
        let secondHalf = framed.suffix(framed.count - firstHalf.count)

        var buffer = Data()
        buffer.append(contentsOf: firstHalf)
        guard case .incomplete = try LengthFraming.read(from: buffer) else {
            Issue.record("half a frame should be incomplete")
            return
        }
        buffer.append(contentsOf: secondHalf)
        guard case .message(let payload, _) = try LengthFraming.read(from: buffer) else {
            Issue.record("the completed frame should be readable")
            return
        }
        #expect(try ProtocolCodec.decodeRequest(payload) == request)
    }

    @Test("An event stream split mid-character reassembles")
    func splitMidCharacter() throws {
        // A multi-byte character can straddle a read boundary. The framing holds the partial
        // bytes rather than decoding them, which is what stops a replacement character.
        let event = EngineEvent.output(.init(agentID: "A", text: "Grüße 🥚", kind: "token"))
        let framed = LengthFraming.frame(try ProtocolCodec.encode(event))

        var buffer = Data()
        var decoded: [EngineEvent] = []
        for byte in framed {
            buffer.append(byte)
            // One byte at a time: most reads are `.incomplete`, and the one that completes the
            // frame is the one that decodes it.
            guard case .message(let payload, let remainder) = try LengthFraming.read(from: buffer)
            else { continue }
            buffer = remainder
            decoded.append(try ProtocolCodec.decodeEvent(payload))
        }
        #expect(decoded.count == 1)
        guard case .output(let delta) = decoded[0] else {
            Issue.record("expected an output event")
            return
        }
        #expect(delta.text == "Grüße 🥚")
        #expect(!delta.text.contains("\u{FFFD}"))
    }
}
