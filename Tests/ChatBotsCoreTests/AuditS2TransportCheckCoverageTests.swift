// ChatBotsCoreTests — the installer's smoke test, actually run (A170).
//
// `TransportCheck` was the least-covered file the finding names (24.33% of lines): it starts a real
// listener, connects a real client, does three round trips, checks that a bad seat is refused, watches
// for a state push and an output event, and reports all of it. Only its arithmetic and its report
// formatting had ever been executed.
//
// Driving the whole channel from here needs one thing the check does not do for itself: the child it
// spawns has to use the identity the check pins. See A215, which is where that is recorded — the test
// below covers the branch that fails before any of it, and the passing path is blocked on A215 rather
// than on a missing fixture.
//
// Serialised with the transport gate, because the check is a real QUIC listener like the five suites
// that gate is for.

import ChatBotsCore
import Foundation
import Testing

@MainActor
@Suite(
    "The installer's transport smoke test (A170)", .serialized, TransportSerialized()
)
struct TransportCheckCoverageTests {

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "transport-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The engine the check spawns: a sibling of the test bundle, because the check's default —
    /// the process's own executable — is the test binary when a test drives it.
    private func engineExecutable() -> URL? {
        // Not `arguments[0]`: under `swift test` that is the SwiftPM testing helper, and the bundle
        // binary is named later in the arguments.
        guard
            let binary = ProcessInfo.processInfo.arguments.first(where: {
                $0.contains(".xctest/Contents/MacOS/")
            })
        else { return nil }
        let products = URL(fileURLWithPath: binary).deletingLastPathComponent()  // …/Contents/MacOS
            .deletingLastPathComponent()  // …/Contents
            .deletingLastPathComponent()  // …/<Bundle>.xctest
            .deletingLastPathComponent()  // …/Products/<config>
        let candidate = products.appending(path: "chatbots-cli")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    @Test("A certificate that cannot be made is reported, not thrown, and the check stops there")
    func aCertificateFailureIsReported() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A *file* where the directory should be: openssl cannot write the key and certificate, so
        // `loadOrCreate` throws and the check records it rather than crashing or hanging.
        let blocked = directory.appending(path: "not-a-directory")
        try Data("in the way".utf8).write(to: blocked)

        let report = await TransportCheck.run(
            in: blocked, port: allocateTestPort(), timeout: .seconds(5),
            executable: engineExecutable())

        #expect(!report.succeeded)
        #expect(!report.connected)
        #expect(report.roundTrips == 0)
        #expect(report.failures.contains { $0.hasPrefix("certificate:") },
            "the refusal is named as a certificate problem: \(report.failures)")
        #expect(report.describe().contains("certificate"))
    }
}
