import Agentic
import AgenticPresentation
import DifferenceSwiftUI
import SwiftUI

/// A document of a run step. A tool's preview is drawn from its sections:
/// diffs natively, commands as their line; anything else as its text.
@MainActor
struct DesktopDocumentView: View {
    let document: AgenticHostConsoleDocumentPresentation

    var body: some View {
        if let sections = document.previewBody, !sections.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let prelude = document.previewPrelude, !prelude.isEmpty {
                    plain(prelude)
                }
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        if sections.count > 1 {
                            Text(section.title).font(.caption.weight(.semibold))
                        }
                        content(section.content)
                    }
                }
            }
        } else {
            plain(document.body)
        }
    }

    @ViewBuilder
    private func content(
        _ content: ToolPreflight.Preview.Content
    ) -> some View {
        switch content {
        case .difference(let difference):
            VStack(alignment: .leading, spacing: 6) {
                if let tree = difference.tree {
                    TreeDifferenceView(tree)
                }
                if let source = difference.source {
                    DifferenceView(source)
                } else {
                    DifferenceView(difference.layout)
                }
            }
        case .command(let command):
            VStack(alignment: .leading, spacing: 2) {
                if let directory = command.workingDirectory {
                    Text("in \(directory)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                plain(command.line)
            }
        case .report:
            plain(document.body)
        }
    }

    private func plain(
        _ text: String
    ) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
