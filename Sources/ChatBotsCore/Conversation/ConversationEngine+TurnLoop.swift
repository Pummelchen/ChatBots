// ChatBotsCore — the turn loop and the events it folds into the shared log
//
// Split out of `ConversationEngine.swift`, which held the orchestrator, its turn loop, its
// transcript plumbing, its context bookkeeping and its research mode in one 1613-line file.
// Who speaks next, one turn end to end, and what a finished or failed generation leaves in
// the log all live here; nothing changed but which file the code lives in.

import Foundation

extension ConversationEngine {

    // MARK: - Turn loop

    /// Who speaks next.
    ///
    /// Entertainment rotates, and rotation is the right answer there: a show where the app
    /// decides who is worth hearing is a show being edited. Research does not rotate. The
    /// moderator has a job — deciding what the investigation still owes and who is equipped to
    /// supply it — and a rotation means a question needing the Statistician hears from whoever
    /// is next instead, which is how a session spends its budget and still does not answer.
    ///
    /// The direction is logged as its own kind of turn, so it reaches the seat in the prompt
    /// *and* is visible in the transcript. A decision that steers the conversation but is
    /// invisible in the record would make the investigation impossible to review afterwards.
    private func nextSeat() -> Seat {
        let rotation = seats[seatCursor % seats.count]
        guard conversation.research != nil else { return rotation }

        let direction = ResearchReading.read(seats: specs, turns: conversation.turns).direction()
        guard
            let seatID = direction.seatID,
            let directed = seats.first(where: { $0.spec.id == seatID })
        else {
            // Nothing outstanding. Saying so is the honest answer, and it is worth a line:
            // otherwise "the moderator had nothing to direct" and "the moderator is not
            // implemented" look identical from the outside.
            note("Research Moderator: \(direction.reason).")
            return rotation
        }

        note("Research Moderator → \(directed.spec.displayName): \(direction.reason).")
        conversation.turns.append(
            Self.directionTurn(sequence: nextSequence(), direction: direction))
        publishTranscript()
        return directed
    }

    /// The transcript entry for one of the director's decisions.
    ///
    /// The turn carries `unaddressedSubject` only for the assignment that points at a subject
    /// nobody has addressed, because that is the one where a single seat's answer counts as the
    /// room engaging with it. Reading it from an explicit marker rather than from the
    /// instruction's wording is what stops a copy edit from silently disabling the rule.
    /// Pure, so the marker the emit path sets is asserted without running a
    /// conversation.
    static func directionTurn(sequence: Int, direction: ResearchDirection) -> Turn {
        Turn(
            sequence: sequence,
            speakerID: nil,
            speakerName: "Research Moderator",
            kind: .direction,
            content: direction.instruction,
            unaddressedSubject: direction.kind == .unaddressedSubject
                ? direction.subQuestion : nil)
    }
    func runLoop(generation: Int) async {
        while !Task.isCancelled {
            if status.isPaused {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    pauseContinuation = continuation
                }
            }
            if Task.isCancelled { break }

            // A research session stops when its budget says so, and writes its report on the
            // way out. Checked before another turn is planned, so a finished investigation
            // does not spend one more contribution restating what it already concluded.
            if let session = conversation.research, session.isFinished() {
                let reason = session.evaluate()
                note("Research finished — \(reason.explanation)")
                await writeReport(reason: reason)
                setStatus(.limitReached)
                break
            }

            // And it stops when the moderator has nothing left to point at, whether or not the
            // budget would have allowed more. The moderator's own decision criteria say it
            // concludes when the sub-questions are addressed and further work would not move
            // the answer; that is a better reason to stop than a clock, and it is the whole
            // point of having a moderator rather than a timer. Guarded on `rounds > 0` so a
            // session cannot conclude before anyone has spoken.
            if let session = conversation.research, session.rounds > 0,
                !ResearchReading.read(seats: specs, turns: conversation.turns).hasOpenWork
            {
                conversation.research?.finish(.answered)
                let reason = ResearchStop.answered
                note("Research finished — \(reason.explanation)")
                await writeReport(reason: reason)
                setStatus(.limitReached)
                break
            }

            if turnsCompleted >= configuration.maxTurns {
                note(
                    "Turn limit (\(configuration.maxTurns)) reached — steer, raise the limit, or clear."
                )
                setStatus(.limitReached)
                break
            }

            let seat = nextSeat()
            setStatus(.running(turn: turnsCompleted + 1))
            await runTurn(seat: seat)
            if Task.isCancelled { break }

            seatCursor += 1
            turnsCompleted += 1

            if configuration.pace > .zero {
                try? await Task.sleep(for: configuration.pace)
            }
        }

        // Only the loop that owns the current generation may clear it. A cancelled
        // predecessor resumes whenever its suspension ends — which `stop()` cannot wait for —
        // and without this check its tail would run after a restart had installed the new
        // task and clear *that* reference. `isLoopRunning`, `pause()` and `stop()` all key off
        // this reference, so the new loop would become unpausable and unstoppable, and a
        // further Start would pass `guard generationTask == nil` and run a second loop over
        // the same transcript. A stale loop also must not overwrite the status its successor
        // has set, so the status line is left alone unless this generation still owns it.
        guard generation == loopGeneration else { return }
        generationTask = nil
        if status.isActive {
            setStatus(.stopped)
        }
    }

    private func runTurn(seat: Seat) async {
        // Deliver anything the moderator typed since the last turn. These enter the
        // shared log here — once — which is why mid-turn steering can never be
        // duplicated or shown to only one seat.
        // Reclaim context before composing this turn, so the seat that is about to speak
        // is the one whose window is measured and whose style shapes the digest. Only the
        // *automatic* path consults the switch; `compactNow` calls this directly.
        //
        // The window is asked of the engine once, here, and handed to compaction and to the
        // usage snapshot both: the spec's value is a fallback, not the measurement. Asking
        // once avoids a second round trip on every turn (the API backend resolves it from
        // disk).
        let window = await refreshContextWindow(for: seat)
        if configuration.autoCompact {
            await compactIfNeeded(using: seat, window: window)
        }

        let pending = drainSteering()
        for turn in pending {
            conversation.turns.append(turn)
        }
        if !pending.isEmpty {
            publishTranscript()
        }

        // Built from the engine's live configuration, not the spec captured at
        // construction, so a persona or thinking change made in the UI takes effect here.
        // The source material reaches a seat through two channels: text goes into the
        // prompt, images go to the engine. Both are refreshed each turn so adding a file
        // before the conversation starts is enough.
        await seat.engine.setAttachments(conversation.attachments)
        let liveSpec = await seat.engine.currentSpec
        currentSpeakerName = liveSpec.displayName
        let prompt = PromptBuilder.prompt(
            for: liveSpec,
            others: seats.map(\.spec).filter { $0.id != liveSpec.id },
            conversation: conversation,
            moderator: moderator
        )

        startedTurns += 1
        publishEvent(.turnStarted(agentID: seat.spec.id, prompt: prompt))

        // Web tools are offered only while the session has search budget left, so once the
        // ceiling is reached a turn cannot start another billed call. The count of what a turn
        // actually spent is taken from the tool-call callback below, not guessed from the
        // transcript: the old sequence-window heuristic counted a multi-call turn as one (so
        // the budget could be run past arbitrarily) and credited a seat a search it had not
        // made from its own previous turn (so `.searchesReached` could fire early and change
        // the report's stop reason).
        toolCallsThisTurn = 0
        let budgetRemaining = conversation.research.map {
            max(0, $0.budget.maxSearches - $0.searches)
        }
        let tools: [any ToolProvider] =
            seat.spec.webSearchEnabled && (budgetRemaining == nil || budgetRemaining! > 0)
            ? WebToolbox.tools : []
        let engine = seat.engine
        let agentID = seat.spec.id

        do {
            let text = try await engine.generate(
                messages: prompt,
                tools: tools,
                onToolCall: { [weak self] name, argument in
                    await self?.noteToolCall(agentID: agentID, name: name, argument: argument)
                },
                onEvent: { [weak self] event in
                    // `handle` is the one that publishes: every branch below ends in
                    // `publishEvent(event)`, and it also folds the event into the transcript.
                    // Publishing here as well ran `record(event)` twice, so live text and
                    // reasoning were doubled, `toolLog` got duplicate entries, and every
                    // `observeEvents` subscriber and the `events` stream saw each token
                    // twice. `conversation.turns` is appended once either way, which is why
                    // no transcript-level test caught it.
                    await self?.handle(event, from: agentID)
                }
            )
            _ = text  // `.turnFinished` already carried the final text
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            note("\(agentID) error: \(error.localizedDescription)")
            publishEvent(.turnFailed(agentID: agentID, message: error.localizedDescription))
        }
    }

    /// Record one web tool call, for the budget and the live pane.
    ///
    /// The engine calls this once per tool call it is about to dispatch, which is the only place
    /// the real number is available: the transcript has a `.tool` turn per result, but a turn's
    /// results are not all in it until the turn ends, and inferring a count from sequences
    /// credited calls that were never made.
    private func noteToolCall(agentID: String, name: String, argument: String) {
        toolCallsThisTurn += 1
        publishEvent(.toolCall(agentID: agentID, name: name, query: argument))
    }

    /// Fold an engine event into the shared log, then forward it to the UI.
    private func handle(_ event: TurnEvent, from agentID: String) {
        switch event {
        case .turnFinished(let id, let text, let stats):
            if stats.promptTokens > 0 {
                measuredPromptTokens = stats.promptTokens
                lastMeasuredDialogueTokens = conversation.dialogueTurns
                    .reduce(0) { $0 + max(1, $1.content.count / 4) }
            }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // The handler is given an id, not the seat, so the mode is looked up here. Needed
            // before the empty/non-empty split now, for the budget below.
            let speakerMode = seats.first { $0.spec.id == id }?.spec.mode ?? .entertainment
            if speakerMode == .research {
                // A contribution that brought evidence, changed a position or answered a
                // challenge is progress; one that restated a position is not. A run of those
                // is what convergence means. An empty turn added nothing by definition.
                let added =
                    !clean.isEmpty
                    && ConflictReader.signals(
                        in: clean, from: id, others: seats.map(\.spec.id), addressing: nil
                    ).contains { $0.kind == .newEvidence || $0.kind == .positionChange }
                // What this turn actually spent, counted at the tool call, recorded whether or
                // not the turn produced text. It used to be recorded only in the non-empty
                // branch, so a turn that emitted nothing but tool calls spent billed searches
                // for free: `searches` never moved, the `maxSearches` ceiling never dropped,
                // and web tools stayed offered on every later turn.
                conversation.research?.record(
                    searchCount: toolCallsThisTurn, addedSomething: added)
            }
            if clean.isEmpty {
                note("\(id) produced no text (stop: \(stats.stopReason)).")
            } else {
                let sequence = nextSequence()
                conversation.turns.append(
                    Turn(
                        sequence: sequence,
                        speakerID: id,
                        speakerName: currentSpeakerName ?? id,
                        kind: .chat,
                        content: clean
                    )
                )
                // Read the turn for social signals, so the next speaker reacts to what was
                // actually said rather than to a transcript it has to re-derive. Only in
                // entertainment: a research seat is judged on method and evidence, and
                // importing grudges into it would be the modes sharing a philosophy.
                if speakerMode == .entertainment {
                    let everyone = seats.map(\.spec.id)
                    let signals = ConflictReader.signals(
                        in: clean,
                        from: id,
                        others: everyone,
                        // Names to match the text against, ids to key the state by: the models write the
                        // name, and the social state is keyed by the id.
                        names: Self.nameIndex(seats.map(\.spec)),
                        // Aimed at whoever spoke last, which is who the message is answering.
                        addressing: conversation.turns.dropLast().last { $0.kind == .chat }?.speakerID
                    )
                    conversation.conflict.apply(
                        signals: signals,
                        from: id,
                        others: everyone,
                        sequence: sequence,
                        summary: ConflictReader.summary(of: clean)
                    )
                }
                publishTranscript()
            }
            publishEvent(event)

        case .toolResult(let id, let name, let summary, let detail):
            conversation.turns.append(
                Turn(
                    sequence: nextSequence(),
                    speakerID: id,
                    speakerName: id,
                    kind: .tool,
                    content: "\(name): \(summary)",
                    toolDetail: detail
                )
            )
            publishTranscript()
            publishEvent(event)

        case .toolFailure(let id, let name, let message):
            note("\(id) tool \(name) failed: \(message)")
            publishEvent(event)

        default:
            publishEvent(event)
        }
    }
    /// A lowercased display name to seat id map, for the social reader.
    ///
    /// A name shorter than three characters is dropped, because `ConflictReader` ignores those — a
    /// one-letter name would match by accident — and a duplicated name keeps the first seat, since two
    /// participants with one name cannot be told apart by text anyway.
    static func nameIndex(_ specs: [AgentSpec]) -> [String: String] {
        var index: [String: String] = [:]
        for spec in specs where spec.displayName.count >= 3 {
            let key = spec.displayName.lowercased()
            if index[key] == nil { index[key] = spec.id }
        }
        return index
    }
}
