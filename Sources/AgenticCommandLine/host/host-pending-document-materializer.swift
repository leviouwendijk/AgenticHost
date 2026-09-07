import Primitives
import Agentic
import AgenticExecution
import AgenticInterfaces
import Foundation
import Terminal

package enum HostPendingDocumentMaterializer {
    package static func document(
        host: AgenticToolHost,
        pending: HostPendingCall,
        kind: AgenticHostConsoleDocumentKind
    ) async throws -> AgenticHostConsoleDocumentPresentation {
        switch kind {
        case .details:
            return details(
                pending
            )

        case .diff:
            return try await diff(
                host: host,
                pending: pending
            )

        case .stdout:
            return unavailableStream(
                pending: pending,
                kind: .stdout,
                body: "No stdout available yet."
            )

        case .stderr:
            return unavailableStream(
                pending: pending,
                kind: .stderr,
                body: "No stderr available yet."
            )
        }
    }
}

private extension HostPendingDocumentMaterializer {
    static func details(
        _ pending: HostPendingCall
    ) -> AgenticHostConsoleDocumentPresentation {
        let inspection = ToolInspectionDocument(
            title: "ToolPlan call details",
            sections: [
                ToolInspectionSection(
                    title: "Summary",
                    items: [
                        .field(
                            label: "state",
                            value: "ready"
                        ),
                        .field(
                            label: "tool",
                            value: pending.call.name
                        ),
                        .field(
                            label: "call id",
                            value: pending.call.id
                        ),
                        .field(
                            label: "path",
                            value: pending.path
                        ),
                    ]
                ),
                ToolInspectionSection(
                    title: "Input",
                    items: [
                        .body(
                            json(
                                pending.call.input
                            )
                        ),
                    ]
                ),
                ToolInspectionSection(
                    title: "Execution",
                    items: [
                        .body(
                            json(
                                pending.execution
                            )
                        ),
                    ]
                ),
            ]
        )
        let rendered = AgenticTerminalInspectionRenderer.render(
            inspection,
            stream: .standardError,
            theme: .agentic,
            layout: .agentic
        )

        return AgenticHostConsoleDocumentPresentation(
            id: documentID(
                pending,
                kind: .details
            ),
            runID: pending.runID,
            stepID: pending.call.id,
            kind: .details,
            title: inspection.title,
            body: rendered
        )
    }

    static func diff(
        host: AgenticToolHost,
        pending: HostPendingCall
    ) async throws -> AgenticHostConsoleDocumentPresentation {
        let execution = try pending.execution.map { value in
            try JSONToolBridge.decode(
                ToolInvocation.Execution.self,
                from: value
            )
        }
        let review = try await host.invoker.review(
            pending.call,
            execution: execution,
            context: host.context
        )
        let preview = review.preflight.diffPreview
        let rendered: String
        let title: String

        if let preview,
           !preview.isEmpty {
            title = preview.title ?? "Diff preview"

            if let layout = preview.layout {
                rendered = TerminalDifferenceRenderer.render(
                    layout
                )
            } else {
                rendered = preview.text
            }
        } else {
            title = "Diff preview"
            rendered = "No diff preview available."
        }

        return AgenticHostConsoleDocumentPresentation(
            id: documentID(
                pending,
                kind: .diff
            ),
            runID: pending.runID,
            stepID: pending.call.id,
            kind: .diff,
            title: title,
            body: """
            status     pre-execution preview
            note       Preview may change before execution.

            \(rendered)
            """
        )
    }

    static func unavailableStream(
        pending: HostPendingCall,
        kind: AgenticHostConsoleDocumentKind,
        body: String
    ) -> AgenticHostConsoleDocumentPresentation {
        AgenticHostConsoleDocumentPresentation(
            id: documentID(
                pending,
                kind: kind
            ),
            runID: pending.runID,
            stepID: pending.call.id,
            kind: kind,
            body: body
        )
    }

    static func documentID(
        _ pending: HostPendingCall,
        kind: AgenticHostConsoleDocumentKind
    ) -> String {
        "\(pending.runID):\(pending.call.id):pending:\(kind.rawValue)"
    }

    static func json(
        _ value: JSONValue
    ) -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys,
            ]
            let data = try encoder.encode(
                value
            )

            return String(
                decoding: data,
                as: UTF8.self
            )
        } catch {
            return "<unavailable>"
        }
    }

    static func json(
        _ value: JSONValue?
    ) -> String {
        guard let value else {
            return "<default>"
        }

        return json(
            value
        )
    }
}
