// ChatBotsCore — the feed the API pushes to every connected client
//
// Split out of `APIServer.swift`, which held the routes, the request-to-command translation and this
// push feed in one file. A request is the client asking; this is the other direction — the snapshot a
// new connection is handed, the per-turn transcript feed, the per-token delta feed, and the frame
// envelopes they are encoded into. The code did not change.

import Foundation

extension APIServer {

    // MARK: - Events

    /// Internal rather than private: `start()` in `APIServer.swift` installs this as the streamer for
    /// `/api/events`.
    func subscribe(_ stream: HTTPServer.EventStream) -> [String] {
        streams.append(stream)
        streams.removeAll { !$0.isOpen }
        // A fresh connection is handed the current state immediately, so a page that has
        // just loaded, or reloaded, does not have to wait for the next turn to see anything.
        // It is returned rather than sent so the server can put the response head first.
        return [encode(service.snapshot()) ?? "{}"]
    }

    /// One task per connection, writing each new turn as it is published.
    ///
    /// Internal rather than private: `start()` in `APIServer.swift` starts it once the listener is up.
    func startFeed() {
        feedTask?.cancel()
        feedTask = Task { [weak self] in
            guard let self else { return }
            // The high-water mark of the sequence numbers already sent, not every id ever seen: the
            // set that used to be here kept one UUID per turn for the life of the process, and
            // `transcriptUpdates` hands over the whole log each time, so the sequence that is
            // already the transcript's own ordering is enough. A log whose highest sequence is
            // below the mark belongs to a new conversation — `reset` and `newConversation` clear
            // the transcript and numbering starts again — so the mark restarts with it.
            var lastSequence = 0
            for await turns in self.engine.transcriptUpdates {
                if Task.isCancelled { return }
                if (turns.map(\.sequence).max() ?? 0) < lastSequence { lastSequence = 0 }
                for turn in turns where turn.sequence > lastSequence {
                    lastSequence = max(lastSequence, turn.sequence)
                    self.broadcast(
                        self.encode(MessageEnvelope(turn: turn)) ?? "{}", event: "turn")
                }
                self.broadcast(self.encode(self.service.snapshot()) ?? "{}", event: "snapshot")
            }
        }
        startTokenFeed()
    }

    /// Stream the model's output as it is written.
    ///
    /// The snapshot feed alone is not enough for a client that wants to show a reply being
    /// written: it fires once per turn, so the text would appear in whole answers rather than
    /// arriving as it is produced. This carries the engine's own per-token events instead.
    ///
    /// Deliberately a small payload — an id and a fragment — rather than a fresh snapshot per
    /// token. A snapshot is a few kilobytes and a turn can produce thousands of tokens;
    /// broadcasting one per token would drown the connection in its own status.
    ///
    /// The reasoning stream is carried too, so a client can show the thinking blocks the
    /// desktop app shows.
    private func startTokenFeed() {
        // Watched rather than read from the stream, because the WebTransport server forwards
        // the same events to the desktop app and an `AsyncStream` would give the whole
        // sequence to one of them and nothing to the other.
        tokenObserver = service.observeEvents { [weak self] event in
            guard let self else { return }
            switch event {
            case .token(let agentID, let text):
                self.broadcast(
                    self.encode(APISnapshot.OutputDelta(agentID: agentID, text: text, kind: "token")) ?? "{}",
                    event: "delta")
            case .reasoning(let agentID, let text):
                self.broadcast(
                    self.encode(APISnapshot.OutputDelta(agentID: agentID, text: text, kind: "reasoning")) ?? "{}",
                    event: "delta")
            case .toolCall(let agentID, let name, let query):
                self.broadcast(
                    self.encode(
                        APISnapshot.OutputDelta(
                            agentID: agentID, text: "\(name)(\(query))", kind: "tool")) ?? "{}",
                    event: "delta")
            case .turnStarted(let agentID, _):
                self.broadcast(
                    self.encode(APISnapshot.OutputDelta(agentID: agentID, text: "", kind: "started")) ?? "{}",
                    event: "delta")
            default:
                // Everything else is reflected in the snapshot that follows the turn.
                break
            }
        }
    }
    private struct MessageEnvelope: Encodable {
        var turn: APISnapshot.Message

        init(turn: Turn) {
            self.turn = APISnapshot.Message(
                id: turn.id.uuidString,
                sequence: turn.sequence,
                speaker: turn.speakerName,
                speakerID: turn.speakerID,
                kind: turn.kind.rawValue,
                text: turn.content,
                timestamp: turn.timestamp,
                toolDetail: turn.toolDetail
            )
        }
    }

    private func broadcast(_ payload: String, event: String? = nil) {
        streams.removeAll { !$0.isOpen }
        for stream in streams { stream.send(payload, event: event) }
    }
}
