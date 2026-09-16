// ChatBotsCoreTests — attachment intake bounds what it reads
//
// Three defects in one place. The size came from `try? attributesOfItem … ?? 0`, so a stat that failed
// meant a cap of zero and the file was then read unbounded. The file was opened again after that check,
// so anything that changed in between was read in full. And nothing looked at the *kind* of file, so a
// FIFO — no size, no end — was passed to `Data(contentsOf:)`, which waits for a writer that never
// comes: the conversion hung forever.
//
// The ingestor now requires a stat, requires a regular file, and reads the bytes once, in chunks,
// stopping one byte past the cap. What an extractor receives is what has already been counted, which is
// why the protocol takes bytes rather than a path.

import Darwin
import Foundation
import Synchronization
import Testing

@testable import ChatBotsCore

@Suite("Attachment intake bounds what it reads")
struct AttachmentIntakeTests {

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "intake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func ingestor() -> DocumentIngestor { SystemDocumentExtractor.ingestor }

    @Test("A regular file is still converted, and its byte count is the bytes that were read")
    func aRegularFileIsConverted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "note.txt")
        try Data("hello there".utf8).write(to: url)

        let document = try ingestor().add(url: url)

        #expect(document.name == "note.txt")
        #expect(document.text.contains("hello there"))
        #expect(document.byteCount == 11, "the count is what was read, not what a stat claimed")
    }

    @Test("A FIFO is refused, and named as what it is")
    func aFIFOIsRefused() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "pipe.txt")
        #expect(mkfifo(url.path, 0o600) == 0, "could not create the FIFO this test is about")

        // What Foundation does with a FIFO is worth recording, because the finding assumed it blocked and
        // it does not: `Data(contentsOf:)` refuses one immediately, with "you don't have permission to
        // view it" — a permission error for a file the user can read, which is the wrong sentence and the
        // reason the intake checks the kind itself.
        //
        // The read still runs detached and bounded here: a future Foundation that *did* wait for a writer
        // must not be able to wedge the suite on a test of all things.
        let finished = Mutex(false)
        let failure = Mutex<DocumentError?>(nil)
        let intake = Task.detached {
            do {
                _ = try ingestor().add(url: url)
            } catch let error as DocumentError {
                failure.withLock { $0 = error }
            } catch {
                failure.withLock { $0 = nil }
            }
            finished.withLock { $0 = true }
        }
        try? await Task.sleep(for: .seconds(1))

        #expect(finished.withLock { $0 }, "the intake never answered: it is waiting on the FIFO")
        #expect(failure.withLock { $0 } == .notARegularFile("pipe.txt"))
        // If it did block, the task is still parked in `open(2)`; releasing a writer lets it finish so a
        // failure does not leave a thread behind for the rest of the run.
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sh")
        writer.arguments = ["-c", "echo x > \(url.path)"]
        try? writer.run()
        _ = await intake.value
    }

    @Test("A directory is refused as a file")
    func aDirectoryIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "folder.txt")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        #expect(throws: DocumentError.notARegularFile("folder.txt")) {
            _ = try ingestor().add(url: url)
        }
    }

    @Test("A path whose size cannot be read is refused, not read unbounded")
    func anUnreadableSizeIsRefused() throws {
        // The file was deleted between being offered and being attached. The old `try? … ?? 0` made
        // that a size of zero — a cap of zero — and the read that followed was unbounded.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "missing.txt")

        do {
            _ = try ingestor().add(url: url)
            Issue.record("a missing file was converted")
        } catch let error as DocumentError {
            guard case .unreadable(let reason) = error else {
                Issue.record("expected the size refusal, got \(error)")
                return
            }
            #expect(reason.contains("size could not be read"))
        }
    }

    @Test("A symbolic link is not a regular file, whether or not it dangles")
    func aSymbolicLinkIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "real.txt")
        try Data("hello".utf8).write(to: target)
        let link = directory.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // `attributesOfItem` reports the link itself rather than following it, which is what makes the
        // kind check able to refuse it: what the read would otherwise open is a path outside the one
        // that was chosen.
        #expect(throws: DocumentError.notARegularFile("link.txt")) {
            _ = try ingestor().add(url: link)
        }
    }

    @Test("The cap is enforced by the read, not by a size the file reported")
    func theCapIsEnforcedByTheRead() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "text.txt")
        try Data(repeating: 0x41, count: 4_096).write(to: url)

        #expect(throws: DocumentError.tooLarge("text.txt", limit: 1_024)) {
            _ = try DocumentIngestor.readBounded(url: url, name: "text.txt", limit: 1_024)
        }
        let all = try DocumentIngestor.readBounded(url: url, name: "text.txt", limit: 4_096)
        #expect(all.count == 4_096, "a file exactly at the limit is inside it")
    }

    @Test("A file over the cap is refused before it is converted")
    func anOversizedFileIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "big.txt")
        try Data(repeating: 0x42, count: 2_048).write(to: url)

        #expect(throws: DocumentError.tooLarge("big.txt", limit: 1_024)) {
            _ = try ingestor().add(url: url, limits: AttachmentLimits(maximumFileBytes: 1_024))
        }
    }
}
