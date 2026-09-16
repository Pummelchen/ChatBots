// ChatBotsCoreTests — a failure has to say what went wrong (A216)
//
// The client reported every connect failure through `error.localizedDescription`, and the
// transport's errors are `CustomStringConvertible` rather than `LocalizedError`. Foundation bridges
// those to "The operation couldn't be completed. (… error 2.)", so the installer's smoke test printed
// `error 2` — the case at index 2, `invalidTransport` — while the sentence naming the setting it had
// rejected sat unread in the error's own `description`. Finding the cause of A215 took a debugging
// round that quoting the error would have avoided.

import Foundation
import Testing

@testable import ChatBotsCore

@Suite("A transport failure says what it was (A216)")
struct ClientErrorDescriptionTests {

    /// The shape the transport's own errors have: a Swift value type that describes itself.
    private enum Refusal: Error, CustomStringConvertible {
        case datagramUnavailable

        var description: String { "QUIC DATAGRAM is not available on this connection" }
    }

    /// A Swift error that carries a reason the way Foundation expects one to.
    private struct Reason: LocalizedError {
        var errorDescription: String? { "the engine refused the request" }
    }

    private enum Nameless: Error { case something }

    @Test("An error that describes itself is quoted, not reduced to a code")
    func selfDescribingErrorsKeepTheirText() {
        let described = ErrorText.describe(Refusal.datagramUnavailable)

        #expect(described == "QUIC DATAGRAM is not available on this connection")
        #expect(!described.contains("error 2"), "the code alone was the whole problem")
    }

    @Test("A LocalizedError is preferred, because that is the text Foundation would show")
    func localizedErrorsKeepTheirReason() {
        #expect(ErrorText.describe(Reason()) == "the engine refused the request")
    }

    @Test("A Foundation error keeps the description Foundation gives it")
    func foundationErrorsAreLeftAlone() {
        // `NSError` also describes itself, but its `description` is "Error Domain=… Code=…", which is
        // the same thing `localizedDescription` bridges; the client's job is not to improve on what
        // the platform already formats.
        let error = CocoaError(.fileNoSuchFile) as NSError
        let described = ErrorText.describe(error)

        #expect(described == error.localizedDescription)
        #expect(described != String(describing: error))
    }

    @Test("An error with nothing to say still produces text")
    func silentErrorsStillProduceText() {
        // The last resort, so a report line is never empty — `cannotConnect("")` reads as a
        // transport that failed for no reason at all.
        #expect(!ErrorText.describe(Nameless.something).isEmpty)
    }
}
