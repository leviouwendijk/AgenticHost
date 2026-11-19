import Agentic
import AgenticInterfaces
import Reporting

/// The `.preview` document for a tool's preview: titled after its sections
/// (`Event`, `Diff`), carried as data for the viewer to lay out, with plain
/// text alongside for copying.
package enum HostPreviewDocument {
    package static func make(
        _ preview: ToolPreflight.Preview,
        id: String,
        runID: String,
        stepID: String,
        prelude: String? = nil
    ) -> AgenticHostConsoleDocumentPresentation? {
        let sections = preview.sections.filter { !$0.content.isEmpty }
        guard !sections.isEmpty else { return nil }
        let text = sections.map { section in
            let body = plainText(section.content)
            return sections.count > 1 ? section.title + "\n" + body : body
        }.joined(separator: "\n\n")

        return .init(
            id: id,
            runID: runID,
            stepID: stepID,
            kind: .preview,
            title: AgenticPreviewRenderer.title(sections),
            body: [prelude, text].compactMap { $0 }.joined(separator: "\n\n"),
            previewBody: sections,
            previewPrelude: prelude
        )
    }

    static func plainText(
        _ content: ToolPreflight.Preview.Content
    ) -> String {
        switch content {
        case .difference(let difference):
            return AgenticMutationDifferenceRenderer.render(difference)
        case .command(let command):
            return (command.workingDirectory.map { "in \($0)\n" } ?? "") + command.line
        case .report(let document):
            return ReportMarkdown.render(document)
        }
    }
}
