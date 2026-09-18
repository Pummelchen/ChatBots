// ChatBotsCore — proving which engine is answering
//
// The token itself lives in `SessionToken`; this is the engine's half of the exchange. It is its
// own file because it is its own responsibility — identity — and because `EngineService.swift`
// sits at the file-size budget.
//
// `.identify` is answered here and nowhere else. `APIServer+Commands.translate` maps method and
// path strings onto `EngineRequest` cases and has no route for it, so the unauthenticated HTTP
// API cannot ask for the token; the case is reachable only on the transport the app connects on.

import Foundation

extension EngineService {

    /// Echo the per-run token, or say that this engine has none to echo.
    ///
    /// An engine started without a token cannot prove who it is, and a refusal is the honest
    /// answer: an empty string would read as a token and verify nothing.
    func identify() -> EngineReply {
        guard let sessionToken else {
            return .refused("this engine has no session token and cannot identify itself")
        }
        return .identified(sessionToken)
    }
}
