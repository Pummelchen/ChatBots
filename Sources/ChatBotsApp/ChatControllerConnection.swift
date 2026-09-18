// ChatBotsApp — the controller's link to the engine
//
// `ChatController` shows what an engine running in another process is doing, and this is the
// half that reaches it: making the connection, drawing from its event feed, polling as a
// safety net, and saying why a connection could not be made. Kept apart from the state the
// rest of the controller publishes, so "where the app talks to the engine" is one file.

import ChatBotsCore
import Foundation

@MainActor
extension ChatController {

    /// Attach to an engine and start drawing from it.
    ///
    /// Called once the supervisor reports an engine answering. Everything the interface shows
    /// comes from here: the transcript, the status, the seat settings, the statistics and the
    /// streamed output.
    public func connect(host: String = "127.0.0.1", port: UInt16) async {
        disconnect()

        var configuration = WebTransportEngineClient.Configuration()
        configuration.host = host
        configuration.port = port
        let client = WebTransportEngineClient(configuration: configuration)

        // The event stream delivers states and output fragments; it is started before the
        // first request so nothing that happens in between is missed.
        var lastError: String?
        for attempt in 0..<8 {
            do {
                try await client.connect()
                lastError = nil
                break
            } catch {
                lastError = error.localizedDescription
                // Cancellation stops the retry: `try?` swallowed it, so the remaining attempts
                // ran back to back with no delay and could still install the client — and start
                // its pumps — after the view was gone.
                if Task.isCancelled { return }
                do {
                    try await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
                } catch {
                    return
                }
            }
        }
        guard !Task.isCancelled else { return }
        guard client.isConnected else {
            // A client that never connected is not a connection, so it is not stored: `client != nil`
            // has to keep meaning "there is an engine to talk to". Storing it meant the seat endpoints
            // were pushed through it, every one of those commands answered with a transport failure,
            // and each failure replaced the reason the connection had actually failed with a symptom
            // of it — before the banner that shows the reason was ever read.
            noteConnectionFailed(lastError ?? "Could not reach the engine.")
            return
        }
        self.client = client
        engineConnection = nil

        // The current state first, so the interface is correct before any event arrives.
        if let snapshot = try? await client.state() {
            apply(snapshot)
        }
        // Then what this app knows that the engine does not: a freshly started engine has the
        // default moderator, and the user's own name and persona live in this app's settings.
        if !restoredModerator.isDefault {
            _ = try? await client.send(.setModerator(restoredModerator))
            if let snapshot = try? await client.state() { apply(snapshot) }
        }
        startPumps()

        // A safety net, not the primary path.
        //
        // Pushed states should arrive whenever the log changes, and they are what keeps the
        // transcript live. But a push that silently fails leaves a window that looks
        // connected and never updates — the worst kind of failure, because nothing is
        // obviously wrong. Polling is cheap here (one small request a second on loopback) and
        // it turns that into a slow refresh rather than a frozen window.
        pumpTasks.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    // The poll's reply is the one snapshot whose arrival order relative to the
                    // push feed is not the engine's order: it can be produced before a push the
                    // pump applies while the request is in flight. The engine's revision orders
                    // them, so `apply` would refuse the older one anyway; this in-flight check
                    // is the belt to that braces, and it costs one integer comparison. Pushes are
                    // the primary path and the poll exists for a push feed that has gone quiet,
                    // so dropping a poll the engine has already superseded costs nothing.
                    let appliedBefore = self.appliedSnapshotCount
                    if let snapshot = try? await client.state(),
                        self.appliedSnapshotCount == appliedBefore
                    {
                        self.apply(snapshot)
                    }
                    // A reader that stopped is why the window would otherwise never update.
                    // This also carries the client's explicit failure for a reply it could not
                    // match, which the `try?` above would otherwise swallow. Once the
                    // reader has gone, every later poll repeats the same sentence, so stop.
                    if let error = client.readerError {
                        self.engineConnection = "Live updates stopped: \(error)"
                        return
                    }
                }
            }
        )
    }

    /// Stop drawing from the engine. The engine itself is the supervisor's business.
    public func disconnect() {
        for task in pumpTasks { task.cancel() }
        pumpTasks.removeAll()
        if let client {
            Task { await client.disconnect() }
        }
        client = nil
    }

    /// Record a connection that could not be made: the reason, and no client.
    ///
    /// The failure half of `connect`, in one place so that "a client that never connected is not a
    /// connection" is stated once rather than implied by the order of two assignments. Being a
    /// method also means the failure path — which the whole finding is about — can be driven without
    /// waiting out eight real connect attempts.
    func noteConnectionFailed(_ reason: String) {
        client = nil
        engineConnection = reason
    }

    /// Dismiss the connection notice once it has been read.
    public func clearConnectionMessage() { engineConnection = nil }
}
