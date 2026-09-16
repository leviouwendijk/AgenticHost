import AgenticInterfaces
import AgenticWorkspace
import Foundation

package enum AgenticWorkspaceAccessPresentation {
    package static func prompt(
        _ request: WorkspaceAccessRequest
    ) -> AgenticWorkspaceAccessPrompt {
        .init(
            summary: summary(
                request
            ),
            fields: [
                .init(
                    "request",
                    details(
                        request
                    )
                ),
            ]
        )
    }

    package static func summary(
        _ request: WorkspaceAccessRequest
    ) -> String {
        let count = request.overlay.roots.count

        if count == 1 {
            return "Request temporary workspace authority for 1 additional root."
        }

        return "Request temporary workspace authority for \(count) additional roots."
    }

    package static func details(
        _ request: WorkspaceAccessRequest
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]

        guard let data = try? encoder.encode(
            request
        ) else {
            return String(
                describing: request
            )
        }

        return String(
            decoding: data,
            as: UTF8.self
        )
    }
}
