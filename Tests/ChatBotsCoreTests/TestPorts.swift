// ChatBotsCoreTests — ports for the tests that start a real server
//
// One counter for the whole test target. Two fixtures each picking their own base range is how
// they ended up colliding: swift-testing runs tests in parallel, so three tests in one suite all
// reached for the same first port and two of them had to retry. A counter cannot collide with
// itself, and the retry is kept for whatever else is on the machine.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

@MainActor private var nextTestPort = 7_900

/// Whether `port` can be bound on loopback right now.
///
/// A **probe, not a reservation**: the socket is closed again immediately, so something else can
/// take the port between this check and the caller's bind. `HTTPServer.waitUntilReady()` stays the
/// authority on whether the server actually came up.
///
/// What it buys is that two runs of this suite on one machine stop starting on the same number.
/// The counter alone is safe *within* a process but knows nothing about anything else, so a second
/// run - another checkout, a CI job, someone running the suite twice - began at 7 900 as well and
/// the two collided from the first server test onward. That is a flakiness source that has nothing
/// to do with the code under test, which is the kind A28's lesson says to remove rather than
/// explain away. Deliberately no `SO_REUSEADDR`: with it, a port already in use would probe as
/// free, which is the one answer this must not give.
@MainActor private func isLoopbackPortFree(_ port: UInt16) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return true }  // Cannot probe: assume free and let the bind decide.
    defer { close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return bound == 0
}

/// A port no other test in this run will pick, and which nothing else holds right now.
///
/// The caller still has to check that it bound: the probe above races with the rest of the
/// machine, and `HTTPServer.waitUntilReady()` is the only way to know.
@MainActor func allocateTestPort() -> UInt16 {
    // Skip past anything held, so a run that starts while another is in progress does not line up
    // with it. The bound is generous relative to the number of server tests in this target, and it
    // exists so that a machine that is busy cannot turn this into an infinite loop.
    for _ in 0..<256 {
        let candidate = UInt16(nextTestPort)
        nextTestPort += 1
        if isLoopbackPortFree(candidate) { return candidate }
    }
    // Nothing free in the range. Return the next number rather than trapping or looping: the
    // caller's readiness check reports a port that could not be bound, which is a clearer failure
    // than a crash inside the fixture.
    defer { nextTestPort += 1 }
    return UInt16(nextTestPort)
}
