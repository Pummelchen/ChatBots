// ChatBotsApp — the deliverable, on screen
//
// A research session's whole point is the report, and the desktop app could not show one. The
// engine had been producing them since the research mode existed and the browser could display
// them; the app had no mode switch, no progress and no report, which made the mode unreachable
// on the platform the project is named after.
//
// The markdown is rendered as markdown rather than shown as source. The labels are the reason a
// report is usable — a reader deciding whether to trust a claim needs to see FACT and INFERENCE
// differently at a glance — and a wall of asterisks hides exactly that.

import ChatBotsCore
import SwiftUI

struct ReportSheet: View {
    @EnvironmentObject private var zoom: ZoomStore
    @ObservedObject var controller: ChatController
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 680 * zoom.scale, height: 600 * zoom.scale)
    }

    private var report: APISnapshot.ReportSummary? { controller.report }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(report?.question ?? "No report yet")
                    .scaledFont(size: 13, weight: .semibold)
                    .lineLimit(2)
                if let report {
                    Text(
                        "\(report.labelledClaims) labelled claims · \(report.stopReason)"
                    )
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let report, !report.isLabelled {
                Label("Written without the claim labels", systemImage: "exclamationmark.triangle")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            } else if let report, !report.missingSections.isEmpty {
                Label(
                    "Not covered: \(report.missingSections.joined(separator: ", "))",
                    systemImage: "info.circle")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                controller.saveReport()
            } label: {
                Label("Download .md", systemImage: "square.and.arrow.down")
                    .scaledFont(size: 11)
            }
            .buttonStyle(.bordered)
            .disabled(report == nil)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: Rendering

    /// The markdown, split into the pieces worth styling differently.
    ///
    /// A deliberately small parser rather than a markdown library: this document has four
    /// constructs in it — headings, bullets, bold labels and paragraphs — and pulling in a
    /// dependency to render them would be a larger thing to keep working than the viewer.
    private var blocks: [Block] {
        guard let markdown = report?.markdown else { return [] }
        var out: [Block] = []
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("## ") {
                out.append(.heading(String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("# ") {
                out.append(.title(String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                out.append(.bullet(String(trimmed.dropFirst(2))))
            } else {
                out.append(.paragraph(trimmed))
            }
        }
        return out
    }

    private enum Block {
        case title(String)
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .title(let text):
            Text(inline(text))
                .scaledFont(size: 18, weight: .bold)
                .padding(.top, 4)
        case .heading(let text):
            VStack(alignment: .leading, spacing: 4) {
                Text(text.uppercased())
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(.secondary)
                Divider()
            }
            .padding(.top, 8)
        case .bullet(let text):
            HStack(alignment: .top, spacing: 7) {
                Text("•").foregroundStyle(.tertiary)
                Text(inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scaledFont(size: 12)
        case .paragraph(let text):
            Text(inline(text))
                .scaledFont(size: 12)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Bold the spans the report itself marked, and colour the claim labels.
    ///
    /// The labels are what make the document usable, so they are given a colour of their own
    /// rather than left as bold text among other bold text.
    private func inline(_ text: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(text)
        while let open = rest.range(of: "**") {
            result.append(AttributedString(String(rest[rest.startIndex..<open.lowerBound])))
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "**") else {
                result.append(AttributedString(String(rest[open.lowerBound...])))
                return result
            }
            var bold = AttributedString(String(after[after.startIndex..<close.lowerBound]))
            bold.font = .system(size: 12, weight: .semibold)
            if let label = ResearchStatement.Basis(rawValue: String(bold.characters).uppercased()) {
                bold.foregroundColor = label.isReliable ? AgentTheme.ok : .orange
            }
            result.append(bold)
            rest = after[close.upperBound...]
        }
        result.append(AttributedString(String(rest)))
        return result
    }
}
