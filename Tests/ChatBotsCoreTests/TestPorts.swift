// ChatBotsCoreTests — ports for the tests that start a real server
//
// One counter for the whole test target. Two fixtures each picking their own base range is how
// they ended up colliding: swift-testing runs tests in parallel, so three tests in one suite all
// reached for the same first port and two of them had to retry. A counter cannot collide with
// itself, and the retry is kept for whatever else is on the machine.

import Foundation

@MainActor private var nextTestPort = 7_900

/// A port no other test in this run will pick.
///
/// The caller still has to check that it bound: another process on the machine may hold it, and
/// `HTTPServer.waitUntilReady()` is the only way to know.
@MainActor func allocateTestPort() -> UInt16 {
    defer { nextTestPort += 1 }
    return UInt16(nextTestPort)
}
