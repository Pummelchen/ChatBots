// ChatBotsCore — reading the moderator's files
//
// In the core rather than a front end, so the SwiftUI app, the HTTP server and the web page
// all read a document the same way. There is one implementation of "what is in this PDF".
//
// It uses the system's own converters: PDFKit for PDFs and `textutil` for the document
// formats. That is deliberate over hand-written parsers — `textutil` is part of macOS and
// has read Word, RTF, ODT and HTML for years, and a hand-rolled `.docx` unzipper would be a
// fraction as capable and a great deal more code to get wrong.

import Darwin
import Foundation
import PDFKit

/// Reads a plain text file, honouring a byte-order mark and falling back sensibly.
///
/// Markdown is included here: it is text, and converting it would strip the structure that
/// makes it useful to a model, so it is passed through as written.
public struct PlainTextExtractor: DocumentExtracting {
    public func extract(url: URL, kind: DocumentKind, limits: AttachmentLimits) throws -> AttachedDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DocumentError.unreadable(error.localizedDescription)
        }

        // UTF-8 first, then the encodings a Mac is most likely to meet. Latin-1 is last
        // because it accepts any byte, so it would mask a genuine encoding problem.
        let text =
            String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        return fit(text, kind: kind, in: limits)
    }

    /// Shared shortening, so every extractor applies the same budget and records it.
    ///
    /// `kind` is passed in rather than assumed: this serves both plain text and Markdown,
    /// and returning `.plainText` for a `.md` file would misreport what the moderator added.
    public func fit(_ text: String, kind: DocumentKind, in limits: AttachmentLimits) -> AttachedDocument {
        // Null bytes appear in files that are not really text; they confuse models and
        // serve no purpose here.
        let cleaned = text.replacingOccurrences(of: "\u{0}", with: "")
        if cleaned.count > limits.maximumTextCharacters {
            return AttachedDocument(
                name: "", kind: kind, text: String(cleaned.prefix(limits.maximumTextCharacters)),
                wasTruncated: true)
        }
        return AttachedDocument(name: "", kind: kind, text: cleaned)
    }
}

/// Reads a PDF's text layer.
public struct PDFTextExtractor: DocumentExtracting {
    public func extract(url: URL, kind: DocumentKind, limits: AttachmentLimits) throws -> AttachedDocument {
        guard let document = PDFDocument(url: url) else {
            throw DocumentError.unreadable("the PDF could not be opened")
        }

        var pages: [String] = []
        var characters = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let pageText = page.string else { continue }
            // Stop reading once the budget is spent rather than extracting a whole
            // book to then throw most of it away.
            if characters + pageText.count > limits.maximumTextCharacters {
                pages.append(String(pageText.prefix(max(0, limits.maximumTextCharacters - characters))))
                characters = limits.maximumTextCharacters
                break
            }
            pages.append(pageText)
            characters += pageText.count
        }

        let text = pages.joined(separator: "\n\n")
        return AttachedDocument(
            name: "", kind: .pdf, text: text,
            pageCount: document.pageCount,
            wasTruncated: characters >= limits.maximumTextCharacters
        )
    }
}

/// Converts Word, RTF, ODT, HTML and WebArchive with the system's own converter.
public struct TextutilExtractor: DocumentExtracting {
    public func extract(url: URL, kind: DocumentKind, limits: AttachmentLimits) throws -> AttachedDocument {
        let result = try SystemProcess.run(
            "/usr/bin/textutil",
            ["-convert", "txt", "-stdout", "-encoding", "UTF-8", url.path]
        )
        guard result.status == 0 else {
            let reason = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DocumentError.unreadable(reason.isEmpty ? "\(kind.label) conversion failed" : reason)
        }
        // `textutil` writes UTF-8 with `-encoding UTF-8`; anything else would be surprising.
        guard let text = String(data: result.output, encoding: .utf8) else {
            throw DocumentError.unreadable("the converted text was not valid UTF-8")
        }
        return PlainTextExtractor().fit(text, kind: kind, in: limits)
    }
}

/// Reads an image's bytes, for seats that can see.
public struct ImageExtractor: DocumentExtracting {
    public func extract(url: URL, kind: DocumentKind, limits: AttachmentLimits) throws -> AttachedDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DocumentError.unreadable(error.localizedDescription)
        }
        let lowered = url.pathExtension.lowercased()
        return AttachedDocument(
            name: "", kind: .image, text: "", byteCount: data.count, imageData: data
        ).withKindHint(lowered)
    }
}

private extension AttachedDocument {
    /// Images keep their kind; the hint exists only so a future format (HEIC, for instance)
    /// could be converted to a universally readable one at this point.
    func withKindHint(_ extension: String) -> AttachedDocument { self }
}

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

    public static func run(_ executable: String, _ arguments: [String]) throws -> Result {
        try run(executable, arguments, timeout: timeout)
    }

    /// Run with an explicit deadline.
    ///
    /// The default `run` uses the conversion timeout; this exists so a caller that knows
    /// the command is short — and the tests — can bound it without waiting out 30 seconds.
    public static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval
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

        var outputData = Data()
        var errorData = Data()
        var outOpen = true
        var errOpen = true
        let deadline = Date.now.addingTimeInterval(timeout)
        var timedOut = false

        // Both pipes are drained by this one thread and polled together, so filling either
        // past its buffer can no longer block the child and neither pipe's EOF is a
        // precondition for reading the other.
        while outOpen || errOpen {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                timedOut = true
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
                    outOpen = Self.drain(outDescriptor, into: &outputData)
                } else {
                    errOpen = Self.drain(errDescriptor, into: &errorData)
                }
            }
        }

        // A child that closes its output pipes but keeps running — or one whose pipes ended
        // before it did — still has to obey the deadline.
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
            output: outputData,
            error: String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    /// Put a descriptor in non-blocking mode so `drain` returns on EAGAIN instead of
    /// waiting for the child.
    private static func makeNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    /// Read everything currently available on `descriptor`, appending it to `data`.
    ///
    /// Returns `true` while the writer is still open, `false` once it has closed the pipe.
    private static func drain(_ descriptor: Int32, into data: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                return false
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return true
            } else {
                return false
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

/// The extractors this app ships with.
public enum SystemDocumentExtractor {
    public static var ingestor: DocumentIngestor {
        let text = PlainTextExtractor()
        let pdf = PDFTextExtractor()
        let documents = TextutilExtractor()
        let image = ImageExtractor()
        return DocumentIngestor(extractors: [
            .plainText: text,
            .markdown: text,
            .pdf: pdf,
            .word: documents,
            .richText: documents,
            .html: documents,
            .image: image,
        ])
    }

    /// Add files, keeping the ones that worked and describing the ones that did not.
    ///
    /// One bad file should not discard the good ones, so this reports per file.
    public static func add(
        urls: [URL], limits: AttachmentLimits = .standard
    ) -> (documents: [AttachedDocument], failures: [String]) {
        var documents: [AttachedDocument] = []
        var failures: [String] = []
        for url in urls {
            do {
                documents.append(try ingestor.add(url: url, limits: limits))
            } catch let error as DocumentError {
                failures.append(error.errorDescription ?? "\(url.lastPathComponent) could not be read.")
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (documents, failures)
    }
}
