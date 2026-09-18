// ChatBotsCoreTests — an upload does not hold the engine's main actor
//
// `EngineService` is `@MainActor` and every front end and the transport share it. A document
// conversion — a PDF extraction, or a `textutil` subprocess that may run to its 30-second
// timeout — was performed straight from `addAttachment` on that actor, so the one-second state
// poll, the website and the push loop all waited for it. These tests hold a conversion open on
// purpose: the engine has to answer a state request while the extraction is still running.
//
// The staging directory is asserted by path rather than by counting the temporary directory:
// the path the extractor was handed is recorded, so the cleanup is checked without racing the
// other suites that are also creating staging directories in the same process.

import ChatBotsCore
import Dispatch
import Foundation
import Synchronization
import Testing

/// An engine that does nothing, so these tests are about the upload path.
private actor QuietStub: LLMEngine {
    nonisolated let spec: AgentSpec
    init(spec: AgentSpec) { self.spec = spec }

    var isLoaded: Bool { true }
    var contextWindow: Int { spec.contextWindow }
    var currentSpec: AgentSpec { spec }
    func load() async throws {}
    func unload() async {}

    func generate(
        messages: [PromptMessage],
        tools: [any ToolProvider],
        onToolCall: @escaping @Sendable (String, String) async -> Void,
        onEvent: @escaping @Sendable (TurnEvent) async -> Void
    ) async throws -> String {
        "a reply"
    }
}

/// The staged file a controlled extractor was handed.
///
/// A class because `Mutex` is not `Copyable` and so cannot be a stored property of a struct
/// that has to be `Sendable`; the lock is the whole of the state and it is never copied.
private final class StagedFile: Sendable {
    private let value = Mutex<URL?>(nil)

    func record(_ url: URL) { value.withLock { $0 = url } }
    var recorded: URL? { value.withLock { $0 } }
}

/// An extractor the test drives: it records the file it was given, can announce that it has
/// started, can be held open, and can refuse.
private struct ControlledExtractor: DocumentExtracting {
    /// The staged file this extractor was handed, so the cleanup can be asserted by path.
    let staged: StagedFile
    /// Signalled on entry, so "the conversion has started" is a fact rather than a sleep.
    let entered: DispatchSemaphore?
    /// Waited on before returning, so the conversion can be held open across another request.
    let release: DispatchSemaphore?
    /// When set, the extractor refuses with this reason instead of returning a document.
    var failure: String?

    func extract(data: Data, from url: URL, kind: DocumentKind, limits: AttachmentLimits) throws
        -> AttachedDocument
    {
        staged.record(url)
        if let entered { _ = entered.signal() }
        if let release {
            // Bounded, so an old code path that blocks here cannot wedge the suite forever.
            _ = release.wait(timeout: .now() + 20)
        }
        if let failure { throw DocumentError.unreadable(failure) }
        return AttachedDocument(name: "", kind: kind, text: "the controlled document's text")
    }
}

/// Wait for a semaphore without blocking the caller's executor.
///
/// `DispatchSemaphore.wait` is unavailable from an async context, and waiting on the main actor
/// is exactly what these tests must not do, so the wait happens on a dispatch queue and the
/// result is bridged back.
private func waitForSignal(_ semaphore: DispatchSemaphore, timeout: DispatchTime) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            switch semaphore.wait(timeout: timeout) {
            case .success: continuation.resume(returning: true)
            case .timedOut: continuation.resume(returning: false)
            }
        }
    }
}

/// Wait until `flag` is set, or `timeout` passes. Off the main actor, so the task that sets it can run.
private func waitForSignal(_ flag: borrowing Atomic<Bool>, timeout: DispatchTime) async -> Bool {
    while DispatchTime.now() < timeout {
        if flag.load(ordering: .relaxed) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return flag.load(ordering: .relaxed)
}

@MainActor
private func makeService(ingestor: DocumentIngestor) -> EngineService {
    let specs = (0..<2).map { index -> AgentSpec in
        var spec = AgentSpec.seat(index: index)
        spec.displayName = "Seat \(index + 1)"
        return spec
    }
    let stubs = specs.map { QuietStub(spec: $0) }
    var configuration = ConversationEngine.Configuration()
    configuration.pace = .zero
    let seats = zip(specs, stubs).map { ConversationEngine.Seat(spec: $0, engine: $1) }
    let engine = ConversationEngine(seats: seats, configuration: configuration)
    engine.setTopic("A conversion test")
    let store = ConversationStore(
        directory: FileManager.default.temporaryDirectory
            .appending(path: "conversion-\(UUID().uuidString)"))
    return EngineService(engine: engine, store: store, attachmentIngestor: { ingestor })
}

/// The directory the engine staged an upload in, from the file the extractor was handed.
private func stagingDirectory(of staged: URL?) -> URL? {
    staged?.deletingLastPathComponent()
}

@Suite("A conversion does not block the engine")
struct DocumentConversionTests {

    /// The finding, made measurable: the conversion is held open, and a state request has to be
    /// answered while it is still running. On the old code the conversion ran on the main actor
    /// and the probe could not even start until it finished.
    ///
    /// The test is deliberately not on the main actor, so waiting for the conversion to begin
    /// does not depend on the actor the conversion is supposed to have left.
    @Test("The engine answers a state request while a document is converting")
    func stateIsAnsweredDuringConversion() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let extractor = ControlledExtractor(
            staged: StagedFile(), entered: entered, release: release)
        let ingestor = DocumentIngestor(extractors: [.plainText: extractor])
        let service = await MainActor.run { makeService(ingestor: ingestor) }

        let upload = Task {
            await service.handle(
                .addAttachment(filename: "slow.txt", contents: Data("some words".utf8)))
        }

        // Off the main actor on purpose: on the old code the conversion is inside a synchronous
        // call on that actor, and this wait must not be behind it.
        let started = await waitForSignal(entered, timeout: .now() + 10)
        #expect(started, "the conversion never started")

        let answered = Atomic<Bool>(false)
        let probe = Task { @MainActor in
            _ = await service.handle(.fetchState)
            answered.store(true, ordering: .relaxed)
        }
        // Bounded rather than a single 600 ms sample, for the reason the share-page test gives: the
        // question is whether the main actor can answer at all while the conversion is held open, and on
        // the old code it cannot — the release comes after this wait either way.
        let responsive = await waitForSignal(answered, timeout: .now() + 5)

        // Release before asserting: a failure on the old code must still finish rather than
        // leave the conversion and the actor blocked.
        _ = release.signal()
        _ = await probe.value
        let reply = await upload.value

        #expect(responsive, "the engine did not answer a state request while a conversion ran")
        #expect(reply.snapshot?.attachments.count == 1)
    }
}

@MainActor
@Suite("A staged upload leaves nothing behind", .serialized)
struct UploadStagingTests {

    @Test("A converted upload's staging directory is removed")
    func successfulConversionCleansUp() async {
        let staged = StagedFile()
        let ingestor = DocumentIngestor(extractors: [
            .plainText: ControlledExtractor(staged: staged, entered: nil, release: nil)
        ])
        let service = makeService(ingestor: ingestor)

        let reply = await service.handle(
            .addAttachment(filename: "notes.txt", contents: Data("hello".utf8)))

        #expect(reply.snapshot?.attachments.count == 1)
        guard let directory = stagingDirectory(of: staged.recorded) else {
            Issue.record("the extractor was never handed a staged file")
            return
        }
        #expect(
            !FileManager.default.fileExists(atPath: directory.path),
            "the staging directory outlived the upload")
    }

    @Test("A conversion that throws still returns its refusal and is cleaned up")
    func failedConversionRefusesAndCleansUp() async {
        let staged = StagedFile()
        let extractor = ControlledExtractor(
            staged: staged, entered: nil, release: nil, failure: "the extractor said no")
        let ingestor = DocumentIngestor(extractors: [.plainText: extractor])
        let service = makeService(ingestor: ingestor)

        let reply = await service.handle(
            .addAttachment(filename: "broken.txt", contents: Data("hello".utf8)))

        // The same sentence the synchronous path produced: the refusal is not changed by the
        // move off the actor.
        #expect(reply.refusal == "Could not read the file: the extractor said no")
        guard let directory = stagingDirectory(of: staged.recorded) else {
            Issue.record("the extractor was never handed a staged file")
            return
        }
        #expect(
            !FileManager.default.fileExists(atPath: directory.path),
            "a failed conversion left its staging directory behind")
    }
}
