import AgenticConversation
import AgenticPresentation
import Primitives
import Agentic
import AgenticInterfaces
import Foundation
import Terminal

@_spi(Testing) public enum HostPendingDocumentMaterializer {
    public static func document(
        host: AgenticToolHost,
        pending: HostPendingCall,
        kind: AgenticHostConsoleDocumentKind
    ) async throws -> AgenticHostConsoleDocumentPresentation {
        switch kind {
        case .details:
            return details(
                pending
            )

        case .preview:
            return try await preview(
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

    static func preview(
        host: AgenticToolHost,
        pending: HostPendingCall
    ) async throws -> AgenticHostConsoleDocumentPresentation {
        let invocation = ToolInvocation(
            id: pending.call.id,
            tool: ToolIdentifier(pending.call.name),
            arguments: pending.call.input,
            execution: pending.execution
        )
        let review = try await host.tools.review(
            invocation,
            context: ToolContext(
                workspace: host.workspace
            )
        )
        let id = documentID(
            pending,
            kind: .preview
        )

        return HostPreviewDocument.make(
            review.preflight.preview,
            id: id,
            runID: pending.runID,
            stepID: pending.call.id,
            prelude: "status     pre-execution preview\nnote       Preview may change before execution.",
            rendering: TerminalConversationTextRendering()
        ) ?? AgenticHostConsoleDocumentPresentation(
            id: id,
            runID: pending.runID,
            stepID: pending.call.id,
            kind: .preview,
            body: "No preview available."
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

    static func json(
        _ value: ToolInvocation.Target?
    ) -> String {
        guard let value else {
            return "<default>"
        }

        do {
            return json(
                try JSONValue.encoding(
                    value
                )
            )
        } catch {
            return "<unavailable>"
        }
    }
}
