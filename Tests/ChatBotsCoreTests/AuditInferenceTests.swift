// ChatBotsCoreTests — audit coverage for the conversion subprocess (A36)
//
// `SystemProcess.run` used to drain stdout to EOF and *then* stderr to EOF before it even
// looked at its own deadline. `readDataToEndOfFile` has no timeout, so a converter that
// filled both pipes deadlocked and one that hung — a crafted document, or a FIFO staged
// as an attachment — wedged the calling thread forever while the doc comment claimed the
// wait was bounded.
//
// These tests spawn real processes, but a shell rather than a model: they need no network,
// no weights and no private state, and they must not leave a process behind.

import ChatBotsCore
import Darwin
import Foundation
import Testing

@Suite("SystemProcess deadline and pipes (A36)")
struct AuditInferenceTests {

    @Test("A quick command returns its status and output")
    func quickCommand() throws {
        let result = try SystemProcess.run("/bin/echo", ["hello"])
        #expect(result.status == 0)
        #expect(String(data: result.output, encoding: .utf8) == "hello\n")
    }

    @Test("More than 64 KB on both streams does not deadlock")
    func bothPipesPastTheBuffer() throws {
        // 200 KB to stdout and 200 KB to stderr: each is more than the 64 KB pipe buffer,
        // so the old stdout-to-EOF-then-stderr order could never finish.
        let script = """
            /usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\0' 'o'
            /usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\0' 'e' >&2
            """
        let result = try SystemProcess.run("/bin/sh", ["-c", script], timeout: 20)
        #expect(result.status == 0)
        #expect(result.output.count == 200_000, "stdout should be drained in full")
        #expect(result.error.count == 200_000, "stderr should be drained in full")
    }

    @Test("A command that outlives the timeout is killed and reaped, not waited on")
    func deadlineKillsAndReaps() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appending(path: "child.pid")

        // `exec` keeps the recorded pid as the process that sleeps, so the check below
        // inspects the process `run` actually killed.
        let script = "echo $$ > \"\(pidFile.path)\"; exec sleep 30"
        let started = Date.now
        do {
            _ = try SystemProcess.run("/bin/sh", ["-c", script], timeout: 1)
            Issue.record("a command that outlives its timeout must not return success")
        } catch let error as DocumentError {
            guard case .unreadable(let message) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(message.contains("longer than 1 seconds"))
        }
        let elapsed = Date.now.timeIntervalSince(started)
        #expect(elapsed < 10, "the deadline should fire near 1s, took \(elapsed)s")

        // Reaped, not a zombie: a zombie still answers `kill(pid, 0)` with success.
        let pid = try #require(childPID(in: pidFile))
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "pid \(pid) must be gone, not a zombie")
    }

    @Test("A FIFO staged as an attachment cannot wedge the conversion")
    func blockingFIFOIsAbandoned() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appending(path: "staged.pipe")
        // Opening a FIFO for reading blocks until a writer appears, so `cat` hangs exactly
        // the way a staged path that is not a regular file would.
        #expect(mkfifo(fifo.path, 0o600) == 0)

        let started = Date.now
        do {
            _ = try SystemProcess.run("/bin/cat", [fifo.path], timeout: 1)
            Issue.record("reading a FIFO with no writer must time out")
        } catch let error as DocumentError {
            guard case .unreadable = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
        #expect(Date.now.timeIntervalSince(started) < 10)
    }

    /// A scratch directory private to one test.
    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "chatbots-system-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Read a pid the child wrote, waiting briefly for the file to appear.
    private func childPID(in url: URL) -> Int32? {
        let deadline = Date.now.addingTimeInterval(2)
        while Date.now < deadline {
            if let data = try? Data(contentsOf: url),
                let text = String(data: data, encoding: .utf8),
                let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            usleep(20_000)
        }
        return nil
    }
}
