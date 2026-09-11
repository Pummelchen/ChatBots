// ChatBotsCore — the wire protocol between an interface and the engine
//
// The desktop app talks to the engine over WebTransport rather than holding it in-process.
// That means the two need an agreed format for what they say to each other, and this file is
// it: the message types, and the framing that puts them on a byte stream.
//
// Kept separate from the transport on purpose. The framing rules — how a message is
// delimited, what happens when a read lands mid-message — are the part that goes wrong
// silently, and they can be tested exhaustively with no socket, no certificate and no QUIC.
// The WebTransport layer above this only has to move bytes.
//
// **Two channels, because they have different shapes.**
//
//   · A *request* channel carries one command at a time and one reply per command. Each
//     message is length-prefixed, because a command body can contain newlines — a topic, a
//     pasted question — and a delimiter would split it in the wrong place.
//   · An *event* channel carries a stream of updates with no replies. Here newline-delimited
//     JSON is right: events are frequent and small, and the delimiter costs less than a
//     length prefix on every one. JSON encoders never emit a bare newline inside a string, so
//     the delimiter cannot be forged by the payload.
//
// Both are strict about the same thing: a partial message is never guessed at. Bytes are
// buffered until the message is complete, so a read that lands inside a frame is held rather
// than misparsed.

import Foundation

/// A request from an interface to the engine.
///
/// One case per thing the interface can ask for. Deliberately a closed set rather than a
/// route string: a typo in a route fails at runtime somewhere in the engine, and a typo in an
/// enum case fails to compile.
public enum EngineRequest: Sendable, Hashable, Codable {
    case start
    case pause
    case resume
    case stop
    case reset
    case compact
    case setTopic(String)
    case steer(String)
    case setShowReasoning(Bool)
    case setMode(DiscussionMode)
    case setResearchBudget(ResearchBudget.Depth)
    /// One seat's configuration. Only the fields set are changed.
    case updateSeat(SeatChange)
    case addAttachment(filename: String, contents: Data)
    case removeAttachment(id: String)
    case clearAttachments
    /// Just the current state, for a client that wants it without waiting for the stream.
    case fetchState
    /// The finished research report, as markdown.
    case fetchReport

    /// A partial seat change, so the sender says what it means to alter rather than sending a
    /// whole seat back and relying on the receiver to notice what differs.
    public struct SeatChange: Sendable, Hashable, Codable {
        public var seatID: String
        public var name: String?
        public var personaID: String?
        public var thinking: ThinkingMode?
        public var backend: AgentSpec.Backend?
        public var baseURL: String?
        public var apiModel: String?
        public var apiKey: String?

        public init(
            seatID: String,
            name: String? = nil,
            personaID: String? = nil,
            thinking: ThinkingMode? = nil,
            backend: AgentSpec.Backend? = nil,
            baseURL: String? = nil,
            apiModel: String? = nil,
            apiKey: String? = nil
        ) {
            self.seatID = seatID
            self.name = name
            self.personaID = personaID
            self.thinking = thinking
            self.backend = backend
            self.baseURL = baseURL
            self.apiModel = apiModel
            self.apiKey = apiKey
        }
    }
}

/// The engine's answer to a command.
public enum EngineReply: Sendable, Codable {
    /// The state after the command, which every command returns.
    case state(APISnapshot)
    /// A report, for `fetchReport`.
    case report(String)
    /// The command was understood and refused. Distinct from a transport failure: "the topic
    /// cannot be changed once the conversation has started" is an answer, not an error.
    case refused(String)

    public var snapshot: APISnapshot? {
        if case .state(let snapshot) = self { return snapshot }
        return nil
    }
}

/// Something the engine tells interfaces about, without being asked.
public enum EngineEvent: Sendable, Codable {
    /// The whole state after a change. The basis of everything a client draws.
    case state(APISnapshot)
    /// A fragment of a model's output, as it is produced.
    case output(APISnapshot.OutputDelta)
}

/// The largest single message either side will accept.
///
/// A guard, not a limit anyone should meet: the largest legitimate message is a state
/// snapshot with a long transcript, or an uploaded document. Refusing something absurd is
/// better than buffering until memory runs out.
public enum ProtocolLimits {
    /// 32 MB. A generous multiple of the largest attachment the engine accepts.
    public static let maximumMessageBytes = 32 * 1024 * 1024
}

// MARK: - Framing

/// Length-prefixed framing, for the request channel.
///
/// A message is a big-endian `UInt32` length followed by that many bytes of JSON. The length
/// comes first so a reader knows how much to wait for, and there is no delimiter to escape.
public enum LengthFraming {

    /// Wrap an encoded message.
    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    /// What a read produced.
    public enum ReadResult: Sendable {
        /// A whole message, plus whatever followed it.
        case message(Data, remainder: Data)
        /// Not enough bytes yet. The caller keeps the buffer and reads again.
        case incomplete
    }

    /// Take one message off the front of a buffer, if a whole one is there.
    ///
    /// Returns the remainder rather than mutating a buffer the caller owns, so a caller cannot
    /// lose bytes by forgetting to consume them.
    public static func read(from buffer: Data) throws -> ReadResult {
        guard buffer.count >= 4 else { return .incomplete }
        let length = buffer.prefix(4).withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
        }
        guard length <= ProtocolLimits.maximumMessageBytes else {
            throw ProtocolError.messageTooLarge(Int(length))
        }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return .incomplete }
        let payload = buffer[buffer.index(buffer.startIndex, offsetBy: 4)..<buffer.index(buffer.startIndex, offsetBy: total)]
        let remainder = buffer[buffer.index(buffer.startIndex, offsetBy: total)...]
        return .message(Data(payload), remainder: Data(remainder))
    }
}

/// Newline-delimited framing, for the event channel.
///
/// JSON encoders escape newlines inside strings, so a bare newline can only be a delimiter —
/// the payload cannot forge one.
public enum LineFraming {

    public static func frame(_ payload: Data) -> Data {
        var out = payload
        out.append(UInt8(ascii: "\n"))
        return out
    }

    /// Every complete line in the buffer, and whatever tail is still partial.
    ///
    /// The tail is returned rather than dropped: it is the beginning of a message whose end
    /// has not arrived, and discarding it would lose that message silently.
    public static func read(from buffer: Data) -> (messages: [Data], remainder: Data) {
        var messages: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
            if newline > start {
                messages.append(Data(buffer[start..<newline]))
            }
            start = buffer.index(after: newline)
        }
        return (messages, Data(buffer[start...]))
    }
}

public enum ProtocolError: LocalizedError, Equatable {
    case messageTooLarge(Int)
    case cannotEncode(String)
    case cannotDecode(String)

    public var errorDescription: String? {
        switch self {
        case .messageTooLarge(let size):
            "A message of \(size) bytes was refused; the limit is \(ProtocolLimits.maximumMessageBytes)."
        case .cannotEncode(let detail): "Could not encode the message: \(detail)"
        case .cannotDecode(let detail): "Could not decode the message: \(detail)"
        }
    }
}

// MARK: - Encoding

/// The codec both sides share.
///
/// One place, so the two ends cannot disagree about how a message is spelled.
public enum ProtocolCodec {

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted so an encoded message is stable, which makes a wire capture diffable.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ request: EngineRequest) throws -> Data {
        try wrap { try encoder.encode(request) }
    }

    public static func decodeRequest(_ data: Data) throws -> EngineRequest {
        try unwrap { try decoder.decode(EngineRequest.self, from: data) }
    }

    public static func encode(_ reply: EngineReply) throws -> Data {
        try wrap { try encoder.encode(reply) }
    }

    public static func decodeReply(_ data: Data) throws -> EngineReply {
        try unwrap { try decoder.decode(EngineReply.self, from: data) }
    }

    public static func encode(_ event: EngineEvent) throws -> Data {
        try wrap { try encoder.encode(event) }
    }

    public static func decodeEvent(_ data: Data) throws -> EngineEvent {
        try unwrap { try decoder.decode(EngineEvent.self, from: data) }
    }

    private static func wrap(_ body: () throws -> Data) throws -> Data {
        do {
            return try body()
        } catch {
            throw ProtocolError.cannotEncode(error.localizedDescription)
        }
    }

    private static func unwrap<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw ProtocolError.cannotDecode(error.localizedDescription)
        }
    }
}
