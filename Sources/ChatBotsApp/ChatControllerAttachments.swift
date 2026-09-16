// ChatBotsApp — the source material a conversation is given
//
// Everything the moderator attaches — documents and images — and the rule that governs it:
// the engine holds the file and does the reading, so this side never keeps or re-uploads a
// body. What settings restore is therefore the engine's *description* of a file, which may
// outlive the engine that read it; this is where that gap is tracked and reported.

import AppKit
import ChatBotsCore
import Foundation
import UniformTypeIdentifiers

@MainActor
extension ChatController {

    /// Documents and images the moderator has added: what the engine is holding, plus anything
    /// restored from settings that the engine could not be given (see `setAttachments`).
    ///
    /// Rebuilt from the state rather than kept separately, so the app and the engine cannot
    /// disagree about what is attached. The extracted text is the engine's and is not sent
    /// back, so a rebuilt document carries the engine's own summary and token count rather than
    /// recomputing them from fields this side never had — recomputing produced "0 words" on
    /// every chip. The body itself is not here, which is why the chip does not
    /// offer to show it.
    ///
    /// An image's bytes are not among the fields the engine sends either: this used to
    /// decode `imageBase64` back into `imageData`, and nothing in the app ever read it — the chip
    /// draws the document's kind as a symbol, not the picture. The engine keeps the bytes; sending
    /// them cost a base64 copy of every attached image in every state push.
    public var attachments: [AttachedDocument] {
        let held = (lastSnapshot?.attachments ?? []).map { attachment in
            AttachedDocument(
                id: UUID(uuidString: attachment.id) ?? UUID(),
                name: attachment.name,
                kind: DocumentKind(rawValue: attachment.kind) ?? .plainText,
                text: "",
                byteCount: 0,
                pageCount: nil,
                wasTruncated: attachment.wasTruncated,
                imageData: nil,
                engineSummary: attachment.summary,
                engineTokens: attachment.tokens)
        }
        guard !restoredAttachments.isEmpty else { return held }
        // A restored file the engine has since been given — an adopted engine that already had
        // it, or the moderator re-added it — is the engine's; the stored copy is superseded by
        // name. Matching by id would show the same file twice, since a re-upload gets a new id.
        let heldNames = Set(held.map(\.name))
        return held + restoredAttachments.filter { !heldNames.contains($0.name) }
    }

    /// The attachments the models cannot currently see: restored from a saved conversation but
    /// not loaded into this engine.
    ///
    /// The chip renders from this rather than from the banner, so dismissing the notice cannot
    /// leave a chip implying the models can read material they cannot. The state is
    /// derived from `restoredAttachments`, which is what `setAttachments` and `addFiles` keep in
    /// step, so a file that is re-added leaves this set immediately.
    public var attachmentsNotLoaded: Set<UUID> {
        Set(restoredAttachments.map(\.id))
    }

    /// Push the attachment set to the engine.
    ///
    /// Adding a file already happened over the request channel, so this only reconciles the
    /// engine with the app's view — it removes what is gone. Adding here would re-upload, which
    /// a restored document cannot be: the app never kept its body.
    ///
    /// An attachment is kept when its name is wanted as well as when its id is, because a
    /// restored document carries the id of whichever engine first accepted it. Matching on ids
    /// alone would delete the engine's copy of a file the moderator restored.
    private func syncAttachments(_ documents: [AttachedDocument]) {
        let wantedIDs = Set(documents.map(\.id.uuidString))
        let wantedNames = Set(documents.map(\.name))
        for present in lastSnapshot?.attachments ?? [] {
            if wantedIDs.contains(present.id) { continue }
            if wantedNames.contains(present.name) { continue }
            run { client in _ = try await client.send(.removeAttachment(id: present.id)) }
        }
    }

    /// Keep the "restored but not loaded" notice in step with `restoredAttachments`.
    ///
    /// It is a warning the moderator has to read, not a transient error: until the file is
    /// added again the models cannot see it, and the list is kept so the relaunch that dropped
    /// it is not also the relaunch that forgot it. Nothing is shown once every restored file is
    /// either loaded or removed.
    func refreshAttachmentRestoreNotice() {
        let notice: String?
        if restoredAttachments.isEmpty {
            notice = nil
        } else {
            let count = restoredAttachments.count
            let names = restoredAttachments.map(\.name).joined(separator: ", ")
            notice =
                "\(count) saved source file\(count == 1 ? "" : "s") could not be loaded into this "
                + "engine. The file itself was not kept, only what was read from it, so the "
                + "models cannot see \(count == 1 ? "it" : "them") until "
                + "\(count == 1 ? "it is" : "they are") added again: \(names)"
        }
        // Replace a previous notice, but never overwrite a different message the moderator has
        // not read yet.
        if errorBanner == nil || errorBanner == attachmentRestoreNotice {
            errorBanner = notice
        }
        attachmentRestoreNotice = notice
    }

    /// True when every seat's model can accept images, which is what decides whether the
    /// image part of the interface is offered at all. A conversation where one participant
    /// cannot see the picture is worse than being told upfront that images are unavailable.
    public var allSeatsSupportVision: Bool {
        panes.allSatisfy { $0.spec.visionSupport.allowsImages }
    }

    /// Which seats cannot see, for the explanation shown when images are unavailable.
    public var seatsWithoutVision: [String] {
        panes.filter { !$0.spec.visionSupport.allowsImages }.map { $0.spec.displayName }
    }

    /// Files may only be added before the conversation starts: the material is context for
    /// the discussion, and adding it midway would leave earlier turns ignorant of it.
    public var canAttachFiles: Bool { turns.isEmpty && !isRunning }

    /// Add files through the standard open panel.
    @discardableResult
    public func attachFiles(allowImages: Bool? = nil) -> Int {
        guard canAttachFiles else {
            errorBanner = "Source material must be added before the conversation starts."
            return 0
        }
        let imagesAllowed = allowImages ?? allSeatsSupportVision

        let panel = NSOpenPanel()
        panel.title = "Add Source Material"
        panel.message =
            imagesAllowed
            ? "Choose documents or images. Text is extracted so the models can read it."
            : "Choose documents. Images need every seat to support vision."
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        var types: [UTType] = [.plainText, .pdf, .rtf, .html]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        if let word = UTType(filenameExtension: "docx") { types.append(word) }
        if let legacyWord = UTType(filenameExtension: "doc") { types.append(legacyWord) }
        if imagesAllowed { types.append(contentsOf: [.png, .jpeg, .bmp, .gif, .tiff, .heic]) }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK else { return 0 }
        return addFiles(panel.urls, allowImages: imagesAllowed)
    }

    /// Add already-chosen files. Returns how many were accepted.
    ///
    /// The file is sent to the engine and extracted there, rather than being read here.
    ///
    /// That is a change of direction from the in-process design, and it is deliberate: the
    /// engine holds the attachment, so the engine must be the one that decides what is in the
    /// file. Extracting here as well would mean two implementations of "what does this
    /// document say" that could disagree, and the app's copy would be the one on screen while
    /// the engine used its own.
    ///
    /// The cost is that the whole file crosses the wire. On loopback, for a document a person
    /// chose by hand, that is nothing.
    /// Returns how many files were accepted for upload.
    ///
    /// The upload runs in the background: reading a large PDF and sending it should not freeze
    /// the window, and the engine publishes the new attachment list when it is done, so there
    /// is no local state to keep in step.
    @discardableResult
    public func addFiles(_ urls: [URL], allowImages: Bool = true) -> Int {
        guard let client else {
            errorBanner = "Not connected to the engine."
            return 0
        }
        let imagesAllowed = allowImages && allSeatsSupportVision

        // Checked before reading, so an unreadable or unwanted file costs nothing.
        var queued: [(name: String, data: Data)] = []
        var failures: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            if !imagesAllowed, let kind = DocumentKind.forFilename(name), kind.isImage {
                failures.append(
                    DocumentError.imageNotAllowed.errorDescription ?? "Images are unavailable.")
                continue
            }
            do {
                queued.append((name, try Data(contentsOf: url)))
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }

        guard !queued.isEmpty else {
            errorBanner = failures.first
            return 0
        }

        errorBanner = nil
        let pending = queued
        Task { [weak self] in
            var rejected: [String] = failures
            for file in pending {
                do {
                    try await client.addAttachment(filename: file.name, contents: file.data)
                    // The engine now holds the real file, so a stored copy of the same name is
                    // no longer "restored but not loaded".
                    self?.restoredAttachments.removeAll { $0.name == file.name }
                } catch {
                    // The engine's reason, which is what the user needs to read.
                    rejected.append("\(file.name): \(error.localizedDescription)")
                }
            }
            guard let self else { return }
            self.errorBanner = rejected.isEmpty ? nil : rejected.joined(separator: "\n")
            self.refreshAttachmentRestoreNotice()
        }
        return queued.count
    }

    /// Seed the attached material at launch, before any turn can run.
    ///
    /// The engine is a separate, freshly started process holding nothing, and a document the
    /// moderator added was extracted *there*: what settings kept is the engine's description of
    /// the file, never the file. So the stored list cannot be re-uploaded from here, and this
    /// does not pretend otherwise. It keeps the list (see `restoredAttachments`), leaves it in
    /// `attachments` so the chips and the saved settings survive the relaunch, reconciles away
    /// anything the engine holds that is no longer wanted, and tells the moderator which files
    /// the models cannot see until they are added again.
    ///
    /// Returns false when something could not be loaded, true when the engine already holds
    /// everything asked for. The launch path ignores the result and reads the notice instead.
    @discardableResult
    public func setAttachments(_ documents: [AttachedDocument]) -> Bool {
        // A file the engine already holds under the same name is loaded, not restored, so the
        // stored copy is superseded rather than reported as missing.
        let heldNames = Set((lastSnapshot?.attachments ?? []).map(\.name))
        restoredAttachments = documents.filter { !heldNames.contains($0.name) }
        syncAttachments(documents)
        refreshAttachmentRestoreNotice()
        return restoredAttachments.isEmpty
    }

    public func removeAttachment(_ id: UUID) {
        restoredAttachments.removeAll { $0.id == id }
        syncAttachments(attachments.filter { $0.id != id })
        refreshAttachmentRestoreNotice()
        saveSettings()
    }

    public func removeAllAttachments() {
        restoredAttachments.removeAll()
        syncAttachments([])
        refreshAttachmentRestoreNotice()
        saveSettings()
    }

    /// Ask for a vision override on a seat, for an API model whose family cannot be
    /// recognised from its id.
    public func setVisionOverride(_ agentID: String, _ support: VisionSupport?) {
        guard var spec = panes.first(where: { $0.id == agentID })?.spec else { return }
        spec.visionOverride = support
        pane(agentID)?.spec = spec
        saveSettings()
    }

    /// Where the log gets condensed, for display.
    public var compactThreshold: Double { lastSnapshot?.compactThreshold ?? 0.7 }

    /// Condense the log now, rather than waiting for the threshold.
    public func compactNow() {
        errorBanner = nil
        run { client in _ = try await client.send(.compact) }
    }
}
