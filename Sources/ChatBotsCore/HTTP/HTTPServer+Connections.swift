// ChatBotsCore — one accepted connection, from admission to close
//
// Split out of `HTTPServer.swift`, which held the server's configuration and lifecycle next to the
// per-connection work it does. This is the life of a single socket: admission against the connection
// cap, the idle deadline that drops a silent peer, accumulating a whole request, handing it to the main
// actor, writing the answer and reaping the connection afterwards. The code did not change.

import Foundation
import Network

extension HTTPServer {

    /// Internal rather than private: `start()` in `HTTPServer.swift` installs this as the listener's
    /// `newConnectionHandler`, so it is the one entry point into the per-connection work.
    func accept(_ connection: NWConnection) {
        stateLock.lock()
        let atCapacity = connections.count >= maximumConnections
        if atCapacity {
            refusals += 1
        } else {
            connections[ObjectIdentifier(connection)] = connection
        }
        stateLock.unlock()

        connection.start(queue: queue)
        guard !atCapacity else {
            note("refused: \(maximumConnections) connections already open")
            // Refused rather than queued, and refused with an answer rather than silence: a
            // peer over the cap is told, and the connection is not entered in the table.
            write(
                .error("the server is at its connection limit", status: 503), to: connection,
                thenClose: true)
            return
        }
        armRequestDeadlines(for: connection)
        receive(on: connection, buffer: Data())
    }

    /// Arm the idle deadline and the whole-request wall-clock deadline for a new connection.
    ///
    /// Two timers because one is not enough: the idle deadline is re-armed by every chunk, so a
    /// peer that trickles one byte just inside it never trips it; the wall-clock one is armed
    /// here and never replaced, so it ends that connection however slowly it drips.
    private func armRequestDeadlines(for connection: NWConnection) {
        armIdleDeadline(for: connection)

        let token = UUID()
        stateLock.lock()
        totalDeadlines[ObjectIdentifier(connection)] = token
        stateLock.unlock()
        queue.asyncAfter(deadline: .now() + maximumRequestDuration) { [weak self] in
            self?.totalDeadlineFired(for: connection, token: token)
        }
    }

    /// Start, or restart, the idle deadline for a connection whose request is not complete.
    ///
    /// The token replaces any previous one, so the earlier deadline — if it has not fired
    /// already — finds itself stale and does nothing. It is not cancelled, because a dispatch
    /// work item cannot be cancelled once it is executing anyway and a stale one costs a UUID
    /// comparison.
    private func armIdleDeadline(for connection: NWConnection) {
        let token = UUID()
        stateLock.lock()
        idleDeadlines[ObjectIdentifier(connection)] = token
        stateLock.unlock()

        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            self?.idleDeadlineFired(for: connection, token: token)
        }
    }

    /// The connection's request has been read in full; it is no longer idle, and its
    /// wall-clock deadline no longer applies.
    private func disarmRequestDeadlines(for connection: NWConnection) {
        stateLock.lock()
        idleDeadlines[ObjectIdentifier(connection)] = nil
        totalDeadlines[ObjectIdentifier(connection)] = nil
        stateLock.unlock()
    }

    /// Drop a connection whose request did not arrive in time.
    private func idleDeadlineFired(for connection: NWConnection, token: UUID) {
        stateLock.lock()
        let isCurrent = idleDeadlines[ObjectIdentifier(connection)] == token
        let isLive = connections[ObjectIdentifier(connection)] != nil
        if isCurrent { idleDeadlines[ObjectIdentifier(connection)] = nil }
        stateLock.unlock()

        // Stale token, or the connection has already been answered or reaped: nothing to do.
        guard isCurrent, isLive else { return }
        note("request: not completed in time")
        write(
            .error("the request was not completed in time", status: 408), to: connection,
            thenClose: true)
    }

    /// Drop a connection whose request has been open longer than the wall-clock allowance.
    ///
    /// This is what a trickling peer trips: it resets the idle deadline with every byte, so the
    /// only bound on how long it can hold a slot is this one.
    private func totalDeadlineFired(for connection: NWConnection, token: UUID) {
        stateLock.lock()
        let isCurrent = totalDeadlines[ObjectIdentifier(connection)] == token
        let isLive = connections[ObjectIdentifier(connection)] != nil
        if isCurrent { totalDeadlines[ObjectIdentifier(connection)] = nil }
        stateLock.unlock()

        guard isCurrent, isLive else { return }
        note("request: open longer than the wall-clock allowance")
        write(
            .error("the request took too long to send", status: 408), to: connection,
            thenClose: true)
    }

    /// Accumulate until a whole request has arrived, then answer it.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 64 * 1024
        ) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.finish(connection, error: error)
                return
            }

            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }

            if accumulated.isEmpty, isComplete {
                self.finish(connection, error: nil)
                return
            }

            do {
                let request = try HTTPParser.parse(accumulated)
                // The request is complete, so the connection is no longer idle. This is what
                // lets an event stream stay open past `requestTimeout`: the deadline covers
                // reading the request, not the conversation the connection is kept for.
                self.disarmRequestDeadlines(for: connection)
                self.respond(to: request, on: connection)
            } catch is HTTPParser.Incomplete {
                if isComplete {
                    // The peer closed mid-request; nothing useful to send.
                    self.note("request: the peer closed before the request was complete")
                    self.finish(connection, error: nil)
                } else if accumulated.count > HTTPParser.maximumHeadBytes
                    + HTTPParser.maximumBodyBytes
                {
                    // Head plus body, because a head that has not terminated is counted here too and the
                    // head has its own cap inside `parse`.
                    self.note("request: larger than the head and body limits")
                    self.write(
                        .error("Request body is too large", status: 413), to: connection,
                        thenClose: true)
                } else {
                    // Progress restarts the idle clock; a client that sends nothing does not.
                    if chunk != nil { self.armIdleDeadline(for: connection) }
                    self.receive(on: connection, buffer: accumulated)
                }
            } catch let error as HTTPError {
                // The parser refused it: a malformed head, a head or body past its cap, a request line it
                // cannot read. Answered with its own status and, now, remembered.
                self.note("request: \(error.localizedDescription)")
                self.write(
                    .error(error.localizedDescription, status: error.statusCode), to: connection,
                    thenClose: true)
            } catch {
                // Anything else, which the caller sees as a 400. Recorded too: the failures worth reading are
                // the ones nobody wrote a status code for.
                self.note("request: \(error.localizedDescription)")
                self.write(
                    .error(error.localizedDescription, status: 400), to: connection, thenClose: true)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        // A stream owns the connection from here: the response head goes out immediately and
        // the socket stays open, which is what makes server-sent events work.
        // Everything below hops to the main actor rather than assuming it: this runs on the
        // network queue, and `assumeIsolated` from there traps. The consequence is that
        // handlers run on the main actor, which is what lets them use a `@MainActor` engine
        // without any locking.
        Task { @MainActor [weak self] in
            guard let self else { return }

            if request.method == "GET", let streamer = self.streamer {
                let stream = EventStream(connection: connection)
                let initial = streamer(request, stream)
                if !initial.isEmpty {
                    // Appended under `stateLock`, like every other access to `streams`.
                    //
                    // This said "no lock: `streams` is only ever touched on the main actor", and
                    // that was never true: `stop()` and `finish()` mutate the same array under the
                    // lock, and `finish()` runs on the network queue. Appending here without it is a
                    // concurrent mutation of a Swift array — the kind that corrupts or crashes
                    // rather than merely reporting a stale value.
                    self.addStream(stream)
                    // Head first, then the opening events, then the socket is left open —
                    // which is what makes server-sent events work. The head comes from the same
                    // response type every other route answers with, so it carries the same security
                    // headers; it used to be assembled here by hand, without any of them.
                    connection.send(
                        content: HTTPResponse.eventStream().streamingHead(),
                        completion: .contentProcessed { _ in })
                    for payload in initial { stream.send(payload, event: "snapshot") }
                    // The connection stays open, so it still has to be watched: this is the
                    // only place that learns the client has gone, and `finish` is the only code
                    // that prunes the stream and the connection. This used to return here, so
                    // `finish` could never run for a streaming connection, `isOpen` stayed true,
                    // `removeAll { !$0.isOpen }` never removed anything, and every page reload
                    // or dropped client left an `EventStream` and an `NWConnection` retained for
                    // the life of the process while the server kept broadcasting to a dead
                    // socket.
                    self.awaitClose(on: connection)
                    return
                }
            }

            let response = await self.handler(request)
            self.write(response, to: connection, thenClose: true)
        }
    }

    private func write(_ response: HTTPResponse, to connection: NWConnection, thenClose: Bool) {
        let data = response.serialised(keepAlive: !thenClose)
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                if thenClose { self.finish(connection, error: nil) }
            })
    }

    /// Wait for a client the server is streaming to, to go away.
    ///
    /// The request has already been answered, so anything the client sends is ignored: this
    /// exists only so the closure is observed and `finish` — the sole pruning path — can run.
    /// `finish` cancels the connection, which ends this read too, so it is not re-armed after
    /// it fires; a keep-alive byte from a client that has nothing to say re-arms the wait rather
    /// than ending the stream.
    private func awaitClose(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 4 * 1024
        ) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.finish(connection, error: error)
            } else {
                self.awaitClose(on: connection)
            }
        }
    }

    private func finish(_ connection: NWConnection, error: NWError?) {
        if let error {
            // Not worth *showing* anyone — a client that walks away mid-request is routine — but worth
            // recording once, because "the connection keeps dropping" is not diagnosable otherwise. The
            // ring is bounded, so routine noise cannot grow.
            note("connection: \(error)")
        }
        stateLock.lock()
        connections[ObjectIdentifier(connection)] = nil
        idleDeadlines[ObjectIdentifier(connection)] = nil
        totalDeadlines[ObjectIdentifier(connection)] = nil
        for stream in streams where stream.matches(connection) { stream.markClosed() }
        streams.removeAll { !$0.isOpen }
        stateLock.unlock()
        connection.cancel()
    }
}
