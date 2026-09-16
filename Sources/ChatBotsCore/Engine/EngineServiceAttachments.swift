// ChatBotsCore — staging and reading an uploaded document
//
// Split out of `EngineService.swift`, which held the dispatch, the attachment pipeline, the
// snapshot and the line-up commands in one 814-line file. What lives here is the one route
// untrusted bytes take into the engine: the name checks, the private staging directory, the
// off-actor conversion and the ceiling that has to hold even when two uploads race.

import Foundation

/// The result of reading a staged upload, in a form that can cross back from the conversion
/// task without carrying a non-`Sendable` error across the actor boundary.
///
/// `DocumentError` is a public enum with `String` payloads and is not declared `Sendable`, and
/// `any Error` is not either, so the failure is turned into the sentence the caller would have
/// been given anyway, off the actor, where the thrown type is known.
private enum StagedConversion: Sendable {
    case document(AttachedDocument)
    case refused(String)
}

extension EngineService {

    /// How many files one conversation may carry.
    ///
    /// Enforced here rather than in the engine, because it is a front-end rule about how much material a
    /// room is asked to read. It has to be checked **after** the conversion as well as before it: the
    /// guard at the top of `addAttachment` runs before the `await`, so uploads that arrive together all
    /// saw the same count and all passed it, and the room ended up over the ceiling by however many
    /// arrived at once.
    static let maximumAttachments = 24

    /// Stage an upload and read it.
    ///
    /// Written to a temporary file because the extractors take a URL — the same path the app
    /// uses for a dragged file — so there is one implementation of "what is in this document"
    /// rather than a second one for bytes.
    ///
    /// **`filename` is caller-supplied data, not a name.** It arrives verbatim in the request
    /// body of `POST /api/attachments` and in the WebTransport `addAttachment` command, so it
    /// cannot be trusted to describe a location. It is reduced to a single path component and
    /// refused unless what remains is a usable name; the destination is then checked to be
    /// inside the per-upload directory this method created. The upload can only ever be written
    /// inside that directory, whatever the caller sends — without this, a name like
    /// `../../../../Users/<user>/Library/LaunchAgents/x.plist` wrote attacker-controlled bytes
    /// outside it, and the file outlived the `defer` that removes the staging directory.
    /// **The conversion runs off this actor.** `EngineService` is `@MainActor` and every front
    /// end and the transport share it, so converting here — a PDF extraction or a `textutil`
    /// subprocess that may run to its 30-second timeout — froze the one-second state poll, the
    /// website and the push loop for as long as it took. The staging, the name checks and the
    /// engine mutation stay on the actor; only `DocumentIngestor.add` moves to a detached task.
    /// `DocumentIngestor` is `Sendable` and the bytes cross as the file the extractors already
    /// take, so the public API is unchanged.
    ///
    /// The `defer` still removes the staging directory, and it is still correct across the
    /// move: `Task.value` is awaited before it runs, so the file outlives the read and not the
    /// request. A conversion that throws is reported as the same refusal it was before.
    ///
    /// Internal rather than private: `handle(_:)` dispatches to it from `EngineService.swift`.
    func addAttachment(filename: String, contents: Data) async -> EngineReply {
        guard engine.canAttachFiles else {
            return .refused("source material must be added before the conversation starts")
        }
        guard engine.attachments.count < Self.maximumAttachments else {
            return .refused("too many attached files")
        }

        guard let name = Self.stagedAttachmentName(filename) else {
            // Not silently renamed: a name that cannot be used is something the caller is told
            // about, and the raw value is not echoed because it is untrusted too.
            return .refused("the uploaded file name is not a usable name")
        }

        let staged: StagedUpload
        do {
            staged = try Self.stageUpload(contents: contents, name: name)
        } catch {
            return .refused(error.localizedDescription)
        }
        let directory = staged.directory
        defer { try? FileManager.default.removeItem(at: directory) }

        // The belt to the validation's braces: even if the name check above were ever bypassed,
        // the write is refused unless the destination really is a direct child of the directory
        // created a moment ago.
        let temporary = staged.file
        guard Self.isDirectChild(temporary, of: directory) else {
            return .refused("the uploaded file name is not a usable name")
        }

        // Detached rather than a structured child, so the read is not cancelled by a caller
        // that goes away — the staged file is removed when this method returns, and returning
        // while the conversion still held the path would delete it under the extractor.
        let conversion = await Task.detached(
            priority: .userInitiated
        ) { [attachmentIngestor] () -> StagedConversion in
            do {
                let ingestor = try attachmentIngestor()
                return .document(try ingestor.add(url: temporary))
            } catch let error as DocumentError {
                return .refused(error.errorDescription ?? "the file could not be read")
            } catch {
                return .refused(error.localizedDescription)
            }
        }.value

        switch conversion {
        case .refused(let reason):
            return .refused(reason)
        case .document(let document):
            guard !document.kind.isImage || engine.allSeatsSupportVision else {
                return .refused("images need every seat to support vision")
            }
            // Counted again here, on the main actor with the append below and after the `await`, because
            // that is the only place the count cannot have moved: the guard at the top of this method ran
            // before the conversion, so uploads arriving together all passed it.
            guard engine.attachments.count < Self.maximumAttachments else {
                return .refused("too many attached files")
            }
            guard engine.setAttachments(engine.attachments + [document]) else {
                return .refused(Self.sourceMaterialIsFixed)
            }
            return .state(snapshot())
        }
    }

    /// One staged upload: the private directory it lives in and the file inside it.
    struct StagedUpload {
        var directory: URL
        var file: URL
    }

    /// Why an upload could not be staged on disk.
    enum UploadStagingError: LocalizedError {
        case cannotCreateDirectory(String)
        case cannotWriteFile

        var errorDescription: String? {
            switch self {
            case .cannotCreateDirectory(let reason): "could not stage the upload: \(reason)"
            case .cannotWriteFile: "could not stage the upload"
            }
        }
    }

    /// Write the uploaded bytes into a directory of their own, readable only by this user.
    ///
    /// Two rules live here rather than inline, and both are about the window between creating a file and
    /// being able to trust it:
    ///
    /// - **Owner-only, from the start.** The default mode leaves the directory and the file inside it
    ///   readable by every user on the machine for as long as the conversion takes — up to the extractor's
    ///   30-second deadline, for a document that is the moderator's own material.
    /// - **Created with its final mode rather than written and then chmodded.** Between those two steps
    ///   the file is on disk under the process umask, which is exactly the window a chmod-after-write
    ///   leaves open. `Data.write(to:)` used to be the whole of it, with no mode at all.
    ///
    /// The directory is removed if the write fails, so a failed staging leaves nothing behind: the caller
    /// registers its `defer` only once this has returned.
    static func stageUpload(contents: Data, name: String) throws -> StagedUpload {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "chatbots-upload-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw UploadStagingError.cannotCreateDirectory(error.localizedDescription)
        }
        let file = directory.appending(path: name)
        guard
            FileManager.default.createFile(
                atPath: file.path, contents: contents,
                attributes: [.posixPermissions: 0o600])
        else {
            try? FileManager.default.removeItem(at: directory)
            throw UploadStagingError.cannotWriteFile
        }
        return StagedUpload(directory: directory, file: file)
    }

    /// The name an upload is staged under, or `nil` when what the caller sent cannot be used.
    ///
    /// The value is untrusted data from the request body, not a path. `lastPathComponent` keeps
    /// the final component — which is also the display name the extractor reports — and the
    /// checks below refuse anything that is still not a usable name. On Darwin a backslash is
    /// not a separator, so it survives the reduction and has to be refused explicitly; a NUL or
    /// other control character could truncate the path at the filesystem boundary; and a cap
    /// keeps a pathological name out of a path that would fail there anyway.
    static func stagedAttachmentName(_ filename: String) -> String? {
        let name = (filename as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        guard !name.contains("/"), !name.contains("\\") else { return nil }
        guard name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        // A few hundred bytes is plenty for a file name; 255 is the usual single-component cap.
        guard name.utf8.count <= 255 else { return nil }
        return name
    }

    /// Whether `url` is a direct child of `directory`, compared by resolved path components.
    ///
    /// A string prefix test would be fooled by a sibling whose name merely starts with the same
    /// characters, so this compares whole components after both sides are standardised and have
    /// had symlinks resolved. The write happens after the directory exists, so resolving the
    /// parent is resolving a real directory rather than a guess.
    static func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let target = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard target.count == base.count + 1 else { return false }
        return Array(target.dropLast()) == base
    }
}
