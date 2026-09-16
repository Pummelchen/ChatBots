// ChatBotsCore — running a system tool and collecting what it said
//
// Extracted from `DocumentImport` when a second unit needed it (A155): it was written for the document
// converters, and the certificate store had grown its own copy that drained stdout to EOF before looking
// at stderr — the two-pipe deadlock this one already solved, and which the certificate path could reach
// because `openssl` writes as much as it likes to either pipe.

import Foundation

/// Runs a system tool and collects its output.
public enum SystemProcess {
    public struct Result {
        public var status: Int32
        public var output: Data
        public var error: String
    }

    /// How long a conversion may take before it is killed. Generous, because a large Word
    /// document on a busy Mac is not a hang — but bounded, because a broken file should not
    /// freeze the interface.
    public static let timeout: TimeInterval = 30

    /// How long a killed child gets to exit on SIGTERM before it is SIGKILLed.
    private static let killGrace: TimeInterval = 2

    /// Ceiling on what one run may read from the child's stdout.
    ///
    /// The same 64 MB an attachment may be, for the reason the image path already gives: the
    /// converted bytes are what travel, base64-encoded, inside one protocol message, and that cap is
    /// derived from this number. A container that expands past the ceiling of the file it came from
    /// is a decompression bomb rather than a document, and reading it costs memory this 8 GB Mac does
    /// not have (A197).
    public static let defaultMaximumOutputBytes = AttachmentLimits.defaultMaximumFileBytes

    public static func run(_ executable: String, _ arguments: [String]) throws -> Result {
        try run(executable, arguments, timeout: timeout)
    }

    /// Run with an explicit deadline and output ceiling.
    ///
    /// The default `run` uses the conversion timeout; this exists so a caller that knows
    /// the command is short — and the tests — can bound it without waiting out 30 seconds.
    public static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval,
        maximumOutputBytes: Int = SystemProcess.defaultMaximumOutputBytes
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // A tool that needs input must not inherit ours and wait on it.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw DocumentError.unreadable(error.localizedDescription)
        }

        // The read ends are non-blocking so the deadline is enforced by this thread rather
        // than by the child. `readDataToEndOfFile` has no timeout: a `textutil` that hangs on
        // a crafted document, or blocks opening a FIFO staged as an attachment, would hold
        // this thread forever, and draining stdout to EOF before even looking at stderr would
        // deadlock both once either pipe passed its 64 KB buffer.
        let outDescriptor = out.fileHandleForReading.fileDescriptor
        let errDescriptor = err.fileHandleForReading.fileDescriptor
        Self.makeNonBlocking(outDescriptor)
        Self.makeNonBlocking(errDescriptor)

        let deadline = Date.now.addingTimeInterval(timeout)
        let collected = Self.collectOutput(
            outDescriptor: outDescriptor, errDescriptor: errDescriptor, deadline: deadline,
            maximumOutputBytes: maximumOutputBytes)

        if collected.outputExceeded {
            // Kill and reap before reporting, exactly as the timeout path does: the child is very
            // likely still writing, and one zombie per oversized conversion is the leak A122 closed.
            Self.stop(process)
            process.waitUntilExit()
            throw DocumentError.unreadable(
                "the conversion produced more than \(maximumOutputBytes / 1_000_000) MB of text")
        }

        // A child that closes its output pipes but keeps running — or one whose pipes ended
        // before it did — still has to obey the deadline.
        var timedOut = collected.timedOut
        while process.isRunning, Date.now < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            timedOut = true
        }

        if timedOut {
            // Kill *and reap*. Without `waitUntilExit` the child would linger as a zombie,
            // one process-table entry per hung conversion, and a later PID could be reused.
            Self.stop(process)
            process.waitUntilExit()
            throw DocumentError.unreadable(
                "the conversion took longer than \(Int(timeout)) seconds")
        }

        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            output: collected.output,
            error: String(data: collected.error, encoding: .utf8) ?? ""
        )
    }

    /// What collecting a child's output ended with.
    private struct CollectedOutput {
        var output = Data()
        var error = Data()
        /// The deadline passed while at least one pipe was still open.
        var timedOut = false
        /// stdout reached its ceiling, so the run is a refusal rather than a result.
        var outputExceeded = false
    }

    /// Read both of a child's pipes until they close, the deadline passes, or stdout passes its
    /// ceiling.
    ///
    /// Both pipes are polled by this one thread, so filling either past its buffer cannot block the
    /// child and neither pipe's EOF is a precondition for reading the other.
    private static func collectOutput(
        outDescriptor: Int32, errDescriptor: Int32, deadline: Date, maximumOutputBytes: Int
    ) -> CollectedOutput {
        var collected = CollectedOutput()
        var outOpen = true
        var errOpen = true
        while outOpen || errOpen {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                collected.timedOut = true
                break
            }
            var descriptors: [pollfd] = []
            if outOpen {
                descriptors.append(pollfd(fd: outDescriptor, events: Int16(POLLIN), revents: 0))
            }
            if errOpen {
                descriptors.append(pollfd(fd: errDescriptor, events: Int16(POLLIN), revents: 0))
            }
            // Short poll slices, so a process that closes its pipes and then exits is
            // noticed promptly and the deadline is checked on every pass.
            let waitMilliseconds = Int32(min(max(remaining, 0.001), 0.25) * 1_000)
            let ready = descriptors.withUnsafeMutableBufferPointer { buffer in
                poll(buffer.baseAddress, nfds_t(buffer.count), waitMilliseconds)
            }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            for index in descriptors.indices {
                let revents = descriptors[index].revents
                guard revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 else { continue }
                if descriptors[index].fd == outDescriptor {
                    let outcome = Self.drain(
                        outDescriptor, into: &collected.output, limit: maximumOutputBytes)
                    outOpen = outcome.stillOpen
                    if outcome.overLimit {
                        collected.outputExceeded = true
                        break
                    }
                } else {
                    // Past the ceiling this end is left unread rather than emptied and discarded:
                    // the child then blocks on a full stderr, and the deadline is what ends it. Both
                    // memory and time stay bounded, and no tool that produces a usable document
                    // writes this much to stderr.
                    let outcome = Self.drain(
                        errDescriptor, into: &collected.error, limit: maximumOutputBytes)
                    errOpen = outcome.stillOpen && !outcome.overLimit
                }
            }
            if collected.outputExceeded { break }
        }
        return collected
    }

    /// Put a descriptor in non-blocking mode so `drain` returns on EAGAIN instead of
    /// waiting for the child.
    private static func makeNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    /// What one pass over a non-blocking read end found.
    private struct DrainOutcome {
        /// The writer has not closed its end of the pipe.
        var stillOpen = true
        /// At least `limit` bytes were available. The excess was read and dropped rather than
        /// accumulated, and the caller decides what that means for this pipe.
        var overLimit = false
    }

    /// Read what is available on `descriptor`, appending at most `limit` bytes to `data`.
    ///
    /// Bounded by `limit`, and that is the point: the old loop exited only on EOF or EAGAIN, and a
    /// child that keeps its pipe full satisfies neither — `read` keeps returning data and never sees
    /// the end — so a compressed document that expands without limit grew `data` without limit and
    /// the caller's deadline was unreachable while it did, because this loop never returned to have
    /// it checked. `limit` is what makes the loop return whatever the child does; the excess in the
    /// same read is dropped so a full pipe cannot block the child either (A197).
    private static func drain(_ descriptor: Int32, into data: inout Data, limit: Int) -> DrainOutcome {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var outcome = DrainOutcome()
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            if count > 0 {
                let room = limit - data.count
                if room >= count {
                    data.append(contentsOf: buffer[0..<count])
                } else {
                    if room > 0 { data.append(contentsOf: buffer[0..<room]) }
                    outcome.overLimit = true
                    return outcome
                }
            } else if count == 0 {
                outcome.stillOpen = false
                return outcome
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return outcome
            } else {
                outcome.stillOpen = false
                return outcome
            }
        }
    }

    /// Terminate and, if it will not go, kill `process`.
    ///
    /// Guarded by `isRunning` because the child may have exited on its own between the
    /// caller's check and here, and the PID could have been handed to something else. The
    /// caller must still call `waitUntilExit()` afterwards to reap whichever way this ends.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let graceDeadline = Date.now.addingTimeInterval(killGrace)
        while process.isRunning, Date.now < graceDeadline {
            usleep(20_000)
        }
        if process.isRunning {
            // Not another `terminate()`: a child that ignores SIGTERM must not be allowed
            // to outlive the conversion.
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }
}
