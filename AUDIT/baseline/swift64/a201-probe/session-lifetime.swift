// The measurement behind the `ResponseSession` deinit, run on its own so the claim "URLSession is not
// released until it is invalidated" is a result rather than a belief. `swift a201-probe/session-lifetime.swift`.
import Foundation

final class Delegate: NSObject, URLSessionTaskDelegate {}

func makePlain() -> URLSession? {
    let c = URLSessionConfiguration.ephemeral
    let s = URLSession(configuration: c, delegate: Delegate(), delegateQueue: nil)
    withExtendedLifetime(s) {}
    return s
}
func makeInvalidated() -> URLSession? {
    let c = URLSessionConfiguration.ephemeral
    let s = URLSession(configuration: c, delegate: Delegate(), delegateQueue: nil)
    s.finishTasksAndInvalidate()
    return s
}

weak var plain: URLSession? = makePlain()
weak var invalidated: URLSession? = makeInvalidated()
Thread.sleep(forTimeInterval: 0.3)
print("released without invalidating -> still alive: \(plain != nil)")
print("released after invalidating    -> still alive: \(invalidated != nil)")
