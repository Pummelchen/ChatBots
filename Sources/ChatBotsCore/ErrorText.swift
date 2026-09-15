// ChatBotsCore — how a failure is worded
//
// One place decides which description an error gets, because `localizedDescription` alone is not
// enough. The transport's errors are `CustomStringConvertible` and not `LocalizedError`, and
// Foundation bridges exactly those to "The operation couldn't be completed. (… error 2.)" — a number
// with no cause in it. That is what the installer's smoke test printed: `error 2`, the case at index
// 2, `invalidTransport`, while the sentence naming the setting it had rejected sat unread in the
// error's own `description`. The same collapse reaches the window, where `engineConnection` is the
// text a user is shown when the engine cannot be reached (A216, and A175 for the banner it feeds).
//
// It lives outside `WebTransportEngineClient` because it is not about that client: an error is
// worded this way wherever one is reported, and the client is a `@MainActor` class, so a pure
// formatting function inside it would be main-actor isolated for no reason.

import Foundation

enum ErrorText {

    /// The most specific description an error offers.
    ///
    /// A `LocalizedError` is preferred, because its `errorDescription` is the text Foundation itself
    /// would show. Then an error that is not an `NSError` speaks with its own `description` — the
    /// transport's own sentence. `NSError` and its subclasses are left to `localizedDescription`:
    /// they also describe themselves, but their `description` is the same "Error Domain=… Code=…"
    /// text, and Foundation's version of it is what every other Swift program shows.
    ///
    /// A class metatype is how a bridged Foundation error is told apart from a Swift value type.
    /// `as? NSError` cannot tell them apart: every Swift error bridges to one.
    static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError,
            let description = localized.errorDescription, !description.isEmpty
        {
            return description
        }
        if !(type(of: error) is AnyClass) {
            let described = String(describing: error)
            if !described.isEmpty { return described }
        }
        return error.localizedDescription
    }
}
