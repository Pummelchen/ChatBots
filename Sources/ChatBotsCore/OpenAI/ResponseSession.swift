// ChatBotsCore — the session a client keeps, and the redirects it refuses
//
// Split out of `OpenAIResponsesClient.swift`. The session lives in a class because `deinit` is what
// invalidates it — a struct cannot do anything when it is deallocated.

import Foundation

/// first is not. A struct cannot do anything when it is deallocated, so the session lives in a class
/// whose `deinit` is the invalidate.
final class ResponseSession: Sendable {
    let session: URLSession

    init(configuration: URLSessionConfiguration, delegate: URLSessionDelegate) {
        self.session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        // `finishTasksAndInvalidate` rather than `invalidateAndCancel`: a session released after a turn
        // has already finished has nothing in flight to cancel, and cancelling is for the caller that is
        // deliberately giving up on a request it started.
        session.finishTasksAndInvalidate()
    }
}
