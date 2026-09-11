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
                            AttachmentChip(document: document) {
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
    let onRemove: () -> Void

    @Environment(\.themePalette) private var palette
    @State private var showingText = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: document.kind.symbol)
                .scaledFont(size: 10)

            VStack(alignment: .leading, spacing: 0) {
                Text(document.name)
                    .scaledFont(size: 10.5, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(document.summary)
                    .scaledFont(size: 9)
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 220, alignment: .leading)

            if !document.kind.isImage, !document.text.isEmpty {
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
            .disabled(false)
            .help("Remove \(document.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.textTertiary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 0.5)
        )
        .help("\(document.name) — \(document.summary)")
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
