// ChatBotsCore — serving one accepted session, from stream to close
//
// Split out of `WebTransportServer.swift`, which held the listener, the live sessions and the event
// pumps in one 548-line file. Serving a session did not change; only the file it lives in did.

import Foundation
import WebTransport
import WebTransportNetworkRuntime

extension WebTransportEngineServer {

    // MARK: - Sessions

    func serve(_ session: WebTransportSession, id: UUID) async {
        // Every exit from this method deregisters the session, and closes it only if this task
        // still owns it. That ownership test is what gives the session exactly one closer:
        // `stop()` removes the entries before it closes anything, so a task ending during or
        // after a stop finds its entry gone and leaves the close to `stop()`; a task ending on
        // its own removes the entry itself and is the one that closes. Without it both would
        // close, sending the final capsule twice.
        defer {
            subscribers[id] = nil
            spokenSessions.remove(id)
            let stillOwned = sessions.removeValue(forKey: id) != nil
            sessionTasks[id] = nil
            if stillOwned {
                Task { try? await session.close() }
            }
        }

        // The deadline for a session to become one. It covers the stream being opened *and* the first frame
        // arriving, because a client that does neither has never asked for anything and is holding a slot
        // the engine could be using. `spokenSessions` is what the watchdog reads, and both it and
        // this loop are on the main actor, so there is no lock between them.
        let startupTimeout = Duration.seconds(configuration.sessionStartupTimeout)
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: startupTimeout)
            guard !Task.isCancelled, let self, !self.spokenSessions.contains(id) else { return }
            let seconds = Int(self.configuration.sessionStartupTimeout)
            let reason = "the session did not finish a frame within \(seconds) seconds"
            self.note(reason)
            // The session is taken out of `sessions` before it is closed, exactly as the `defer`
            // below does: the `defer` closes only what it still owns, and the library's `close()`
            // must not be called twice.
            if self.sessions.removeValue(forKey: id) != nil {
                try? await session.close(reason: reason)
            }
        }
        defer { watchdog.cancel() }

        // One stream, and that is not a simplification for its own sake: the transport
        // serialises stream operations on a session, and a second bidirectional stream does
        // not open. A single stream carrying tagged frames avoids both the deadlock and the
        // limitation. See EngineProtocol for the full account.
        let stream: WebTransportBidirectionalStream
        do {
            stream = try await session.acceptBidirectionalStream()
        } catch {
            // The failure used to be discarded by `try?`, so a session that could never open its
            // stream ended with no recorded reason — `recentSessionErrors` stayed empty and the
            // end was indistinguishable from a clean close. Every neighbouring refusal records
            // one.
            note("the session could not open its stream: \(error.localizedDescription)")
            return
        }

        // This session is subscribed the moment its stream exists.
        //
        // There was a separate subscription step — the server waited to accept a second
        // stream before sending anything — and it was the reason the desktop app showed a
        // conversation that never updated. Nothing ever opened that second stream, so the
        // server waited forever while the client waited for events, and the only thing that
        // eventually moved the window was the polling safety net. Since replies and events are
        // told apart by their frame tag, no negotiation is needed at all.
        let (events, continuation) = AsyncStream<EngineEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(ProtocolLimits.eventBufferDepth))
        subscribers[id] = continuation
        let writer = Task { [weak self] in
            guard let self else { return }
            for await event in events {
                if Task.isCancelled { return }
                await self.send(.event(event), on: stream)
            }
        }
        defer {
            writer.cancel()
            continuation.finish()
        }

        // The current state first, so a client that has just connected can draw something
        // without waiting for a change.
        await send(.event(.state(service.snapshot())), on: stream)

        var buffer = Data()
        // What this session holds from the server's buffered-frame budget. It is given back as the
        // buffer is consumed and on every exit, so the budget is a bound on live buffers rather
        // than on sessions ever seen.
        var reserved = 0
        defer { releaseFrameBytes(reserved) }
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await stream.receive()
            } catch {
                note("the session ended: \(error.localizedDescription)")
                return
            }
            if chunk.isEmpty { return }
            guard reserveFrameBytes(chunk.count) else {
                note("an incomplete frame would exceed the buffered-frame budget")
                return
            }
            reserved += chunk.count
            buffer.append(chunk)

            // Several frames can arrive together and one can be split across reads; the
            // framing holds partial messages until they are complete.
            while true {
                let result: LengthFraming.ReadResult
                do {
                    result = try LengthFraming.read(from: buffer)
                } catch {
                    // A frame the framing refuses cannot be skipped, so this ends the session; the reasons
                    // are unwound in `refuseFraming` because this function is at its complexity budget.
                    await refuseFraming(error, on: stream, session: session, id: id)
                    return
                }
                guard case .message(let payload, let remainder) = result else { break }
                let consumed = buffer.count - remainder.count
                releaseFrameBytes(consumed)
                reserved -= consumed
                buffer = remainder
                // A whole frame, so the session is a conversation rather than a client that sent a byte and
                // stopped: the startup deadline no longer applies to it. It is *bytes* that make the server
                // serve a session — measured, one byte is enough to hold an admission slot and receive the
                // state pushes — so the deadline has to cover the frame being finished, not the first byte
                // arriving.
                spokenSessions.insert(id)
                await answer(payload, on: stream)
            }
        }
    }

    /// Answer one decoded payload.
    ///
    /// Extracted from `serve`, which is at its complexity and length budgets: three of its four branches are
    /// about a payload the server cannot read, and they read better together than inside the read loop.
    private func answer(_ payload: Data, on stream: WebTransportBidirectionalStream) async {
        do {
            let request = try ProtocolCodec.decodeRequest(payload)
            let reply = await service.handle(request)
            await send(.reply(reply), on: stream)
        } catch let error as ProtocolError {
            // A client may tag its frames too; accept both spellings so the encoder is not something a caller
            // has to get exactly right.
            if let request = (try? ProtocolCodec.decodeFrame(payload))?.asRequest {
                let reply = await service.handle(request)
                await send(.reply(reply), on: stream)
                return
            }
            // Neither spelling read it. Unlike the framing refusal above, the length prefix is intact, so
            // later frames are still reachable and the session is still usable — but a client waiting for a
            // reply must not be left waiting for one that will never come. This was a `try?` that dropped the
            // payload and said nothing at all.
            let reason = error.errorDescription ?? "the frame could not be read"
            note(reason)
            await send(.reply(.failed(reason)), on: stream)
        } catch {
            // `decodeRequest` reports a refusal as `ProtocolError`; anything else is a defect, and it is named
            // rather than dropped, which is the whole of this branch's reason for existing.
            let reason = "the frame could not be read: \(error.localizedDescription)"
            note(reason)
            await send(.reply(.failed(reason)), on: stream)
        }
    }

    /// Refuse a frame the framing would not read, and end the session.
    ///
    /// The length prefix is the only thing that says where the next frame begins, so every later frame is
    /// unreachable: the session cannot be left running, and it is answered first so the client is told why.
    /// This was a `try?`, which discarded the error and left a session that answered nothing for the rest of
    /// its life — and the cap was low enough that a legitimate large attachment reached it.
    private func refuseFraming(
        _ error: Error, on stream: WebTransportBidirectionalStream, session: WebTransportSession,
        id: UUID
    ) async {
        let reason =
            (error as? ProtocolError)?.errorDescription
            ?? "the frame could not be read: \(error.localizedDescription)"
        note(reason)
        await send(.reply(.failed(reason)), on: stream)
        // Ownership is taken before the close, for the same reason the watchdog takes it: the
        // `defer` in `serve` closes only what is still in `sessions`, and `close()` must not be
        // called twice.
        if sessions.removeValue(forKey: id) != nil {
            try? await session.close(reason: reason)
        }
    }

    /// Write one frame. Every write goes through here so there is one place that serialises
    /// them: replies and events reach the same stream from different tasks, and interleaving
    /// two writes would corrupt the framing.
    ///
    /// A frame the receiver would refuse is not put on the wire at all: framing it would put a
    /// length prefix before bytes that will never be read as a message, and the error names the
    /// size where it was made instead. `lastSessionError` carries the reason.
    private func send(_ frame: EngineFrame, on stream: WebTransportBidirectionalStream) async {
        let encoded: Data
        do {
            encoded = try ProtocolCodec.encode(frame)
        } catch {
            note("could not encode a frame: \(error.localizedDescription)")
            return
        }
        let framed: Data
        do {
            framed = try LengthFraming.frameChecked(encoded)
        } catch {
            note("could not frame a reply: \(error.localizedDescription)")
            return
        }
        do {
            try await stream.send(framed)
        } catch {
            // The client is gone; the reader will notice and end the session.
        }
    }
}
