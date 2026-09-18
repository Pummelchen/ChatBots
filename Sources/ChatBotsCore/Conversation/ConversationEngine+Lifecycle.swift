// ChatBotsCore — starting, pausing, stopping and steering a conversation
//
// Split out of `ConversationEngine.swift`, which held the orchestrator, its turn loop, its
// transcript plumbing, its context bookkeeping and its research mode in one 1613-line file.
// These are the commands a front end sends and the opening turns a start writes; nothing
// changed but which file the code lives in.

import Foundation

extension ConversationEngine {

    // MARK: - Commands

    public func send(_ command: EngineCommand) {
        switch command {
        case .start: start()
        case .pause: pause()
        case .resume: resume()
        case .stop: stop()
        case .steer(let text): steer(text)
        case .reset: reset()
        }
    }

    /// Begin (or restart after a stop) with the given topic. Every seat is loaded
    /// first, so the first turn is not also a model download.
    /// Begin a research session, if the mode calls for one.
    ///
    /// Started once per conversation and then carried, so restarting does not reset a budget
    /// the moderator already spent — a session that reset its clock on every Start would never
    /// reach its end condition.
    private func beginResearchSessionIfNeeded() {
        guard !seats.isEmpty, seats[0].spec.mode == .research else { return }
        guard conversation.research == nil else { return }
        let budget =
            configuration.researchBudget
            ?? ResearchBudget.preset(.standard)
        conversation.research = ResearchSession(budget: budget)
        note(
            "Research budget: \(budget.depth.label) — \(budget.depth.summary), "
                + "\(budget.maxRounds) contributions, \(budget.maxSearches) searches.")
    }

    public func start(topic: String? = nil) {
        beginResearchSessionIfNeeded()
        if let topic {
            conversation.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !conversation.topic.isEmpty else {
            setStatus(.failed(ChatBotsError.emptyTopic.localizedDescription))
            return
        }
        guard generationTask == nil else { return }

        // A restarted conversation is a new run, so its failure count starts again.
        failedTurns = 0
        seedOpeningTurns()
        setStatus(.preparing)

        // The new loop's identity is stamped before the task is installed, so a predecessor
        // resuming from its cancellation sees a generation that is no longer its own.
        loopGeneration += 1
        let generation = loopGeneration
        let seats = self.seats
        generationTask = Task { [weak self] in
            // Load all seats concurrently — they are independent model instances.
            await withTaskGroup(of: Void.self) { group in
                for seat in seats {
                    group.addTask {
                        do {
                            try await seat.engine.load()
                            await self?.recordModelLoad(of: seat.spec.id, failure: nil)
                        } catch {
                            let reason = error.localizedDescription
                            await self?.note("\(seat.spec.id) failed to load: \(reason)")
                            await self?.recordModelLoad(of: seat.spec.id, failure: reason)
                        }
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            await self.runLoop(generation: generation)
        }
    }

    /// Pause between turns. A turn already generating is allowed to finish.
    /// True while a conversation is under way, paused included — a paused conversation is
    /// still one that has started.
    public var isRunning: Bool { status.isActive }
    public var isPaused: Bool { status.isPaused }

    public func pause() {
        guard generationTask != nil else { return }
        guard !status.isPaused else { return }
        setStatus(.paused)
    }

    public func resume() {
        guard generationTask != nil else { return }
        guard status.isPaused else { return }
        let continuation = pauseContinuation
        pauseContinuation = nil
        setStatus(.running(turn: turnsCompleted + 1))
        continuation?.resume()
    }

    /// Stop the loop. Loaded weights stay resident so restarting is instant.
    public func stop() {
        generationTask?.cancel()
        generationTask = nil
        releasePauseGate()
        setStatus(.stopped)
    }

    /// Condense the log on demand.
    ///
    /// Runs whether or not the threshold has been reached, which is what makes it usable as
    /// a "make room now" control before a long prompt of your own.
    public func compactNow() {
        guard generationTask == nil else {
            note("Finish or stop the current turn before compacting.")
            return
        }
        guard let seat = seats.first else { return }
        Task { [weak self] in
            guard let self else { return }
            let compacted = await self.compactIfNeeded(using: seat, force: true)
            if !compacted { self.note("Nothing to condense yet.") }
        }
    }

    /// Forget the conversation, keeping the configuration.
    ///
    /// The rule is what a conversation *accumulated* goes and what the moderator *chose* stays:
    /// the topic, the seats and the attachments are settings, and the transcript, the social
    /// state, the investigation's budget, its report and the audience's votes all belong to the
    /// conversation being cleared.
    ///
    /// Getting this wrong was not cosmetic. `research` surviving a reset meant a finished
    /// investigation kept its latched stop reason, so **Clear then Start did nothing at all**:
    /// the new run found a session that was already finished and wrote a second report without
    /// a single turn. A stale report also stayed on screen over an empty transcript.
    public func reset() {
        stop()
        conversation.turns = []
        conversation.conflict = ConflictState()
        conversation.research = nil
        conversation.report = nil
        conversation.votes = []
        queuedSteering = []
        notices = []
        noticeContinuation?.yield([])
        turnsCompleted = 0
        startedTurns = 0
        seatCursor = 0
        publishTranscript()
        setStatus(.idle)
        note("Conversation cleared.")
    }

    /// Inject a human message into the shared log.
    ///
    /// Mid-turn, the text is queued and appended once, at the next turn boundary, so
    /// the next speaker sees it. Idle, it is appended immediately and the loop starts.
    public func steer(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let turn = Turn(
            sequence: nextSequence(),
            speakerName: moderator.speakerName,
            kind: .steering,
            content: trimmed
        )

        if status.isActive {
            queuedSteering.append(turn)
            publishTranscript()  // visible immediately, marked pending by the UI
            note("Queued — \(nextSpeakerID()) will pick it up at the next turn boundary.")
        } else {
            // Into the log and *not* into the queue. The queue is "not yet delivered to the
            // models"; this turn is in the log they are about to be given, so queueing it as well
            // delivered it twice — once now and once when the queue was drained at the first turn
            // boundary. The duplicate reached the prompt, where it read as the moderator saying
            // the same thing twice.
            conversation.turns.append(turn)
            publishTranscript()
            if generationTask == nil, status != .stopped {
                // Steering an untouched conversation is how you start it: the message
                // becomes the topic, so the opening brief is generated around it.
                if conversation.topic.isEmpty {
                    conversation.topic = trimmed
                }
                start()
            } else if status.isPaused {
                note("Appended to the log. Press Resume to let the models answer it.")
            }
        }
    }
    /// Write the opening: the question, and the brief that explains the rules.
    ///
    /// Written once and idempotently, so restarting a stopped conversation does not write a
    /// second brief — and so a conversation *started* by the moderator typing a message still
    /// gets one. The previous version bailed out entirely if the log already held a steering
    /// turn, which meant the "type a message to begin" path had no brief at all: the seats were
    /// given a question and no rules, no roster and no statement of what the conversation was.
    ///
    /// No topic turn is written in that case, because the message that started the conversation
    /// *is* the question; writing both would show it twice, which is the bug this replaced.
    private func seedOpeningTurns() {
        let alreadyAsked = conversation.turns.contains {
            $0.kind == .topic || $0.kind == .steering
        }
        if !alreadyAsked {
            conversation.turns.append(
                Turn(
                    sequence: nextSequence(),
                    speakerName: moderator.speakerName,
                    kind: .topic,
                    content: conversation.topic
                )
            )
        }

        if !conversation.turns.contains(where: { $0.kind == .introduction }) {
            let intro = PromptBuilder.introduction(
                specs: specs, topic: conversation.topic, moderator: moderator)
            conversation.turns.append(
                Turn(
                    sequence: nextSequence(),
                    speakerName: "System",
                    kind: .introduction,
                    content: intro
                )
            )
        }
        publishTranscript()
    }
    private func nextSpeakerID() -> String {
        seats[seatCursor % seats.count].spec.id
    }
    /// Start a new conversation, with a new identity on disk.
    public func startNewConversation() {
        reset()
        conversationID = UUID()
        conversationStartedAt = .now
    }
}
