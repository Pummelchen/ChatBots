// ChatBotsCore — an HTTP request translated into an engine command
//
// Split out of `APIServer.swift`, which held the routes, this translation and the push feed in one file.
// Nothing here answers a request itself: it turns a method and a path into the engine's own vocabulary,
// and a body it cannot read into a refusal that says why rather than into silent defaults. The code did
// not change.

import Foundation

extension APIServer {

    /// A request that cannot be turned into an engine request, and why.
    ///
    /// Separate from "no route" because the answer differs: an unknown route is a 404, a body the
    /// server cannot read is a 400 that says what was wrong.
    ///
    /// Internal rather than private: `route` in `APIServer.swift` catches it to answer 400.
    struct UnreadableRequest: Error {
        var reason: String
    }

    /// The command body, telling three states apart that `try?` used to collapse into one.
    ///
    /// No body at all means the field was not sent, which some routes treat as "clear this" and is
    /// the caller's decision. A body that decodes is the command. A body that was **sent and cannot
    /// be read** is a client error — and it used to be read as the defaults, so a typo in `mode`
    /// switched the room to entertainment, an unknown research depth reset it to standard, and a
    /// malformed topic cleared it. Silent, and in the direction of changing state.
    private func command(from request: HTTPRequest) throws -> APICommand? {
        guard !request.body.isEmpty else { return nil }
        guard let decoded = request.json(APICommand.self) else {
            throw UnreadableRequest(
                reason: "the request body is not a JSON object with the fields this route takes")
        }
        return decoded
    }

    /// The 400 for a value that is present but not one this server knows.
    ///
    /// The two routes that map a string to a case used to answer with a default instead — an unknown
    /// mode switched the room to entertainment, an unknown research depth reset it to standard — so a
    /// misspelling changed state. It is a bad request, and the answer says what was expected.
    private func unknownValue(_ field: String, _ raw: String, _ allowed: [String]) -> UnreadableRequest {
        UnreadableRequest(
            reason: "unknown \(field) \"\(raw)\" — expected one of: \(allowed.joined(separator: ", "))")
    }

    /// The change a seat update describes.
    ///
    /// Pulled out of `translate` because the case that used to build it inline put that function over
    /// its `function_body_length` budget, and a named value reads better than a nested `.init` anyway.
    private func seatChange(from body: APICommand, seatID: String) throws -> EngineRequest.SeatChange {
        // An unknown value used to be flattened to nil, which the engine reads as "leave it", so a
        // misspelling answered 200 with the seat unchanged. Every sibling route refuses it with 400
        // and the list of what was expected; this one does now too.
        let thinking = try body.thinking.map { raw in
            guard let mode = ThinkingMode(rawValue: raw) else {
                throw unknownValue("thinking", raw, ThinkingMode.allCases.map(\.rawValue))
            }
            return mode
        }
        let backend = try body.backend.map { raw in
            guard let value = AgentSpec.Backend(rawValue: raw) else {
                throw unknownValue("backend", raw, AgentSpec.Backend.allCases.map(\.rawValue))
            }
            return value
        }
        return EngineRequest.SeatChange(
            seatID: seatID, name: body.name, personaID: body.personaID,
            thinking: thinking,
            backend: backend,
            modelID: body.modelID,
            baseURL: body.baseURL, apiModel: body.apiModel, apiKey: body.apiKey)
    }

    /// Turn an HTTP request into an engine request.
    ///
    /// Internal rather than private: `route` in `APIServer.swift` calls it for every route the
    /// transport-specific switch did not answer.
    func translate(_ request: HTTPRequest) throws -> EngineRequest? {
        switch (request.method, request.path) {
        case ("GET", "/api/state"): return .fetchState
        case ("POST", "/api/start"): return .start
        case ("POST", "/api/pause"): return .pause
        case ("POST", "/api/resume"): return .resume
        case ("POST", "/api/stop"): return .stop
        case ("POST", "/api/reset"): return .reset
        case ("POST", "/api/compact"): return .compact
        case ("POST", "/api/attachments/clear"): return .clearAttachments
        case ("GET", "/api/conversations"): return .listSavedConversations
        case ("POST", "/api/conversations/new"): return .newConversation

        case ("POST", "/api/conversations/load"):
            guard let id = try command(from: request)?.value else { return nil }
            return .loadSavedConversation(id: id)

        case ("POST", "/api/conversations/delete"):
            guard let id = try command(from: request)?.value else { return nil }
            return .deleteSavedConversation(id: id)

        case ("POST", "/api/topic"):
            guard let body = try command(from: request), let topic = body.topic,
                !topic.isEmpty
            else { return .setTopic("") }  // an empty topic is refused by the engine
            return .setTopic(topic)

        case ("POST", "/api/message"):
            guard let body = try command(from: request), let text = body.text else {
                return .steer("")
            }
            return .steer(text)

        case ("POST", "/api/settings"):
            let body = try command(from: request)
            return .setShowReasoning(body?.showReasoning ?? service.showReasoning)

        case ("POST", "/api/mode"):
            guard let raw = try command(from: request)?.value else { return nil }
            guard let mode = DiscussionMode(rawValue: raw) else {
                throw unknownValue("mode", raw, DiscussionMode.allCases.map(\.rawValue))
            }
            return .setMode(mode)

        case ("POST", "/api/roster"):
            guard let body = try command(from: request), let id = body.id else { return nil }
            // A seed the caller supplies reproduces a draw; one it does not supply is made
            // here and reported, so every draw is repeatable whether or not it was planned.
            return .applyRoster(id: id, seed: body.seed ?? RosterLibrary.freshSeed())

        case ("POST", "/api/scenario"):
            guard let id = try command(from: request)?.id else { return nil }
            return .applyScenario(id: id)

        case ("POST", "/api/vote"):
            guard let body = try command(from: request), let turnID = body.id else { return nil }
            // No verdict withdraws the vote, so a mis-click does not have to be reversed by
            // clicking the opposite button — which would leave a wrong judgement in the record.
            return .castVote(
                turnID: turnID,
                verdict: body.verdict.flatMap(AudienceVote.Verdict.init(rawValue:)))

        case ("POST", "/api/votes/clear"):
            return .clearVotes

        case ("POST", "/api/moderator"):
            guard let body = try command(from: request) else { return nil }
            return .setModerator(
                ModeratorIdentity(
                    name: body.name ?? ModeratorIdentity.defaultName,
                    personaID: body.personaID ?? PersonaLibrary.neutral.id))

        case ("POST", "/api/research/budget"):
            guard let raw = try command(from: request)?.value else { return nil }
            guard let depth = ResearchBudget.Depth(rawValue: raw) else {
                throw unknownValue(
                    "research depth", raw, ResearchBudget.Depth.allCases.map(\.rawValue))
            }
            return .setResearchBudget(depth)

        case ("POST", "/api/seat"):
            guard let body = try command(from: request), let seatID = body.seat else {
                return nil
            }
            return .updateSeat(try seatChange(from: body, seatID: seatID))

        case ("POST", "/api/attachments"):
            guard let body = try command(from: request), let filename = body.filename,
                let content = body.content, let data = Data(base64Encoded: content)
            else { return nil }
            return .addAttachment(filename: filename, contents: data)

        case ("POST", "/api/attachments/remove"):
            guard let id = try command(from: request)?.value else { return nil }
            return .removeAttachment(id: id)

        default:
            return nil
        }
    }
}
