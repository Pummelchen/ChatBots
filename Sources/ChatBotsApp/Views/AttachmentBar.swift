// ChatBotsApp — the source-material row
//
// Files are added before a conversation starts, and what matters to the moderator is not
// just *that* a file was accepted but *what was read out of it*: how many words, whether it
// was shortened, how many pages. A chip that only showed a filename would leave them
// wondering whether a 300-page PDF was really included. So each chip carries the extract.

import ChatBotsCore
import SwiftUI

/// The Add button plus one chip per attached file.
struct AttachmentBar: View {
    @ObservedObject var controller: ChatController
    @Environment(\.themePalette) private var colors

    var body: some View {
        HStack(spacing: 8) {
            Button {
                controller.attachFiles()
            } label: {
                Label("Add files", systemImage: "paperclip")
                    .scaledFont(size: 11)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!controller.canAttachFiles)
            .help(
                controller.canAttachFiles
                    ? "Add documents (PDF, txt, md, docx…) or images as source material"
                    : "Source material must be added before the conversation starts"
            )

            if !controller.allSeatsSupportVision {
                // Images are hidden rather than shown-and-failing, and saying why is the
                // difference between "unavailable" and "broken".
                Image(systemName: "photo.badge.exclamationmark")
                    .scaledFont(size: 10)
                    .foregroundStyle(colors.textTertiary)
                    .help(
                        "Images are hidden because these seats cannot see: "
                            + controller.seatsWithoutVision.joined(separator: ", ")
                    )
            }

            if controller.attachments.isEmpty {
                Text("No source material")
                    .scaledFont(size: 10.5)
                    .foregroundStyle(colors.textTertiary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(controller.attachments) { document in
                            AttachmentChip(
                                document: document,
                                isLoaded: !controller.attachmentsNotLoaded.contains(document.id),
                                canRemove: controller.canAttachFiles
                            ) {
                                controller.removeAttachment(document.id)
                            }
                        }
                        if controller.canAttachFiles, controller.attachments.count > 1 {
                            Button("Remove all") { controller.removeAllAttachments() }
                                .buttonStyle(.link)
                                .scaledFont(size: 10)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
            }

            Spacer(minLength: 0)
        }
    }
}

/// One attached file: what it is, what was read from it, and a way to remove it.
struct AttachmentChip: View {
    let document: AttachedDocument
    /// False when the file was restored from a saved conversation but this engine does not
    /// hold it, so the models cannot see it.
    ///
    /// This is part of what the chip renders rather than something the banner says: the
    /// notice is dismissable, and once it is gone an ordinary-looking chip implies the models
    /// can read material they cannot.
    let isLoaded: Bool
    /// Whether removing is allowed at all. The engine refuses a change once a turn has completed, the
    /// page gates its ✕ on the same flag, and this is that flag passed down rather than the chip having
    /// to know where it comes from.
    let canRemove: Bool
    let onRemove: () -> Void

    @Environment(\.themePalette) private var palette
    @State private var showingText = false

    /// The warning colour, which is deliberately not a palette field: an unloaded attachment is
    /// a state rather than a theme, and orange reads against both themes.
    private var warning: Color { .orange }

    private var helpText: String {
        isLoaded
            ? "\(document.name) — \(document.summary)"
            : "\(document.name) — saved from a previous session but not loaded into this "
                + "engine: the models cannot see it. Add the file again to load it."
    }

    /// The chip's fill and border. `AnyShapeStyle` so the loaded and unloaded branches have a
    /// common type — the palette's text colours are shape styles rather than `Color`s.
    private var chipFill: AnyShapeStyle {
        isLoaded
            ? AnyShapeStyle(palette.textTertiary.opacity(0.10))
            : AnyShapeStyle(warning.opacity(0.12))
    }

    private var chipStroke: AnyShapeStyle {
        isLoaded ? AnyShapeStyle(palette.border) : AnyShapeStyle(warning.opacity(0.7))
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isLoaded ? document.kind.symbol : "exclamationmark.triangle.fill")
                .scaledFont(size: 10)
                .foregroundStyle(isLoaded ? AnyShapeStyle(palette.textSecondary) : AnyShapeStyle(warning))

            VStack(alignment: .leading, spacing: 0) {
                Text(document.name)
                    .scaledFont(size: 10.5, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isLoaded ? document.summary : "Not loaded — the models cannot see this")
                    .scaledFont(size: 9)
                    .foregroundStyle(isLoaded ? palette.textTertiary : AnyShapeStyle(warning))
                    .lineLimit(1)
            }
            .frame(maxWidth: 220, alignment: .leading)

            if !document.kind.isImage, !document.text.isEmpty {
                // Shown only for a document whose extract is on this side of the wire. A
                // document rebuilt from the engine has no body — the engine keeps it — so the
                // affordance is absent rather than opening an empty popover, and the chip's
                // figures come from the engine's own summary and token count instead of being
                // recomputed from fields this side does not have.
                Button {
                    showingText = true
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .scaledFont(size: 10)
                }
                .buttonStyle(.plain)
                .help("Show the text that was extracted")
                .popover(isPresented: $showingText, arrowEdge: .bottom) {
                    ExtractedTextView(document: document)
                }
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 10)
                    .foregroundStyle(palette.textTertiary)
            }
            .buttonStyle(.plain)
            // The same rule the engine enforces and the page gates on: the ✕ used to be
            // `.disabled(false)`, so a click during a running conversation did nothing at all — the
            // engine refused the change and the service reported success.
            .disabled(!canRemove)
            .help(
                canRemove
                    ? "Remove \(document.name)"
                    : "Source material cannot be changed once the conversation has started"
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(chipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(chipStroke, lineWidth: 0.5)
        )
        .help(helpText)
    }
}

/// The extracted text, shown so the moderator can check what the models will actually read.
///
/// This matters: extraction is where a PDF's columns can interleave or a table can lose its
/// shape, and the only way to know is to look. It is also the fastest way to confirm that a
/// document was read at all.
struct ExtractedTextView: View {
    let document: AttachedDocument
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(document.name)
                    .scaledFont(size: 11, weight: .semibold)
                Spacer()
                Text("\(document.estimatedTokens) tokens")
                    .scaledFont(size: 10)
                    .foregroundStyle(palette.textTertiary)
            }
            if document.wasTruncated {
                Label(
                    "Shortened to fit the context budget",
                    systemImage: "exclamationmark.triangle"
                )
                .scaledFont(size: 10)
                .foregroundStyle(palette.textSecondary)
            }
            Divider()
            ScrollView {
                Text(document.text)
                    .scaledFont(size: 10, design: .monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(width: 520, height: 360)
    }
}
