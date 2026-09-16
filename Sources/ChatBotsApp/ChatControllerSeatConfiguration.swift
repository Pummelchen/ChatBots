// ChatBotsApp — what each seat is, and which engine it uses
//
// One place for every change to a seat: its name, its style, its thinking level, the backend
// it answers through and the checkpoint or endpoint behind that. They are grouped because
// they share one rule — the pane is only ever changed from what the engine accepted, never
// from the click — and because the API switch rewrites all of them at once.

import ChatBotsCore
import Foundation

@MainActor
extension ChatController {

    /// Rename a seat.
    ///
    /// The name is what the moderator sees, what the transcript is tagged with, and what
    /// the *models* are told each participant is called. The seat's internal id is
    /// untouched, so the log stays addressable and settings keep loading.
    ///
    /// Rejected while a conversation is running: history already carries the previous name,
    /// and a rename halfway through would leave the shared log attributing turns to
    /// different names for the same participant.
    @discardableResult
    public func renameSeat(_ agentID: String, to name: String) -> Bool {
        guard turns.isEmpty, !isRunning else { return false }
        guard let index = panes.firstIndex(where: { $0.id == agentID }) else { return false }

        let trimmed = String(
            name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        var spec = panes[index].spec
        // An emptied field falls back to the seat's kind rather than leaving it nameless.
        spec.displayName = trimmed.isEmpty ? panes[index].seatKind : trimmed
        panes[index].spec = spec

        run { client in
            _ = try await client.send(
                .updateSeat(.init(seatID: agentID, name: spec.displayName)))
        }
        saveSettings()
        return true
    }

    /// Whether seats may be renamed right now.
    public var canRenameSeats: Bool { turns.isEmpty && !isRunning }

    /// Change one seat's thinking level. Applies from its next turn.
    public func setThinking(_ mode: ThinkingMode, for agentID: String) {
        run { client in
            _ = try await client.send(
                .updateSeat(.init(seatID: agentID, thinking: mode)))
        }
    }

    /// Change one seat's style. Applies from its next turn.
    public func setPersona(_ personaID: String, for agentID: String) {
        // The engine reseats the style and answers with the whole state, so the pane is
        // updated from the reply rather than from a local guess at what changed.
        run { client in
            _ = try await client.send(
                .updateSeat(.init(seatID: agentID, personaID: personaID)))
        }
        pane(agentID)?.spec.personaID = personaID
        saveSettings()
    }

    /// Point one seat at a backend. Only offered before the conversation starts, because
    /// switching mid-thread would change a participant's identity part-way through.
    public func setBackend(_ backend: AgentSpec.Backend, for agentID: String) {
        run { client in
            _ = try await client.send(
                .updateSeat(.init(seatID: agentID, backend: backend)))
        }
        pane(agentID)?.spec.backend = backend
    }

    /// Point one seat at a different MLX checkpoint.
    ///
    /// The engine replaces the seat's MLX engine with one for the new weights and releases the old
    /// one, so the pane is updated from what was asked for and the next turn loads the new
    /// checkpoint. A refusal — the room is running, or the id is empty — comes back as a message and
    /// the pane keeps the model it has, because a change that did not happen must not be shown as one
    /// that did.
    public func setModel(_ modelID: String, for agentID: String) {
        let resolved = ModelCatalog.resolve(modelID)
        guard !resolved.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            // The pane follows the engine, not the click: the change is shown only once the engine has
            // taken it, and a refusal — the room is running — arrives in `engineConnection` with the
            // reason. Showing the new checkpoint on a seat that is still running the old one is the
            // defect this guards against, and `deliver` is the awaiting send added for exactly this.
            guard await self.deliver(.updateSeat(.init(seatID: agentID, modelID: resolved))) else {
                return
            }
            guard self.pane(agentID)?.spec.modelID != resolved else { return }
            self.pane(agentID)?.spec.modelID = resolved
            self.pane(agentID)?.spec.modelShortName = ModelNames.shortName(resolved)
            self.saveSettings()
        }
    }

    /// Point one seat at a different server or model id.
    public func setEndpoint(_ endpoint: OpenAIEndpoint, for agentID: String) {
        run { client in
            _ = try await client.send(
                .updateSeat(
                    .init(
                        seatID: agentID, backend: .openAIResponses, baseURL: endpoint.baseURL,
                        apiModel: endpoint.model, apiKey: endpoint.apiKey)))
        }
        pane(agentID)?.spec.openAI = endpoint
    }

    /// Push every seat's configured endpoint into its engine.
    ///
    /// Called whenever the endpoint settings change and once at launch, so a seat is ready
    /// before it is asked for a turn.
    func applyAPIEndpoints(_ store: APIEndpointStore) {
        for (index, pane) in panes.enumerated() where index < panes.count {
            let endpoint = store.endpoint(forSeat: index)
            pane.spec.openAI = endpoint
            run { client in
                _ = try await client.send(
                    .updateSeat(
                        .init(
                            seatID: pane.id, baseURL: endpoint.baseURL,
                            apiModel: endpoint.model, apiKey: endpoint.apiKey)))
            }
        }
    }

    /// Route every seat through the API, or back to the local models.
    ///
    /// The point of the API backend is that local weights need not be involved at all, so
    /// this is a single switch rather than one per seat.
    func useAPIForAllSeats(_ useAPI: Bool, store: APIEndpointStore) {
        for pane in panes {
            setBackend(useAPI ? .openAIResponses : .mlx, for: pane.id)
        }
        applyAPIEndpoints(store)
    }

    /// True when no seat is using the local MLX models.
    public var isCloudOnly: Bool {
        !panes.isEmpty && panes.allSatisfy { $0.spec.backend == .openAIResponses }
    }
}
