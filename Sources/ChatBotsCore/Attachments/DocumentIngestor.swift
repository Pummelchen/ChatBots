// ChatBotsCore — reading one file and applying the shared intake rules
//
// Split out of `Attachments.swift`, which held the document shapes, the intake, the limits and the
// vision gate in one 573-line file. The rules did not change; only the file they live in did.

import Foundation

/// Reads one document and returns its text or image bytes.
///
/// A protocol so the app can supply the real extractors while tests supply fakes, and so a
/// future format is one more implementation rather than a change here.
///
/// **The bytes, not a path.** The ingestor reads the file once, refuses anything that is not a
/// regular file, and refuses anything over the byte cap *as it is reading* — so what an extractor is
/// given is what has already been bounded. Handing over the path instead is what made the cap
/// unenforceable: the size came from a separate `stat`, so an unreadable one meant a cap of zero, a
/// file that grew between the two calls was read in full, and a FIFO — which has no size and never
/// ends — hung the conversion forever.
///
/// `url` still travels alongside, for the one extractor that hands a path to a system tool.
public protocol DocumentExtracting: Sendable {
    func extract(data: Data, from url: URL, kind: DocumentKind, limits: AttachmentLimits) throws
        -> AttachedDocument
}

/// Chooses an extractor per kind, and holds the shared rules — size limits and the
/// blank-result check — so no individual extractor has to remember them.
///
/// `@unchecked Sendable` because there is no mutable state to confine, so there is no lock,
/// actor or queue to name: both stored properties are `let` and nothing in the type writes
/// them. `extractors` is a dictionary of `DocumentExtracting`, which is `Sendable`, and the
/// shared `FileManager` is only ever read through `attributesOfItem(atPath:)`. What keeps it
/// true is that the type declares no `var` and exposes no setter, so `let` immutability is the
/// whole of the confinement — there is no second access site a comment could disagree with.
public final class DocumentIngestor: @unchecked Sendable {
    private let extractors: [DocumentKind: any DocumentExtracting]
    private let fileManager: FileManager

    public init(
        extractors: [DocumentKind: any DocumentExtracting],
        fileManager: FileManager = .default
    ) {
        self.extractors = extractors
        self.fileManager = fileManager
    }

    /// Add a file. Throws `DocumentError` with something the moderator can act on.
    public func add(url: URL, limits: AttachmentLimits = .standard) throws -> AttachedDocument {
        let name = url.lastPathComponent
        guard let kind = DocumentKind.forFilename(name) else {
            throw DocumentError.unsupportedType(name)
        }
        guard
            let extractor = extractors[kind]
                ?? extractors.first(where: { $0.key.extensions.contains(kind.extensions.first ?? "") })?.value
        else {
            throw DocumentError.unsupportedType(name)
        }

        // The stat is required, and it has to say "regular file". A failed stat used to mean a
        // size of zero, which meant a cap of zero; a FIFO or a device has no size and never reaches an
        // end, so a conversion from one either hung or ran unbounded.
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            throw DocumentError.unreadable("\(name)'s size could not be read")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DocumentError.notARegularFile(name)
        }
        if let size = (attributes[.size] as? NSNumber)?.intValue, size > limits.maximumFileBytes {
            throw DocumentError.tooLarge(name, limit: limits.maximumFileBytes)
        }

        // One read, bounded by the cap. The stat above is a courtesy — it refuses an obviously large
        // file without opening it — but *this* is the check that binds: a file that grew after the stat,
        // or one whose size the stat did not report, cannot be read past the limit, and the extractor
        // receives only bytes that were counted.
        let data = try Self.readBounded(url: url, name: name, limit: limits.maximumFileBytes)

        var document = try extractor.extract(data: data, from: url, kind: kind, limits: limits)
        document.name = name
        document.byteCount = data.count

        guard document.isUsable else {
            // An image with no bytes is a read failure; a document with no text is either
            // empty or a scan, and saying which is the difference between "pick another
            // file" and "this needs OCR".
            if kind == .pdf {
                throw DocumentError.needsOCR(name)
            }
            throw DocumentError.emptyText(name)
        }
        return document
    }

    /// A file's bytes, stopping one byte past the limit rather than reading whatever is there.
    ///
    /// `Data(contentsOf:)` is the wrong tool here: it reads to the end of whatever it was given, which
    /// for a special file is either forever or unbounded. This reads in chunks and refuses as soon as
    /// the limit is passed, so the ceiling is a property of the read rather than of a previous `stat`
    /// that could be raced. The file is a regular file by the time this runs — the caller has
    /// checked — so the read terminates.
    static func readBounded(url: URL, name: String, limit: Int) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw DocumentError.unreadable("\(name) could not be opened")
        }
        defer { try? handle.close() }

        var data = Data()
        // A chunk size rather than one call: `read(upToCount:)` returns what is available, so a file
        // larger than the limit arrives in pieces and the check below happens on each of them.
        while data.count <= limit {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 64 * 1024), !read.isEmpty else { break }
                chunk = read
            } catch {
                // A mid-file read error used to be swallowed by `try?`: the loop broke and the
                // bytes read so far were returned as the whole document, with nothing to tell a
                // short file from a failed read. The failure is raised instead.
                throw DocumentError.unreadable(
                    "\(name) could not be read: \(error.localizedDescription)")
            }
            data.append(chunk)
        }
        guard data.count <= limit else {
            throw DocumentError.tooLarge(name, limit: limit)
        }
        return data
    }
}
