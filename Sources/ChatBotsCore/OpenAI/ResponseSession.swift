// ChatBotsCore — the session a client keeps, and the redirects it refuses
//
// Split out of `OpenAIResponsesClient.swift`. The session lives in a class because `deinit` is what
// invalidates it — a struct cannot do anything when it is deallocated.

import Foundation

/// A task delegate that refuses every redirect.
///
/// Stateless, and `Sendable` because of it — `URLSession` keeps it for the session's lifetime.
///
/// Shared by both outbound clients. The OpenAI client always had it; the Tavily client built a bare
/// `URLSession(configuration:)`, which follows redirects by default, so a 302 from `api.tavily.com`
/// was followed with `Authorization: Bearer <key>` attached. Following a redirect is how a URL that
/// passed a host check reaches a host that never did.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// The session a client keeps, invalidated when the last reference to it goes.
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
