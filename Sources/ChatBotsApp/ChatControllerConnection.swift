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
        let lastError = await connectWithRetries(client)
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

        // What this app knows and the engine does not, sent *before* the engine's state is applied.
        //
        // The order is the whole point: `apply` copies the engine's backend into the panes, so
        // applying first replaced the user's stored choice with the engine's default and left this
        // hand-over comparing against its own clobbered copy. It then "corrected" the checkpoint of a
        // seat the user had put on an API — making the engine rebuild and load local weights for a
        // seat that was never going to use them, which is minutes of loading and no progress on
        // screen — and never sent the backend at all. A freshly started engine has the default
        // moderator too, and that is the other thing this side knows.
        await handOverStoredSeatConfiguration(client)
        if !restoredModerator.isDefault {
            _ = try? await client.send(.setModerator(restoredModerator))
        }
        // Then the current state, so the interface is correct before any event arrives.
        if let snapshot = try? await client.state() {
            apply(snapshot)
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

    /// Hand the engine the seat configuration this app has stored.
    ///
    /// A seat's backend and checkpoint live in this app's settings, and the engine is launched on
    /// its own defaults, so unless they are sent the seat runs the default while the interface draws
    /// the user's choice — the mismatch `setModel` exists to prevent on a click. The backend is sent
    /// first and on its own account: without it a seat the user had switched to an API is silently
    /// returned to the local engine, which is the same defect one field over, and the one that made
    /// "Use API" appear to switch itself off.
    ///
    /// This must run before the caller applies a snapshot (see `connect`), because it compares the
    /// panes with what the engine reports and `apply` overwrites the panes with the engine's own
    /// values. A refusal is left where the engine put it: `deliver` puts the reason in
    /// `engineConnection`, and the caller's single `apply` then shows what is really set.
    private func handOverStoredSeatConfiguration(_ client: WebTransportEngineClient) async {
        guard let snapshot = try? await client.state() else { return }
        let models = Dictionary(
            snapshot.seats.map { ($0.id, $0.model) }, uniquingKeysWith: { first, _ in first })
        let backends = Dictionary(
            snapshot.seats.map { ($0.id, $0.backend) }, uniquingKeysWith: { first, _ in first })
        for change in Self.storedSeatChanges(
            stored: panes.map(\.spec), engineModels: models, engineBackends: backends)
        {
            let request: EngineRequest
            switch change {
            case .backend(let seatID, let backend):
                request = .updateSeat(.init(seatID: seatID, backend: backend))
            case .model(let seatID, let modelID):
                request = .updateSeat(.init(seatID: seatID, modelID: modelID))
            }
            // The reply is not used to re-read the state here: the caller applies one snapshot once
            // every request has gone out, so a refusal becomes the engine's truth instead of a second
            // round trip that could land before the moderator's.
            await deliver(request)
        }
        // The output ceiling is sent for every seat rather than compared, because a snapshot does not
        // carry it: the app is the only side that knows it, and a freshly started engine has none. A
        // seat with no ceiling stores nil and sends `0`, which is how "leave this alone" is told apart
        // from "off" on the wire.
        for spec in panes.map(\.spec) {
            await deliver(
                .updateSeat(
                    .init(
                        seatID: spec.id,
                        maximumTokensPerSecond: spec.maximumTokensPerSecond ?? 0)))
        }
    }

    /// One seat setting this app has stored that the engine is not running.
    enum StoredSeatChange: Equatable {
        case backend(seatID: String, backend: AgentSpec.Backend)
        case model(seatID: String, modelID: String)
    }

    /// The seat settings whose stored value is not the one the engine reports.
    ///
    /// Separated from the sending so the rule can be tested without a socket, and deliberately
    /// narrow: only a seat that really differs is returned, because changing a seat makes the engine
    /// release the old weights and load new ones, so a launch that would change nothing must ask for
    /// nothing. A local checkpoint is never handed to an API-backed seat — the field is meaningless
    /// there and the engine would try to load it.
    static func storedSeatChanges(
        stored: [AgentSpec],
        engineModels: [String: String],
        engineBackends: [String: String]
    ) -> [StoredSeatChange] {
        var changes: [StoredSeatChange] = []
        for spec in stored {
            // Which engine a seat uses comes first: it decides whether the checkpoint beside it
            // means anything at all.
            if let running = engineBackends[spec.id],
                AgentSpec.Backend(rawValue: running) != spec.backend
            {
                changes.append(.backend(seatID: spec.id, backend: spec.backend))
            }
            guard spec.backend == .mlx, let running = engineModels[spec.id] else { continue }
            let wanted = ModelCatalog.resolve(spec.modelID)
            guard !wanted.isEmpty, wanted != running else { continue }
            changes.append(.model(seatID: spec.id, modelID: wanted))
        }
        return changes
    }

    /// Try to connect eight times with a growing delay, returning the last error.
    ///
    /// Extracted so `connect` stays inside its complexity budget, and because the retry and its
    /// cancellation rule are one thing: a closed window must stop the loop rather than run the
    /// remaining attempts back to back — `try?` swallowed the CancellationError, so the delay
    /// vanished and the client could still be installed, with its pumps running, after the view
    /// was gone.
    private func connectWithRetries(_ client: WebTransportEngineClient) async -> String? {
        var lastError: String?
        for attempt in 0..<8 {
            do {
                try await client.connect()
                return nil
            } catch {
                lastError = error.localizedDescription
                if Task.isCancelled { return lastError }
                do {
                    try await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
                } catch {
                    return lastError
                }
            }
        }
        return lastError
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
